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
    private(set) var cleaning: Set<Finding.ID> = []
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
         cleaning: Set<Finding.ID>, failures: [Finding.ID: String], lastCleaned: String?) {
        self.report = report
        self.disk = disk
        self.config = config
        self.alertState = alertState
        self.scanning = scanning
        self.cleaning = cleaning
        self.failures = failures
        self.lastCleaned = lastCleaned
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
        let present = Set(current.findings.map(\.id))
        failures = failures.filter { present.contains($0.key) }
        scanning = false
        refreshDisk()
    }

    func clean(_ finding: Finding) async {
        cleaning.insert(finding.id)
        failures[finding.id] = nil
        let result = await Hoarder.clean(finding)
        cleaning.remove(finding.id)
        if result.ok {
            report = report?.removing(finding)
            if scanning { cleanedDuringScan.insert(finding.id) }
            let message = "Cleaned \(finding.fullName), \(formatBytes(finding.bytes))"
            lastCleaned = message
            AccessibilityNotification.Announcement(message).post()
        } else {
            let lastLine = result.output.split(separator: "\n").last.map(String.init) ?? "exited with an error"
            failures[finding.id] = String(lastLine.prefix(240))
            AccessibilityNotification.Announcement("\(finding.fullName) not cleaned").post()
        }
        refreshDisk()
    }

    /// The success line has been seen once the popover closes.
    func dismissCleaned() {
        lastCleaned = nil
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
            configError = nil
        } catch {
            configError = "config.json \(Self.describe(error)), using defaults"
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.typeMismatch(let type, let context):
            "has the wrong type for \(context.codingPath.map(\.stringValue).joined(separator: ".")), expected \(type)"
        default:
            "is not valid JSON"
        }
    }

    private func saveAlertState() {
        UserDefaults.standard.set(try? JSONEncoder().encode(alertState), forKey: Self.alertStateKey)
    }
}
