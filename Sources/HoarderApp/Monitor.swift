import AppKit
import HoarderCore
import Observation
import ServiceManagement
import SwiftUI

/// Owns the app's state: free space (checked every minute), the latest scan (rerun on the configured
/// interval), low-disk alerts, and cleaning.
@Observable @MainActor
final class Monitor {
    private(set) var report: Report?
    private(set) var disk = DiskSpace.current()
    private(set) var config = Config()
    private(set) var scanning = false
    /// Rows being cleaned, with the name the header shows, kept here so a scan cannot drop the line.
    private(set) var cleaning: [Finding.ID: String] = [:]
    private(set) var alertState: AlertState
    private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled
    /// Shown in the header. Kept apart, because config is re-read every minute and must not wipe a
    /// login error.
    private(set) var configError: String?
    private(set) var loginError: String?
    /// Why a clean failed, per row: the last line the command printed. Kept while the row exists.
    private(set) var failures: [Finding.ID: String] = [:]
    /// "Cleaned X, 2.1 GB" after a clean succeeds, until the popover closes.
    private(set) var lastCleaned: String?
    /// "Not cleaned: X, see its row" after a clean fails, until the popover closes.
    private(set) var lastFailed: String?
    private var lastFailedID: Finding.ID?
    /// The user turned Hoarder's notifications off, so low-disk alerts cannot arrive.
    private(set) var notificationsOff = false
    /// Cleaned while a scan was running, so that scan's result does not bring the rows back.
    private var cleanedDuringScan: Set<Finding.ID> = []

    private static let alertStateKey = "alertState"

    init() {
        alertState = UserDefaults.standard.data(forKey: Self.alertStateKey)
            .flatMap { try? JSONDecoder().decode(AlertState.self, from: $0) } ?? AlertState()
        Notifier.setUp()
        Task { await watchDisk() }
        Task { await scanOnSchedule() }
    }

    /// A still monitor for `--snapshot`: shows the given state, never scans, alerts or cleans.
    init(preview report: Report?, disk: DiskSpace, config: Config, alertState: AlertState, scanning: Bool,
         cleaning: [Finding.ID: String], failures: [Finding.ID: String], lastCleaned: String?, lastFailed: String?, notificationsOff: Bool) {
        self.report = report
        self.disk = disk
        self.config = config
        self.alertState = alertState
        self.scanning = scanning
        self.cleaning = cleaning
        self.failures = failures
        self.lastCleaned = lastCleaned
        self.lastFailed = lastFailed
        self.notificationsOff = notificationsOff
    }

    var isLow: Bool { disk.map { $0.free < config.alertLimitBytes } ?? false }
    /// Under a quarter of the limit: the heading and menu bar turn red.
    var isCritical: Bool { disk.map { $0.free < config.alertLimitBytes / 4 } ?? false }

    func scan() async {
        guard !scanning else { return }
        scanning = true
        cleanedDuringScan = []
        loadConfig()
        let fresh = await Hoarder.scan(config: config)
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
        refreshDisk()
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
        let result = await Hoarder.clean(finding)
        cleaning[finding.id] = nil
        if result.ok {
            report = report?.removing(finding)
            if scanning { cleanedDuringScan.insert(finding.id) }
            // Docker frees space inside its VM disk; the Mac gets it back only after the VM trims.
            let size = formatBytes(finding.bytes)
            let message = finding.bytes == 0 ? "Cleaned \(finding.fullName)"
                : finding.category == .docker ? "Cleaned \(finding.fullName): \(size) freed inside Docker's disk"
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
        refreshDisk()
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

    func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Open at login: \(error.localizedDescription)"
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    func editConfig() {
        do {
            try Config.writeDefaultsIfMissing()
            NSWorkspace.shared.open(Config.fileURL)
        } catch {
            configError = "Could not create \(Config.fileURL.path): \(error.localizedDescription)"
        }
    }

    /// Free space (and config) every minute, independent of scans, so an alert never waits on a 45s
    /// scan and a new limit applies within a minute.
    private func watchDisk() async {
        while !Task.isCancelled {
            refreshDisk()
            notificationsOff = await Notifier.isDenied()
            try? await Task.sleep(for: .seconds(60))
        }
    }

    private func scanOnSchedule() async {
        while !Task.isCancelled {
            let due = report.map { Date.now.timeIntervalSince($0.scannedAt) >= Double(config.scanEveryMinutes) * 60 } ?? true
            if due { await scan() }
            try? await Task.sleep(for: .seconds(60))
        }
    }

    private func refreshDisk() {
        loadConfig()
        disk = DiskSpace.current()
        // No alert before the first scan: it would have nothing to suggest, and could fire before
        // notification permission is answered and be spent unseen.
        guard let disk, report != nil else { return }
        if alertState.evaluate(free: disk.free, limit: config.alertLimitBytes) {
            Notifier.lowDisk(free: disk.free, limitGB: config.alertBelowGB, report: report)
        }
        saveAlertState()
    }

    private func loadConfig() {
        do {
            config = try Config.load()
            let unknown = (try? Data(contentsOf: Config.fileURL)).map(Config.unknownKeys) ?? []
            configError = unknown.isEmpty ? nil
                : "config.json: unknown \(unknown.count == 1 ? "key" : "keys") \(unknown.joined(separator: ", "))"
        } catch {
            configError = Self.describe(error) + ", using defaults"
        }
    }

    /// A config error in the words of the file, not of Swift's decoder.
    private static func describe(_ error: Error) -> String {
        let key = { (context: DecodingError.Context) in context.codingPath.map(\.stringValue).joined(separator: ".") }
        switch error {
        case DecodingError.typeMismatch(let type, let context):
            return "config.json: \(key(context)) should be \(kind(type))"
        case DecodingError.dataCorrupted(let context) where !context.codingPath.isEmpty:
            return "config.json: \(key(context)) has a bad value"
        default:
            return "config.json is not valid JSON"
        }
    }

    private static func kind(_ type: Any.Type) -> String {
        switch type {
        case is Int.Type: "a whole number"
        case is [String].Type: "a list of folders"
        case is String.Type: "text"
        default: "a different kind of value"
        }
    }

    private func saveAlertState() {
        UserDefaults.standard.set(try? JSONEncoder().encode(alertState), forKey: Self.alertStateKey)
    }
}
