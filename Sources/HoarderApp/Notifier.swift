import Foundation
import HoarderCore
import UserNotifications

/// Low-disk notifications. macOS only grants them to a bundled app, so a bare `swift run` skips them.
enum Notifier {
    private static let available = Bundle.main.bundleIdentifier != nil
    private static let delegate = ForegroundBanners()

    /// Asks for permission at launch, so the prompt never interrupts the moment the disk runs low.
    static func setUp() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        Task { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
    }

    static func lowDisk(free: Int64, limitGB: Int, report: Report?) {
        guard available else { return }
        let title = "\(gigabytes(free)) free"
        var body = "Under your \(limitGB) GB limit."
        if let report, let biggest = report.findings.first(where: { $0.verdict == .reclaimable }) {
            body = "\(formatBytes(report.total(.reclaimable))) is safe to clean. \(biggest.title) is \(formatBytes(biggest.bytes))."
        }
        Task {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            try? await UNUserNotificationCenter.current()
                .add(UNNotificationRequest(identifier: "low-disk", content: content, trigger: nil))
        }
    }
}

/// Without this, macOS hides the banner while the popover is open, because the app is frontmost then.
private final class ForegroundBanners: NSObject, UNUserNotificationCenterDelegate, Sendable {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// Whole gigabytes, one decimal under 10 GB, the way the menu bar shows it.
func gigabytes(_ bytes: Int64, unit: String = " GB") -> String {
    let value = Double(bytes) / 1e9
    return (value < 10 ? String(format: "%.1f", value) : String(Int(value.rounded()))) + unit
}
