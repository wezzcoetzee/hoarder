import Foundation

/// Linked git worktrees left behind by agents (t3, claude, codex, cursor) and by hand.
/// Repos are enumerated through `git worktree list`, because orphans (registration left, directory
/// gone) are invisible to the filesystem.
enum WorktreeScanner {
    struct Entry: Equatable {
        var path: String
        var branch: String?
        var locked = false
    }

    struct Worktree {
        let repo: String
        let gitDir: String
        let entry: Entry
        let present: Bool
        let dirty: Bool
        let merged: Bool
        let pushed: Bool
        let tip: Date?
    }

    static func scan(_ config: Config) async -> [Finding] {
        let dotGits = await Git.dotGits(under: config.existingRoots)
        let repos = Set(dotGits.compactMap(Git.commonDir(forDotGit:)))

        let worktrees = await withTaskGroup(of: [Worktree].self) { group in
            for repo in repos { group.addTask { await inspect(gitDir: repo) } }
            return await group.reduce(into: []) { $0 += $1 }
        }
        // node_modules is sized once by NodeModulesScanner and folded back in by Hoarder.scan.
        let sizes = await Shell.sizes(of: worktrees.filter(\.present).map(\.entry.path), excluding: "node_modules")
        // `worktree prune` clears every orphan in a repo at once, so each repo's orphans share one row.
        let isOrphan = { (worktree: Worktree) in !worktree.present && !worktree.entry.locked }
        let orphans = Dictionary(grouping: worktrees.filter(isOrphan), by: \.gitDir).values.map(orphanFinding)
        return worktrees.filter { !isOrphan($0) }
            .map { finding(for: $0, bytes: sizes[$0.entry.path] ?? 0, staleAfterDays: config.staleWorktreeDays) } + orphans
    }

    /// Parses `git worktree list --porcelain -z`, dropping the first block: the main worktree.
    /// NUL-separated, so a path containing a newline stays one path.
    static func parse(porcelain: String) -> [Entry] {
        var entries: [Entry] = []
        for block in porcelain.components(separatedBy: "\0\0") {
            var entry: Entry?
            for line in block.split(separator: "\0") {
                if line.hasPrefix("worktree ") {
                    entry = Entry(path: String(line.dropFirst("worktree ".count)))
                } else if line.hasPrefix("branch refs/heads/") {
                    entry?.branch = String(line.dropFirst("branch refs/heads/".count))
                } else if line == "locked" || line.hasPrefix("locked ") {
                    entry?.locked = true
                }
            }
            if let entry { entries.append(entry) }
        }
        return Array(entries.dropFirst())
    }

    /// Checked in order: orphan, hold (dirty, locked, recent), merged, stale.
    static func classify(_ worktree: Worktree, staleAfterDays: Int, now: Date = .now) -> (Verdict, String) {
        let age = worktree.tip.map { days(since: $0, now: now) } ?? 0
        if !worktree.present && !worktree.entry.locked {
            return (.reclaimable, "orphan: directory gone, registration left")
        }
        if worktree.dirty { return (.keep, "uncommitted changes") }
        if worktree.entry.locked { return (.keep, "locked") }
        if age < staleAfterDays { return (.keep, "active, \(age)d old") }
        if worktree.merged { return (.reclaimable, "clean, merged, \(age)d old") }
        let unpushed = worktree.pushed ? "" : ", never pushed"
        return (.review, "clean, unmerged\(unpushed), \(age)d old")
    }

    private static func inspect(gitDir: String) async -> [Worktree] {
        let listing = await git(gitDir, "worktree", "list", "--porcelain", "-z")
        let entries = parse(porcelain: listing.stdout)
        guard !entries.isEmpty else { return [] }

        let base = await defaultBranch(gitDir)
        let merged: Set<String> = if let base {
            Set(await git(gitDir, "branch", "--format=%(refname:short)", "--merged=\(base)").stdout
                .split(separator: "\n").map(String.init))
        } else { [] }
        let repo = ((gitDir as NSString).deletingLastPathComponent as NSString).lastPathComponent

        return await withTaskGroup(of: Worktree.self) { group in
            for entry in entries {
                group.addTask {
                    let present = exists(entry.path)
                    let dirty = if present {
                        !(await gitIn(entry.path, "status", "--porcelain").stdout.isEmpty)
                    } else { false }
                    // A present worktree is asked about its own HEAD; via --git-dir, HEAD is the main checkout's.
                    let log = if present {
                        await gitIn(entry.path, "log", "-1", "--format=%ct", "HEAD")
                    } else {
                        await git(gitDir, "log", "-1", "--format=%ct", "--end-of-options", entry.branch ?? "HEAD")
                    }
                    let tip = TimeInterval(log.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                        .map(Date.init(timeIntervalSince1970:))
                    let pushed = if let branch = entry.branch {
                        await git(gitDir, "show-ref", "-q", "--verify", "refs/remotes/origin/\(branch)").ok
                    } else { false }
                    return Worktree(repo: repo, gitDir: gitDir, entry: entry, present: present, dirty: dirty,
                                    merged: entry.branch.map(merged.contains) ?? false, pushed: pushed, tip: tip)
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
    }

    private static func defaultBranch(_ gitDir: String) async -> String? {
        let head = await git(gitDir, "symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD")
        if head.ok { return head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
        for candidate in ["origin/main", "origin/master", "main", "master"] {
            if await git(gitDir, "rev-parse", "-q", "--verify", candidate).ok { return candidate }
        }
        return nil
    }

    /// A background scan must not start repo-configured fsmonitor helpers (or watchman daemons).
    private static let safeConfig = ["-c", "core.fsmonitor=false"]

    private static func git(_ gitDir: String, _ arguments: String...) async -> Shell.Output {
        await Shell.run("git", safeConfig + ["--git-dir=\(gitDir)"] + arguments)
    }

    private static func gitIn(_ worktree: String, _ arguments: String...) async -> Shell.Output {
        await Shell.run("git", safeConfig + ["-C", worktree] + arguments)
    }

    private static func finding(for worktree: Worktree, bytes: Int64, staleAfterDays: Int) -> Finding {
        let (verdict, detail) = classify(worktree, staleAfterDays: staleAfterDays)
        // No --force: git then refuses a worktree that picked up changes since the scan.
        let cleanup = worktree.present
            ? "git --git-dir=\(shellQuote(worktree.gitDir)) worktree remove \(shellQuote(worktree.entry.path))"
            : nil
        return Finding(category: .worktree, title: "\(worktree.repo) · \(worktree.entry.branch ?? "detached")",
                       detail: detail, paths: [worktree.entry.path], bytes: bytes, lastActivity: worktree.tip,
                       verdict: verdict, cleanup: cleanup)
    }

    private static func orphanFinding(_ orphans: [Worktree]) -> Finding {
        let first = orphans[0]
        let count = orphans.count == 1 ? "1 orphan" : "\(orphans.count) orphans"
        return Finding(category: .worktree, title: "\(first.repo) · \(count)",
                       detail: "directories gone, registrations left", paths: orphans.map(\.entry.path).sorted(),
                       bytes: 0, lastActivity: orphans.compactMap(\.tip).max(), verdict: .reclaimable,
                       cleanup: "git --git-dir=\(shellQuote(first.gitDir)) worktree prune")
    }
}
