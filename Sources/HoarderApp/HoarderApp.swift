import AppKit
import HoarderCore
import SwiftUI

@main
enum Entry {
    static func main() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--snapshot"), arguments.count > flag + 2 else {
            HoarderApp.main()
            return
        }
        MainActor.assumeIsolated {
            do {
                try Snapshot.render(report: arguments[flag + 1], to: arguments[flag + 2],
                                    state: arguments.count > flag + 3 ? arguments[flag + 3] : nil)
            } catch {
                FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
                exit(1)
            }
        }
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
/// amber under the limit and red under a quarter of it, which needs a pre-rendered image because the
/// menu bar ignores view tints.
struct MenuBarLabel: View {
    let monitor: Monitor
    @Environment(\.colorScheme) private var menuBarScheme

    var body: some View {
        let text = monitor.disk.map { gigabytes($0.free, unit: "G") } ?? "–"
        Group {
            if let color = warning {
                Image(nsImage: tinted(text, color))
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "internaldrive")
                    Text(text)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    /// The menu bar is light or dark independently of the popover, so the tint follows it.
    private var warning: Color? {
        let light = menuBarScheme == .light
        if monitor.isCritical { return light ? Theme.redOnLight : Theme.red }
        if monitor.isLow { return light ? Theme.amberOnLight : Theme.amber }
        return nil
    }

    private var spoken: String {
        guard let disk = monitor.disk else { return "Hoarder, free space unknown" }
        return "Hoarder, " + freeSpace(disk.free, limitGB: monitor.config.alertBelowGB, low: monitor.isLow)
    }

    private func tinted(_ text: String, _ color: Color) -> NSImage {
        let label = HStack(spacing: 4) {
            Image(systemName: "internaldrive")
            Text(text)
        }
        .font(.system(size: 13))
        .foregroundStyle(color)
        let renderer = ImageRenderer(content: label)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = false
        return image
    }
}
