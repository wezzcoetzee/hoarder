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
