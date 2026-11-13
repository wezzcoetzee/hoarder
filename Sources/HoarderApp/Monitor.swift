import AppKit
import HoarderCore
import Observation
import ServiceManagement

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
    private(set) var configError: String?
    private(set) var cleanError: String?
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
         cleaning: Set<Finding.ID>, cleanError: String?) {
        self.report = report
        self.disk = disk
        self.config = config
        self.alertState = alertState
        self.scanning = scanning
        self.cleaning = cleaning
        self.cleanError = cleanError
    }

    var isLow: Bool { disk.map { $0.free < config.alertLimitBytes } ?? false }

    func scan() async {
        guard !scanning else { return }
        scanning = true
        cleanedDuringScan = []
        loadConfig()
        let fresh = await Hoarder.scan(config: config)
        report = cleanedDuringScan.reduce(fresh) { report, id in
            report.findings.first { $0.id == id }.map(report.removing) ?? report
        }
        scanning = false
        refreshDisk()
    }

    func clean(_ finding: Finding) async {
        cleaning.insert(finding.id)
        cleanError = nil
        let result = await Hoarder.clean(finding)
        cleaning.remove(finding.id)
        if result.ok {
            report = report?.removing(finding)
            if scanning { cleanedDuringScan.insert(finding.id) }
        } else {
            cleanError = "\(finding.title) failed: \(result.output.suffix(240))"
        }
        refreshDisk()
    }

    func snooze() {
        alertState.snooze(until: .now.addingTimeInterval(86_400))
        saveAlertState()
    }

    func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            cleanError = "Open at login: \(error.localizedDescription)"
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

    /// Free space every minute, independent of scans, so an alert never waits on a 45s scan.
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
        disk = DiskSpace.current()
        guard let disk else { return }
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
            configError = "config.json is invalid, using defaults."
        }
    }

    private func saveAlertState() {
        UserDefaults.standard.set(try? JSONEncoder().encode(alertState), forKey: Self.alertStateKey)
    }
}
