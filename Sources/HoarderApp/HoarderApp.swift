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

        Settings {
            SettingsView(monitor: monitor)
        }
    }
}

/// Free space next to a drive icon. Template-rendered normally, so it follows the menu bar's appearance;
/// amber under the limit and red under a quarter of it, which needs a pre-rendered image because the
/// menu bar ignores view tints.
struct MenuBarLabel: View {
    let monitor: Monitor
    @Environment(\.colorScheme) private var menuBarScheme

    private var local: Machine { monitor.local }

    var body: some View {
        let free = local.disk.map { gigabytes($0.free, unit: "G") } ?? "–"
        // One low device is named, so the menu bar says which without opening the popover; a long
        // name gives way in the middle to keep the label short.
        let low = monitor.lowDevices
        let text = switch low.count {
        case 0: free
        case 1: "\(free) · \(middleTruncated(low[0].name, to: 14)) low"
        case let count: "\(free) · \(count) low"
        }
        Group {
            if let color = warning {
                Image(nsImage: tinted(label(text), color))
            } else {
                label(text)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    /// The menu bar is light or dark independently of the popover, so the tint follows it. Another
    /// device under its limit tints it amber too; only this Mac turns it red.
    private var warning: Color? {
        let light = menuBarScheme == .light
        if local.isCritical { return light ? Theme.redOnLight : Theme.red }
        if local.isLow || !monitor.lowDevices.isEmpty { return light ? Theme.amberOnLight : Theme.amber }
        return nil
    }

    private var spoken: String {
        let low = monitor.lowDevices
        let others = switch low.count {
        case 0: ""
        case 1: ", \(low[0].name) low"
        case let count: ", \(count) other devices low"
        }
        guard let disk = local.disk else { return "Hoarder, free space unknown" + others }
        return "Hoarder, " + freeSpace(disk.free, limitGB: local.alertBelowGB, low: local.isLow, critical: local.isCritical) + others
    }

    /// Critical swaps the drive for a warning sign, so it differs from low by shape, not only colour.
    private func label(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: local.isCritical ? "exclamationmark.triangle.fill" : "internaldrive")
            Text(text)
        }
        .font(Font(NSFont.menuBarFont(ofSize: 0)))
    }

    private func tinted(_ label: some View, _ color: Color) -> NSImage {
        let renderer = ImageRenderer(content: label.foregroundStyle(color))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = false
        return image
    }
}

/// "build-r…-ci-01": a name cut in the middle, so both its start and its distinctive end survive.
func middleTruncated(_ text: String, to limit: Int) -> String {
    guard text.count > limit, limit > 1 else { return text }
    let keep = limit - 1
    return text.prefix((keep + 1) / 2) + "…" + text.suffix(keep / 2)
}
