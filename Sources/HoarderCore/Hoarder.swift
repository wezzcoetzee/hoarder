import Foundation

public enum Hoarder {
    /// Runs every scanner concurrently. Read-only: nothing on disk is changed.
    public static func scan(config: Config) async -> Report {
        let start = Date.now
        async let worktrees = WorktreeScanner.scan(config)
        async let nodeModules = NodeModulesScanner.scan(config)
        async let caches = CacheScanner.scan()
        async let docker = DockerScanner.scan()

        let dependencies = await nodeModules
        let findings = await including(dependencies, in: worktrees) + dependencies + caches + docker.findings
        let notes = await docker.daemonDown ? ["Start Docker to see what it can clean"] : []

        return Report(findings: findings.sorted { ($0.verdict, -$0.bytes) < ($1.verdict, -$1.bytes) },
                      notes: notes, scannedAt: start, duration: Date.now.timeIntervalSince(start))
    }

    /// Runs a finding's cleanup command in a login shell, so the user's tool PATH applies.
    /// The only call in Hoarder that changes the disk; the app calls it after the user confirms.
    public static func clean(_ finding: Finding) async -> (ok: Bool, output: String) {
        guard finding.verdict != .keep else { return (false, "\(finding.title) is in use.") }
        guard let command = finding.cleanup else { return (false, "Nothing to run for \(finding.title).") }
        let output = await Shell.run("zsh", ["-lc", command], includeErrors: true, timeout: 1800)
        return (output.ok, output.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
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
