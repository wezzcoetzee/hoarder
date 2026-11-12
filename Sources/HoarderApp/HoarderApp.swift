import AppKit
import HoarderCore
import SwiftUI

@main
enum Entry {
    /// `HoarderApp --snapshot <report.json> <out.png>` renders the popover from a saved
    /// `hoarder --json` report, to check the UI without opening the menu bar.
    static func main() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--snapshot"), arguments.count > flag + 2 else {
            HoarderApp.main()
            return
        }
        MainActor.assumeIsolated {
            do {
                try snapshot(report: arguments[flag + 1], to: arguments[flag + 2])
            } catch {
                FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
                exit(1)
            }
        }
    }

    @MainActor
    private static func snapshot(report path: String, to output: String) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(Report.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        _ = NSApplication.shared
        let view = NSHostingView(rootView: PopoverView(monitor: Monitor(preview: report)))
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.setContentSize(view.fittingSize)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
    }
}

struct HoarderApp: App {
    @State private var monitor = Monitor()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(monitor: monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Free space next to a drive icon. Template-rendered normally, so it follows the menu bar's appearance;
/// amber under the limit, which needs a pre-rendered image because the menu bar ignores view tints.
struct MenuBarLabel: View {
    let monitor: Monitor

    var body: some View {
        let text = monitor.disk.map { gigabytes($0.free, unit: "G") } ?? "–"
        if monitor.isLow {
            Image(nsImage: amber(text))
        } else {
            HStack(spacing: 4) {
                Image(systemName: "internaldrive")
                Text(text)
            }
        }
    }

    private func amber(_ text: String) -> NSImage {
        let label = HStack(spacing: 4) {
            Image(systemName: "internaldrive")
            Text(text)
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.amber)
        let renderer = ImageRenderer(content: label)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = false
        return image
    }
}
