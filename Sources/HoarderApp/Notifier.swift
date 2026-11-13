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

    /// Whether the user turned Hoarder's notifications off in System Settings.
    static func isDenied() async -> Bool {
        guard available else { return false }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=dev.hoarder.app")!

    static func lowDisk(free: Int64, limitGB: Int, report: Report?) {
        guard available else { return }
        let title = freeSpace(free, limitGB: limitGB, low: true)
        let body = report.map(suggestion) ?? "Open Hoarder to see what can go."
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

extension Finding {
    /// The title with its category, since "Build cache" alone does not say whose. Reads mid-sentence.
    var fullName: String {
        switch category {
        case .docker: "Docker " + title.prefix(1).lowercased() + title.dropFirst()
        case .worktree: "worktree " + title
        case .nodeModules: "node_modules in " + title
        case .cache: title
        }
    }
}

/// The one free-space sentence: popover heading, notification title, and the menu bar's spoken label.
func freeSpace(_ free: Int64, limitGB: Int, low: Bool) -> String {
    low ? "\(gigabytes(free)) free, under your \(limitGB) GB limit" : "\(gigabytes(free)) free"
}

/// What to clean first. A Docker prune frees space inside Docker's disk rather than on the Mac, so
/// the biggest other row is named when there is one. Findings are sorted largest first.
private func suggestion(_ report: Report) -> String {
    let safe = report.findings.filter { $0.verdict == .reclaimable }
    if let biggest = safe.first(where: { $0.category != .docker }) ?? safe.first {
        let docker = report.total(.reclaimable, in: .docker)
        let inside = docker > 0 ? " (\(formatBytes(docker)) inside Docker's disk)" : ""
        return "\(formatBytes(report.total(.reclaimable))) is safe to clean\(inside). Biggest: \(biggest.fullName), \(formatBytes(biggest.bytes))."
    }
    let review = report.total(.review)
    return review > 0 ? "Nothing is safe to clean. \(formatBytes(review)) to review." : "Nothing to clean right now."
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
