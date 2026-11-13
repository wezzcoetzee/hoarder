import Foundation

public enum Category: String, Codable, Sendable, CaseIterable {
    case worktree, nodeModules, docker, cache

    public var label: String {
        switch self {
        case .worktree: "Worktrees"
        case .nodeModules: "node_modules"
        case .docker: "Docker"
        case .cache: "Caches"
        }
    }
}

/// How confident Hoarder is that the space can go.
public enum Verdict: String, Codable, Sendable, Comparable {
    /// Nothing is lost by deleting it now.
    case reclaimable
    /// Probably dead weight, but a human should glance at it first.
    case review
    /// In use. Shown so the size is visible, never suggested for cleanup.
    case keep

    private var rank: Int {
        switch self {
        case .reclaimable: 0
        case .review: 1
        case .keep: 2
        }
    }

    public static func < (lhs: Verdict, rhs: Verdict) -> Bool { lhs.rank < rhs.rank }
}

public struct Finding: Codable, Sendable, Identifiable {
    public let category: Category
    public let title: String
    public let detail: String
    /// Filesystem paths the finding covers. Empty for things that live elsewhere, like Docker's VM.
    public let paths: [String]
    public internal(set) var bytes: Int64
    public let lastActivity: Date?
    public let verdict: Verdict
    /// The shell command that reclaims the space. Hoarder shows it and runs it only after the user confirms.
    public let cleanup: String?

    public var id: String { "\(category.rawValue):\(paths.first ?? title)" }
}

public struct Report: Codable, Sendable {
    public let findings: [Finding]
    /// Scanners that could not run, such as Docker when the daemon is stopped.
    public let notes: [String]
    public let scannedAt: Date
    public let duration: TimeInterval

    /// Bytes per verdict. A path nested inside another counted path is skipped, so a worktree and the
    /// node_modules inside it are not counted twice.
    public func total(_ verdict: Verdict, in category: Category? = nil) -> Int64 {
        let matching = findings.filter { $0.verdict == verdict && (category == nil || $0.category == category) }
        var counted: [String] = []
        var sum: Int64 = 0
        for finding in matching.sorted(by: { ($0.paths.first?.count ?? 0) < ($1.paths.first?.count ?? 0) }) {
            if let path = finding.paths.first, counted.contains(where: { path.hasPrefix($0 + "/") }) { continue }
            counted.append(contentsOf: finding.paths)
            sum += finding.bytes
        }
        return sum
    }
}

public extension Report {
    /// The report after a finding was cleaned, so the list updates without waiting for a rescan.
    func removing(_ finding: Finding) -> Report {
        Report(findings: findings.filter { $0.id != finding.id }, notes: notes, scannedAt: scannedAt, duration: duration)
    }
}

/// One format for every size: whole MB under 1 GB, otherwise GB to one decimal, so a column of sizes lines up.
public func formatBytes(_ bytes: Int64) -> String {
    let gigabytes = Double(bytes) / 1e9
    return gigabytes < 1 ? "\(Int((gigabytes * 1000).rounded())) MB" : String(format: "%.1f GB", gigabytes)
}
