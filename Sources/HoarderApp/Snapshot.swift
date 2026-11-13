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
        var cleaning: Finding.ID?
        var expanded: [HoarderCore.Category]?
        var cleanError: String?
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
        if state.snoozed == true { alertState.snooze(until: .now.addingTimeInterval(86_400)) }
        let monitor = Monitor(preview: report,
                              disk: DiskSpace(free: Int64((state.freeGB ?? 22) * 1e9), total: 994_000_000_000),
                              config: config, alertState: alertState, scanning: state.scanning ?? false,
                              cleaning: Set([state.cleaning].compactMap { $0 }), cleanError: state.cleanError)

        _ = NSApplication.shared
        let popover = PopoverView(monitor: monitor, hovered: state.hovered, confirming: state.confirming,
                                  expanded: Set(state.expanded ?? []), listCap: state.full == true ? .infinity : 470)
        try write(popover, to: output)
        let label = MenuBarLabel(monitor: monitor)
            .padding(.horizontal, 10).frame(height: 24).background(Color(white: 0.16))
        try write(label, to: output.replacingOccurrences(of: ".png", with: "-menubar.png"))
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
