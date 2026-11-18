import AppKit
import HoarderCore
import Observation
import SwiftUI

/// One device's state: its latest scan, free space, low-disk alerts, and cleaning. This Mac scans
/// in-process; every other device runs the hoarder CLI over SSH through `Remote`.
@Observable @MainActor
final class Machine: Identifiable {
    let id: String
    /// "This Mac", or the device's SSH host without a tailnet suffix (`displayName`).
    let name: String
    /// Nil for this Mac.
    let host: String?
    private let remote: Remote?
    /// Set from config.json each minute by `Monitor`.
    var config = Config()
    var device: Device?

    private(set) var report: Report?
    private(set) var disk: DiskSpace?
    private(set) var scanning = false
    /// Rows being cleaned, with the name the header shows, kept here so a scan cannot drop the line.
    private(set) var cleaning: [Finding.ID: String] = [:]
    private(set) var alertState: AlertState
    /// Why a clean failed, per row. Kept while the row exists.
    private(set) var failures: [Finding.ID: Failure] = [:]
    /// Rows refused since the popover opened. They keep their place in the list until it closes, even
    /// once judged in use, so the row the header points at is where it was.
    private(set) var refused: Set<Finding.ID> = []
    /// Refused rows on a device, waiting for its rescan to judge them again.
    private(set) var rechecking: Set<Finding.ID> = []
    /// The Clean safe run in progress, for the header's checklist; nil when none is.
    private(set) var batch: Batch?
    /// Scanners finished in the scan running now, for the first scan's progress line. This Mac only.
    private(set) var scanned: Set<HoarderCore.Category> = []
    /// The section order when the first clean since the popover opened started; see `sectionOrder`.
    private var frozenSections: [HoarderCore.Category]?
    /// "Cleaned X, 2.1 GB" after a clean succeeds, until the popover closes.
    private(set) var lastCleaned: String?
    /// "1 cleanup not done, see Worktrees" after a clean fails, until the popover closes.
    private(set) var lastFailed: String?
    private var lastFailedID: Finding.ID?
    /// Docker prunes free space inside a VM disk on macOS, and on the disk itself on Linux.
    var dockerInVM: Bool { platform.map { $0.os == "darwin" } ?? true }
    /// Learned on the first scan or connection test; this Mac's is known up front.
    private(set) var platform: Remote.Platform?
    /// Why the device could not be reached, or its scan not read. The last report stays shown.
    var problem: String? { connectionProblem ?? scanProblem }
    private var connectionProblem: String?
    private var scanProblem: String?
    /// Cleaned while a scan was running, so that scan's result does not bring the rows back.
    private var cleanedDuringScan: Set<Finding.ID> = []
    /// When the last scan started, so a device that keeps failing is retried on schedule, not every minute.
    private var lastScanStart: Date?
    private var checkingDisk = false

    static let localID = "local"

    /// This Mac.
    init() {
        id = Self.localID
        name = "This Mac"
        host = nil
        remote = nil
        alertState = Self.loadAlertState(id: Self.localID)
        disk = DiskSpace.current()
        platform = Remote.Platform(os: "darwin", arch: Self.arch)
    }

    /// What the popover and Settings call a device: its host without a tailnet or Bonjour suffix, so
    /// "box.tail1234.ts.net" reads "box". The full host stays in `host`, for SSH and Settings' Host row.
    static func displayName(_ host: String) -> String {
        guard [".ts.net", ".local"].contains(where: host.hasSuffix) else { return host }
        return String(host.prefix { $0 != "." })
    }

    init(device: Device, build: Remote.Build) {
        id = device.host
        name = Self.displayName(device.host)
        host = device.host
        remote = Remote(host: device.host, build: build)
        self.device = device
        alertState = Self.loadAlertState(id: device.host)
    }

    /// A still machine for `--snapshot`: shows the given state, never scans, alerts or cleans.
    init(preview host: String?, report: Report?, disk: DiskSpace?, config: Config, alertState: AlertState,
         scanning: Bool, cleaning: [Finding.ID: String], failures: [Finding.ID: String], lastCleaned: String?,
         lastFailed: String?, problem: String?, platform: Remote.Platform? = nil, batch: Batch? = nil,
         scanned: Set<HoarderCore.Category> = []) {
        self.batch = batch
        self.scanned = scanned
        id = host ?? Self.localID
        name = host.map(Self.displayName) ?? "This Mac"
        self.host = host
        remote = nil
        self.report = report
        self.disk = disk
        self.config = config
        self.alertState = alertState
        self.scanning = scanning
        self.cleaning = cleaning
        self.failures = failures.mapValues { Failure(reason: describeFailure($0), output: $0) }
        refused = Set(failures.keys)
        self.lastCleaned = lastCleaned
        self.lastFailed = lastFailed
        connectionProblem = problem
        self.platform = platform ?? (host == nil ? Remote.Platform(os: "darwin", arch: Self.arch) : nil)
    }

    private static var arch: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    /// Where the device's SSH Host entry really points, for Settings; nil for this Mac or a plain name.
    func resolvedHostName() async -> String? {
        await remote?.resolvedHostName()
    }

    /// What Settings' Test connection runs: the same platform and free-space calls a scan starts with.
    func testConnection() async {
        guard let remote else { return await refreshDisk() }
        do {
            platform = try await remote.detectPlatform()
        } catch {
            connectionProblem = error.message
            return
        }
        await refreshDisk()
    }

    var alertBelowGB: Int { config.alertBelowGB(for: device) }
    private var alertLimitBytes: Int64 { Int64(alertBelowGB) * 1_000_000_000 }
    var isLow: Bool { disk.map { isLow($0.free) } ?? false }
    /// Under a quarter of the limit: the heading and menu bar turn red and say "critically low".
    var isCritical: Bool { disk.map { isCritical($0.free) } ?? false }
    /// The same tests for a free figure other than the current one, such as after Clean safe.
    func isLow(_ free: Int64) -> Bool { free < alertLimitBytes }
    func isCritical(_ free: Int64) -> Bool { free < alertLimitBytes / 4 }

    func isScanDue(now: Date = .now) -> Bool {
        guard !scanning else { return false }
        return lastScanStart.map { now.timeIntervalSince($0) >= Double(config.scanEveryMinutes) * 60 } ?? true
    }

    func scan() async {
        guard !scanning else { return }
        scanning = true
        lastScanStart = .now
        cleanedDuringScan = []
        scanned = []
        let fresh: Report
        if let remote {
            do {
                platform = try await remote.detectPlatform()
                fresh = try await remote.scan(roots: device?.projectRoots)
                connectionProblem = nil
                scanProblem = nil
            } catch {
                scanProblem = error.message
                scanning = false
                return
            }
        } else {
            fresh = await Hoarder.scan(config: config) { category in
                Task { @MainActor in self.scanned.insert(category) }
            }
        }
        let current = cleanedDuringScan.reduce(fresh) { report, id in
            report.findings.first { $0.id == id }.map(report.removing) ?? report
        }
        report = current
        // A failure stays while its row can still be cleaned, kept rows included; a row with no command
        // left drops it, and the header says why instead of pointing at a row that no longer shows it.
        let cleanable = Set(current.findings.filter { $0.cleanup != nil }.map(\.id))
        failures = failures.filter { cleanable.contains($0.key) }
        if let id = lastFailedID, lastFailed != nil, !cleanable.contains(id) {
            let now = current.findings.first { $0.id == id }
            lastFailed = now.map { "Not cleaned: \($0.fullName), now in use: \($0.detail)" }
        }
        rechecking = []
        frozenSections = nil
        scanning = false
        await refreshDisk()
    }

    /// Sections with the most that is safe to clean come first, so the top section is where to start.
    /// Docker goes last: its prunes free space inside Docker's disk, not on the Mac right away. Once a
    /// clean starts, the order holds until the popover closes or a scan lands, so the section being
    /// worked in never moves while you are in it.
    func sectionOrder(_ report: Report) -> [HoarderCore.Category] {
        let fresh = Self.rankedSections(report)
        guard let frozenSections else { return fresh }
        return frozenSections.filter(fresh.contains) + fresh.filter { !frozenSections.contains($0) }
    }

    private static func rankedSections(_ report: Report) -> [HoarderCore.Category] {
        HoarderCore.Category.allCases
            .filter { category in report.findings.contains { $0.category == category } }
            .map { ($0, report.total(.reclaimable, in: $0), report.total(.review, in: $0)) }
            .sorted { ($0.0 == .docker ? 0 : 1, $0.1, $0.2) > ($1.0 == .docker ? 0 : 1, $1.1, $1.2) }
            .map(\.0)
    }

    /// What "Clean all safe" runs.
    var safeToClean: [Finding] {
        report?.findings.filter { $0.verdict == .reclaimable && $0.cleanup != nil } ?? []
    }

    /// Cleans every safe row in turn rather than at once, so a worktree and the node_modules inside it
    /// never race. A row an earlier clean took with it (nested node_modules) counts as done. Stop takes
    /// effect between rows: the running command finishes, since killing git or docker halfway could
    /// leave a mess.
    func cleanSafe() async {
        let rows = safeToClean
        guard batch == nil, !rows.isEmpty else { return }
        batch = Batch(items: rows.map { Batch.Item(finding: $0) })
        var cleaned = 0
        var freed: Int64 = 0
        var stoppedAfter: Int?
        for (index, row) in rows.enumerated() {
            if batch?.stopping == true {
                stoppedAfter = index
                break
            }
            // The current row: cleaning one inside it may have shrunk it.
            guard let finding = report?.findings.first(where: { $0.id == row.id }) else {
                batch?.items[index].status = .done
                cleaned += 1
                continue
            }
            batch?.items[index].status = .cleaning
            let done = await clean(finding)
            batch?.items[index].status = done ? .done : .notDone
            if done {
                cleaned += 1
                freed += finding.bytes
            }
        }
        batch = nil
        // One row keeps that row's own line.
        guard rows.count > 1 else { return }
        let message = stoppedAfter.map { "Stopped after \($0) of \(rows.count), \(formatBytes(freed)) cleaned" }
            ?? "Cleaned \(cleaned) of \(rows.count), \(formatBytes(freed))"
        lastCleaned = message
        AccessibilityNotification.Announcement(message).post()
    }

    /// Finishes the running cleanup, then starts no more.
    func stopCleanSafe() {
        batch?.stopping = true
    }

    @discardableResult
    func clean(_ finding: Finding) async -> Bool {
        guard cleaning[finding.id] == nil else { return false }
        if frozenSections == nil, let report { frozenSections = Self.rankedSections(report) }
        cleaning[finding.id] = finding.fullName
        failures[finding.id] = nil
        let result = if let remote, let command = finding.cleanup {
            await remote.clean(command)
        } else {
            await Hoarder.clean(finding)
        }
        cleaning[finding.id] = nil
        var done = result.ok
        if result.ok {
            // In a VM, Docker frees space inside its disk; the host gets it back only after the VM trims.
            let size = formatBytes(finding.bytes)
            finish(finding, saying: finding.bytes == 0 ? "Cleaned \(finding.fullName)"
                : finding.category == .docker && dockerInVM ? "Cleaned \(finding.fullName): \(size) freed inside Docker's disk"
                : "Cleaned \(finding.fullName), \(size)")
        } else {
            let failure = Failure(reason: describeFailure(result.output), output: result.output)
            failures[finding.id] = failure
            refused.insert(finding.id)
            lastFailedID = finding.id
            done = await recheck(finding)
            if !done { AccessibilityNotification.Announcement("\(finding.fullName) not cleaned: \(failure.reason)").post() }
        }
        lastFailed = refusalSummary
        await refreshDisk()
        return done
    }

    /// The row leaves the list and the header says what happened.
    private func finish(_ finding: Finding, saying message: String) {
        report = report?.removing(finding)
        if scanning { cleanedDuringScan.insert(finding.id) }
        failures[finding.id] = nil
        refused.remove(finding.id)
        lastCleaned = message
        AccessibilityNotification.Announcement(message).post()
    }

    /// git refuses a worktree that changed since the scan. On this Mac that worktree is read again at
    /// once, so its row shows the new verdict and command where it stands. A device has no single-row
    /// check, so it rescans and the row says "checking again" until then. True when the folder turned
    /// out to be gone, which counts as cleaned.
    private func recheck(_ finding: Finding) async -> Bool {
        guard finding.category == .worktree else { return false }
        guard remote == nil else {
            rechecking.insert(finding.id)
            Task { await scan() }
            return false
        }
        switch await Hoarder.recheck(finding, config: config) {
        case .gone:
            finish(finding, saying: "Already gone: \(finding.fullName)")
            return true
        case .judged(let fresh):
            report = report?.replacing(fresh)
        case .unchecked:
            break
        }
        return false
    }

    /// "1 cleanup not done, see Worktrees", while refused rows are in view.
    private var refusalSummary: String? {
        let rows = report?.findings.filter { refused.contains($0.id) && failures[$0.id] != nil } ?? []
        guard let first = rows.first else { return nil }
        let count = rows.count == 1 ? "1 cleanup" : "\(rows.count) cleanups"
        let place = rows.allSatisfy { $0.category == first.category } ? first.category.label : "their rows"
        return "\(count) not done, see \(place)"
    }

    /// The outcome lines have been seen once the popover closes, and refused rows rejoin their group.
    func dismissCleaned() {
        lastCleaned = nil
        lastFailed = nil
        refused = []
        frozenSections = nil
    }

    func snooze() {
        alertState.snooze(until: .now.addingTimeInterval(86_400))
        saveAlertState()
    }

    func unsnooze() {
        alertState.unsnooze(low: isLow)
        saveAlertState()
    }

    /// Free space, then the low-disk alert. A remote device costs one SSH round trip, so overlapping
    /// checks on a slow link are dropped.
    func refreshDisk() async {
        if let remote {
            guard !checkingDisk else { return }
            checkingDisk = true
            defer { checkingDisk = false }
            do {
                disk = try await remote.diskSpace()
                connectionProblem = nil
            } catch {
                connectionProblem = error.message
                return
            }
        } else {
            disk = DiskSpace.current()
        }
        // No alert before the first scan: it would have nothing to suggest, and could fire before
        // notification permission is answered and be spent unseen.
        guard let disk, report != nil else { return }
        if alertState.evaluate(free: disk.free, limit: alertLimitBytes) {
            Notifier.lowDisk(on: self, free: disk.free)
        }
        saveAlertState()
    }

    /// This Mac keeps the key it always had, so updating does not re-arm a snoozed alert.
    private static func alertStateKey(id: String) -> String {
        id == localID ? "alertState" : "alertState.\(id)"
    }

    private static func loadAlertState(id: String) -> AlertState {
        UserDefaults.standard.data(forKey: alertStateKey(id: id))
            .flatMap { try? JSONDecoder().decode(AlertState.self, from: $0) } ?? AlertState()
    }

    private func saveAlertState() {
        UserDefaults.standard.set(try? JSONEncoder().encode(alertState), forKey: Self.alertStateKey(id: id))
    }
}

/// A refused cleanup: what its row says, and the command's own output for the row's tooltip.
struct Failure: Equatable {
    let reason: String
    let output: String
}

/// A Clean safe run: the rows it set out to clean, as they were when it started, and how each went.
/// Rows leave the report as they finish, so the header's checklist names them from here.
struct Batch {
    enum Status { case pending, cleaning, done, notDone }

    struct Item: Identifiable {
        let finding: Finding
        var status = Status.pending
        var id: Finding.ID { finding.id }
    }

    var items: [Item]
    /// Stop was pressed; the running row finishes and no other starts.
    var stopping = false

    /// Rows finished either way, so "3 of 11" names the one running.
    var finished: Int { items.filter { $0.status == .done || $0.status == .notDone }.count }
}
