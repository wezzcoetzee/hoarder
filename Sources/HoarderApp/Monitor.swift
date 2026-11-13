import AppKit
import HoarderCore
import Observation
import ServiceManagement
import SwiftUI

/// Owns the app's state: every machine (this Mac first, then config.json's devices), which one the
/// popover shows, and the settings that are not per machine. Free space is checked every minute and
/// each machine rescanned on the configured interval.
@Observable @MainActor
final class Monitor {
    private(set) var machines: [Machine]
    var selectedID = Machine.localID
    private(set) var config = Config()
    private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled
    /// Shown in the header. Kept apart, because config is re-read every minute and must not wipe a
    /// login error.
    private(set) var configError: String?
    /// config.json does not parse, so Settings stays read-only rather than overwrite the hand edit.
    private(set) var configInvalid = false
    private(set) var loginError: String?
    /// The user turned Hoarder's notifications off, so low-disk alerts cannot arrive.
    private(set) var notificationsOff = false

    /// What a device installs: this app's version, and any hoarder binaries bundled beside it.
    private static let build = Remote.Build(
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
        binaries: Bundle.main.resourceURL)

    init() {
        machines = [Machine()]
        Notifier.setUp()
        loadConfig()
        Task { await watchDisk() }
        Task { await scanOnSchedule() }
    }

    /// A still monitor for `--snapshot`: shows the given machines, never scans, alerts or cleans.
    init(preview machines: [Machine], selected: Machine.ID, config: Config, notificationsOff: Bool) {
        self.machines = machines
        self.config = config
        self.notificationsOff = notificationsOff
        selectedID = selected
    }

    var local: Machine { machines[0] }
    var selected: Machine { machines.first { $0.id == selectedID } ?? local }
    /// Other devices under their limit, which the menu bar counts beside this Mac's free space.
    var lowDevices: Int { machines.dropFirst().filter(\.isLow).count }

    /// Rescans the machine the popover shows.
    func scan() async {
        loadConfig()
        await selected.scan()
    }

    func dismissCleaned() {
        machines.forEach { $0.dismissCleaned() }
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

    /// Every Settings control goes through here: it writes config.json and applies it at once.
    func updateConfig(_ change: (inout Config) -> Void) {
        guard !configInvalid else { return }
        var next = config
        change(&next)
        do {
            try next.save()
            loadConfig()
        } catch {
            configError = "Could not save config.json: \(error.localizedDescription)"
        }
    }

    /// An empty folder list means the device uses its own config, so it is not stored as `[]`.
    func updateDevice(_ host: String, _ change: (inout Device) -> Void) {
        updateConfig { config in
            guard let index = config.devices.firstIndex(where: { $0.host == host }) else { return }
            change(&config.devices[index])
            if config.devices[index].projectRoots?.isEmpty == true { config.devices[index].projectRoots = nil }
        }
    }

    func addDevice(_ host: String) {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !host.hasPrefix("-"), !config.devices.contains(where: { $0.host == host }) else { return }
        updateConfig { $0.devices.append(Device(host: host)) }
        // Scanned now rather than on the next minute's tick, so Settings shows its status right away.
        if let machine = machines.first(where: { $0.id == host }) { Task { await machine.scan() } }
    }

    func removeDevice(_ host: String) {
        updateConfig { $0.devices.removeAll { $0.host == host } }
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
            loadConfig()
            for machine in machines { Task { await machine.refreshDisk() } }
            notificationsOff = await Notifier.isDenied()
            try? await Task.sleep(for: .seconds(60))
        }
    }

    /// Each machine on its own, so a slow device never holds up this Mac's scan.
    private func scanOnSchedule() async {
        while !Task.isCancelled {
            for machine in machines where machine.isScanDue() { Task { await machine.scan() } }
            try? await Task.sleep(for: .seconds(60))
        }
    }

    private func loadConfig() {
        do {
            config = try Config.load()
            let unknown = (try? Data(contentsOf: Config.fileURL)).map(Config.unknownKeys) ?? []
            configError = unknown.isEmpty ? nil
                : "config.json: unknown \(unknown.count == 1 ? "key" : "keys") \(unknown.joined(separator: ", "))"
            configInvalid = false
        } catch {
            configError = Self.describe(error) + ", using defaults"
            configInvalid = true
        }
        syncMachines()
    }

    /// Machines follow config.json's devices: kept ones keep their state, new ones start scanning on
    /// the next tick, removed ones go.
    private func syncMachines() {
        var seen: Set<String> = []
        let devices = config.devices.filter { !$0.host.isEmpty && !$0.host.hasPrefix("-") && seen.insert($0.host).inserted }
        let existing = Dictionary(uniqueKeysWithValues: machines.map { ($0.id, $0) })
        machines = [local] + devices.map { device in
            let machine = existing[device.host] ?? Machine(device: device, build: Self.build)
            machine.device = device
            return machine
        }
        machines.forEach { $0.config = config }
        if !machines.contains(where: { $0.id == selectedID }) { selectedID = Machine.localID }
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
}
