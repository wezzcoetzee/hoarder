import AppKit
import HoarderCore
import Observation
import SwiftUI

/// One device's state: its latest scan, free space, low-disk alerts, and cleaning. This Mac scans
/// in-process; every other device runs the hoarder CLI over SSH through `Remote`.
@Observable @MainActor
final class Machine: Identifiable {
    let id: String
    /// "This Mac", or the device's SSH host.
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
    /// Why a clean failed, per row: the last line the command printed. Kept while the row exists.
    private(set) var failures: [Finding.ID: String] = [:]
    /// "Cleaned X, 2.1 GB" after a clean succeeds, until the popover closes.
    private(set) var lastCleaned: String?
    /// "Not cleaned: X, see its row" after a clean fails, until the popover closes.
    private(set) var lastFailed: String?
    private var lastFailedID: Finding.ID?
    /// Docker prunes free space inside a VM disk on macOS, and on the disk itself on Linux.
    private(set) var dockerInVM = true
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
    }

    init(device: Device, build: Remote.Build) {
        id = device.host
        name = device.host
        host = device.host
        remote = Remote(host: device.host, build: build)
        self.device = device
        alertState = Self.loadAlertState(id: device.host)
    }

    /// A still machine for `--snapshot`: shows the given state, never scans, alerts or cleans.
    init(preview host: String?, report: Report?, disk: DiskSpace?, config: Config, alertState: AlertState,
         scanning: Bool, cleaning: [Finding.ID: String], failures: [Finding.ID: String], lastCleaned: String?,
         lastFailed: String?, problem: String?) {
        id = host ?? Self.localID
        name = host ?? "This Mac"
        self.host = host
        remote = nil
        self.report = report
        self.disk = disk
        self.config = config
        self.alertState = alertState
        self.scanning = scanning
        self.cleaning = cleaning
        self.failures = failures
        self.lastCleaned = lastCleaned
        self.lastFailed = lastFailed
        connectionProblem = problem
    }

    var alertBelowGB: Int { config.alertBelowGB(for: device) }
    private var alertLimitBytes: Int64 { Int64(alertBelowGB) * 1_000_000_000 }
    var isLow: Bool { disk.map { $0.free < alertLimitBytes } ?? false }
    /// Under a quarter of the limit: the heading and menu bar turn red.
    var isCritical: Bool { disk.map { $0.free < alertLimitBytes / 4 } ?? false }

    func isScanDue(now: Date = .now) -> Bool {
        guard !scanning else { return false }
        return lastScanStart.map { now.timeIntervalSince($0) >= Double(config.scanEveryMinutes) * 60 } ?? true
    }

    func scan() async {
        guard !scanning else { return }
        scanning = true
        lastScanStart = .now
        cleanedDuringScan = []
        let fresh: Report
        if let remote {
            do {
                dockerInVM = try await remote.detectPlatform().os == "darwin"
                fresh = try await remote.scan(roots: device?.projectRoots)
                connectionProblem = nil
                scanProblem = nil
            } catch {
                scanProblem = error.message
                scanning = false
                return
            }
        } else {
            fresh = await Hoarder.scan(config: config)
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
        scanning = false
        await refreshDisk()
    }

    /// What "Clean all safe" runs.
    var safeToClean: [Finding] {
        report?.findings.filter { $0.verdict == .reclaimable && $0.cleanup != nil } ?? []
    }

    /// Cleans every safe row in turn rather than at once, so a worktree and the node_modules inside it
    /// never race. Rows an earlier clean took with it (nested node_modules) are skipped.
    func cleanSafe() async {
        var cleaned = 0
        var freed: Int64 = 0
        for id in safeToClean.map(\.id) {
            // The current row: cleaning one inside it may have shrunk it.
            guard let finding = report?.findings.first(where: { $0.id == id }) else { continue }
            if await clean(finding) {
                cleaned += 1
                freed += finding.bytes
            }
        }
        // One row keeps that row's own line.
        if cleaned > 1 {
            let message = "Cleaned \(cleaned) safe rows, \(formatBytes(freed))"
            lastCleaned = message
            AccessibilityNotification.Announcement(message).post()
        }
    }

    @discardableResult
    func clean(_ finding: Finding) async -> Bool {
        guard cleaning[finding.id] == nil else { return false }
        cleaning[finding.id] = finding.fullName
        failures[finding.id] = nil
        let result = if let remote, let command = finding.cleanup {
            await remote.clean(command)
        } else {
            await Hoarder.clean(finding)
        }
        cleaning[finding.id] = nil
        if result.ok {
            report = report?.removing(finding)
            if scanning { cleanedDuringScan.insert(finding.id) }
            // In a VM, Docker frees space inside its disk; the host gets it back only after the VM trims.
            let size = formatBytes(finding.bytes)
            let message = finding.bytes == 0 ? "Cleaned \(finding.fullName)"
                : finding.category == .docker && dockerInVM ? "Cleaned \(finding.fullName): \(size) freed inside Docker's disk"
                : "Cleaned \(finding.fullName), \(size)"
            lastCleaned = message
            AccessibilityNotification.Announcement(message).post()
        } else {
            let lastLine = result.output.split(separator: "\n").last.map(String.init) ?? "exited with an error"
            let reason = ["fatal: ", "error: "].reduce(lastLine) { line, prefix in
                line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : line
            }
            failures[finding.id] = String(reason.prefix(240))
            lastFailed = "Not cleaned: \(finding.fullName), see its row"
            lastFailedID = finding.id
            AccessibilityNotification.Announcement("\(finding.fullName) not cleaned").post()
            // git refuses a worktree that changed since the scan; a rescan shows it as kept, with why.
            if finding.category == .worktree { Task { await scan() } }
        }
        await refreshDisk()
        return result.ok
    }

    /// The outcome lines have been seen once the popover closes.
    func dismissCleaned() {
        lastCleaned = nil
        lastFailed = nil
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
