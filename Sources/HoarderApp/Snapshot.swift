import AppKit
import HoarderCore
import SwiftUI

/// `HoarderApp --snapshot <report.json|none> <out.png> [state.json]` renders the popover from a saved
/// `hoarder --json` report, and the menu bar label beside it as `<out>-menubar.png`, to check the UI
/// without opening the menu bar. `none` shows the first scan. The state file sets everything else; the
/// report and the per-row keys apply to this Mac, and `devices` adds the device strip.
enum Snapshot {
    struct DeviceState: Decodable {
        var host: String
        var freeGB: Double?
        var alertBelowGB: Int?
        /// Shown in the header and marks the device unreachable in the strip.
        var problem: String?
        /// `uname -sm`, lowercased: "linux x86_64".
        var platform: String?
        var projectRoots: [String]?
    }

    /// Every key is optional.
    struct State: Decodable {
        var freeGB: Double?
        var alertBelowGB: Int?
        var scanning: Bool?
        var snoozed: Bool?
        var hovered: Finding.ID?
        var confirming: Finding.ID?
        /// "Clean all safe" pressed, showing Run.
        var confirmingSafe: Bool?
        var cleaning: Finding.ID?
        var expanded: [HoarderCore.Category]?
        /// Sections whose "N in use" row is open.
        var showingKept: [HoarderCore.Category]?
        /// Finding id to the error shown under that row.
        var failures: [Finding.ID: String]?
        var lastCleaned: String?
        var lastFailed: String?
        var notificationsOff: Bool?
        /// Shows the whole list instead of capping it at the popover's scroll height.
        var full: Bool?
        var devices: [DeviceState]?
        /// Renders the Settings window instead: "general", "local", or a device's host.
        var settings: String?
    }

    @MainActor
    static func render(report path: String, to output: String, state statePath: String?) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = path == "none" ? nil : try decoder.decode(Report.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let state = try statePath.map { try JSONDecoder().decode(State.self, from: Data(contentsOf: URL(fileURLWithPath: $0))) } ?? State()

        var config = Config()
        config.alertBelowGB = state.alertBelowGB ?? config.alertBelowGB
        config.devices = (state.devices ?? []).map { Device(host: $0.host, alertBelowGB: $0.alertBelowGB, projectRoots: $0.projectRoots) }
        let disk = DiskSpace(free: Int64((state.freeGB ?? 22) * 1e9), total: 994_000_000_000)
        let local = Machine(preview: nil, report: report, disk: disk, config: config,
                            alertState: alertState(free: disk.free, limitGB: config.alertBelowGB,
                                                   alerted: report != nil, snoozed: state.snoozed == true),
                            scanning: state.scanning ?? false, cleaning: cleaningNames(state.cleaning, in: report),
                            failures: state.failures ?? [:], lastCleaned: state.lastCleaned,
                            lastFailed: state.lastFailed, problem: nil)
        let devices = (state.devices ?? []).map { device in
            let disk = device.freeGB.map { DiskSpace(free: Int64($0 * 1e9), total: 226_000_000_000) }
            let limit = device.alertBelowGB ?? config.alertBelowGB
            let machine = Machine(preview: device.host, report: nil, disk: disk, config: config,
                                  alertState: alertState(free: disk?.free ?? .max, limitGB: limit, alerted: true, snoozed: false),
                                  scanning: false, cleaning: [:], failures: [:], lastCleaned: nil, lastFailed: nil,
                                  problem: device.problem, platform: platform(device.platform))
            machine.device = config.devices.first { $0.host == device.host }
            return machine
        }
        let monitor = Monitor(preview: [local] + devices, selected: Machine.localID, config: config,
                              notificationsOff: state.notificationsOff ?? false)

        _ = NSApplication.shared
        if let page = state.settings {
            let target: SettingsView.Page = page == "general" ? .general : .machine(page)
            try write(SettingsView(monitor: monitor, page: target), to: output)
            return
        }
        let popover = PopoverView(monitor: monitor, hovered: state.hovered, confirming: state.confirming,
                                  confirmingSafe: state.confirmingSafe ?? false,
                                  expanded: Set(state.expanded ?? []),
                                  showingKept: Set(state.showingKept ?? []), listCap: state.full == true ? .infinity : 470)
        try write(popover, to: output)
        let label = MenuBarLabel(monitor: monitor)
            .padding(.horizontal, 10).frame(height: 24).background(Color(white: 0.16))
        try write(label, to: output.replacingOccurrences(of: ".png", with: "-menubar.png"))
    }

    private static func platform(_ uname: String?) -> Remote.Platform? {
        let parts = uname?.split(separator: " ").map(String.init) ?? []
        return parts.count == 2 ? Remote.Platform(os: parts[0], arch: parts[1]) : nil
    }

    /// As in the app: the alert is sent once a report exists, unless snoozed.
    private static func alertState(free: Int64, limitGB: Int, alerted: Bool, snoozed: Bool) -> AlertState {
        var state = AlertState()
        if snoozed {
            state.snooze(until: .now.addingTimeInterval(86_400))
        } else if alerted {
            _ = state.evaluate(free: free, limit: Int64(limitGB) * 1_000_000_000)
        }
        return state
    }

    private static func cleaningNames(_ id: Finding.ID?, in report: Report?) -> [Finding.ID: String] {
        guard let id, let finding = report?.findings.first(where: { $0.id == id }) else { return [:] }
        return [id: finding.fullName]
    }

    /// Lays the view out twice with the run loop turning in between, so measured sizes settle.
    @MainActor
    private static func write(_ content: some View, to output: String) throws {
        let view = NSHostingView(rootView: content.environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        for _ in 0..<2 {
            window.setContentSize(view.fittingSize)
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: .now.addingTimeInterval(0.2))
        }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
    }
}
