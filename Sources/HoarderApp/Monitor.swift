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

    private static let alertStateKey = "alertState"

    init() {
        alertState = UserDefaults.standard.data(forKey: Self.alertStateKey)
            .flatMap { try? JSONDecoder().decode(AlertState.self, from: $0) } ?? AlertState()
        Notifier.setUp()
        Task { await run() }
    }

    /// A still monitor for `--snapshot`: shows a saved report, never scans, alerts or cleans.
    init(preview report: Report) {
        alertState = AlertState()
        self.report = report
    }

    var isLow: Bool { disk.map { $0.free < config.alertLimitBytes } ?? false }

    func scan() async {
        guard !scanning else { return }
        scanning = true
        loadConfig()
        report = await Hoarder.scan(config: config)
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

    private func run() async {
        await scan()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            refreshDisk()
            let due = report.map { Date.now.timeIntervalSince($0.scannedAt) >= Double(config.scanEveryMinutes) * 60 } ?? true
            if due { await scan() }
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
