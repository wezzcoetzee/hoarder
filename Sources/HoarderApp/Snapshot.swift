import AppKit
import HoarderCore
import SwiftUI

/// `HoarderApp --snapshot <report.json|none> <out.png> [state.json]` renders the popover from a saved
/// `hoarder --json` report, and the menu bar label beside it as `<out>-menubar.png`, to check the UI
/// without opening the menu bar. `none` shows the first scan. The state file sets everything else.
enum Snapshot {
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
    }

    @MainActor
    static func render(report path: String, to output: String, state statePath: String?) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = path == "none" ? nil : try decoder.decode(Report.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let state = try statePath.map { try JSONDecoder().decode(State.self, from: Data(contentsOf: URL(fileURLWithPath: $0))) } ?? State()

        var config = Config()
        config.alertBelowGB = state.alertBelowGB ?? config.alertBelowGB
        var alertState = AlertState()
        let disk = DiskSpace(free: Int64((state.freeGB ?? 22) * 1e9), total: 994_000_000_000)
        // As in the app: the alert is sent once a report exists, unless snoozed.
        if state.snoozed == true {
            alertState.snooze(until: .now.addingTimeInterval(86_400))
        } else if report != nil {
            _ = alertState.evaluate(free: disk.free, limit: config.alertLimitBytes)
        }
        let monitor = Monitor(preview: report, disk: disk,
                              config: config, alertState: alertState, scanning: state.scanning ?? false,
                              cleaning: cleaningNames(state.cleaning, in: report), failures: state.failures ?? [:], lastCleaned: state.lastCleaned,
                              lastFailed: state.lastFailed,
                              notificationsOff: state.notificationsOff ?? false)

        _ = NSApplication.shared
        let popover = PopoverView(monitor: monitor, hovered: state.hovered, confirming: state.confirming,
                                  confirmingSafe: state.confirmingSafe ?? false,
                                  expanded: Set(state.expanded ?? []),
                                  showingKept: Set(state.showingKept ?? []), listCap: state.full == true ? .infinity : 470)
        try write(popover, to: output)
        let label = MenuBarLabel(monitor: monitor)
            .padding(.horizontal, 10).frame(height: 24).background(Color(white: 0.16))
        try write(label, to: output.replacingOccurrences(of: ".png", with: "-menubar.png"))
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
