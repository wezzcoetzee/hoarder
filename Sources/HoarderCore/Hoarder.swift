import Foundation

public enum Hoarder {
    /// Runs every scanner concurrently. Read-only: nothing on disk is changed. `finished` hears each
    /// category as its scanner completes, in whatever order they do, so a first scan can say how far
    /// it has got without inventing a percentage.
    public static func scan(config: Config, finished: (@Sendable (Category) -> Void)? = nil) async -> Report {
        let start = Date.now
        func reporting<T>(_ category: Category, _ work: () async -> T) async -> T {
            let result = await work()
            finished?(category)
            return result
        }
        async let worktrees = reporting(.worktree) { await WorktreeScanner.scan(config) }
        async let nodeModules = reporting(.nodeModules) { await NodeModulesScanner.scan(config) }
        async let caches = reporting(.cache) { await CacheScanner.scan() }
        async let docker = reporting(.docker) { await DockerScanner.scan() }

        let dependencies = await nodeModules
        let findings = await including(dependencies, in: worktrees) + dependencies + caches + docker.findings
        let notes = await docker.daemonDown ? [KnownState.startDocker] : []

        return Report(findings: findings.sorted { ($0.verdict, -$0.bytes) < ($1.verdict, -$1.bytes) },
                      notes: notes, scannedAt: start, duration: Date.now.timeIntervalSince(start))
    }

    /// Runs a finding's cleanup command in a login shell, so the user's tool PATH applies.
    /// The only call in Hoarder that changes the disk; the app calls it after the user confirms, kept
    /// rows included.
    public static func clean(_ finding: Finding) async -> (ok: Bool, output: String) {
        guard let command = finding.cleanup else { return (false, "Nothing to run for \(finding.title).") }
        let output = await Shell.run("zsh", ["-lc", command], includeErrors: true, timeout: 1800)
        return (output.ok, output.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// What a row's second look found after its cleanup was refused.
    public enum Recheck: Sendable {
        /// The folder is gone, so nothing is left to clean.
        case gone
        /// The row as a scan would show it now, with the command that matches.
        case judged(Finding)
        /// Not checked; the next scan will say.
        case unchecked
    }

    /// Checks one row again without a full scan. Worktrees only: git refuses one that changed since the
    /// scan, and reading its state again takes a moment, where a scan walks every node_modules. The size
    /// is kept from the scan.
    public static func recheck(_ finding: Finding, config: Config) async -> Recheck {
        guard finding.category == .worktree, finding.paths.count == 1, let path = finding.paths.first else { return .unchecked }
        guard FileManager.default.fileExists(atPath: path) else { return .gone }
        let fresh = await WorktreeScanner.recheck(path: path, bytes: finding.bytes, staleAfterDays: config.staleWorktreeDays)
        return fresh.map(Recheck.judged) ?? .unchecked
    }

    /// Worktrees are walked without node_modules, so each one gets the node_modules inside it added back:
    /// removing a worktree frees both.
    private static func including(_ dependencies: [Finding], in worktrees: [Finding]) -> [Finding] {
        worktrees.map { worktree in
            guard let root = worktree.paths.first else { return worktree }
            var sized = worktree
            sized.bytes += dependencies.filter { $0.paths.first?.hasPrefix(root + "/") == true }.reduce(0) { $0 + $1.bytes }
            return sized
        }
    }
}
