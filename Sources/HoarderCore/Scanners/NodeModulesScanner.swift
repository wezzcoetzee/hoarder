import Foundation

/// node_modules folders, grouped by the project (git root) that owns them, so a monorepo is one row.
enum NodeModulesScanner {
    static func scan(_ config: Config) async -> [Finding] {
        let roots = config.existingRoots
        guard !roots.isEmpty else { return [] }
        let output = await Shell.run("find", roots + [
            "(", "-name", ".git", "-o", "-name", ".build", ")", "-prune",
            "-o", "-name", "node_modules", "-type", "d", "-print0", "-prune",
        ])
        // NUL-separated: split on newlines, a folder named "a\nb" would turn into a path to its parent.
        let folders = output.stdout.split(separator: "\0").map(String.init)
        let sizes = await Shell.sizes(of: folders)
        let projects = Dictionary(grouping: folders) { projectRoot(of: $0, stoppingAt: roots) }

        return projects.map { project, folders in
            let bytes = folders.reduce(0) { $0 + (sizes[$1] ?? 0) }
            let activity = lastActivity(of: project)
            let idle = activity.map { days(since: $0) } ?? 0
            let verdict: Verdict = idle >= config.idleNodeModulesDays ? .reclaimable : .keep
            // pnpm links into a shared store, so du counts bytes that deleting does not free.
            let pnpm = folders.contains { exists($0 + "/.pnpm") } ? ", pnpm, frees less than shown" : ""
            let age = idle == 0 ? "used today" : "idle \(idle)d"
            let count = folders.count == 1 ? "1 folder" : "\(folders.count) folders"
            return Finding(category: .nodeModules, title: displayName(project, roots: roots),
                           detail: "\(count), \(age)\(pnpm)", paths: folders.sorted(), bytes: bytes,
                           lastActivity: activity, verdict: verdict,
                           cleanup: "rm -rf " + folders.sorted().map(shellQuote).joined(separator: " "))
        }
    }

    /// Nearest ancestor holding a `.git`, or the folder's parent when there is none.
    static func projectRoot(of nodeModules: String, stoppingAt roots: [String]) -> String {
        let parent = (nodeModules as NSString).deletingLastPathComponent
        var directory = parent
        while !roots.contains(directory), directory != "/" {
            if exists(directory + "/.git") { return directory }
            directory = (directory as NSString).deletingLastPathComponent
        }
        return parent
    }

    /// The latest of: git HEAD moving (commit, checkout, pull), package.json, or a lockfile changing.
    /// Not the index, which `git status` rewrites.
    private static func lastActivity(of project: String) -> Date? {
        let headLog = Git.gitDir(forDotGit: project + "/.git").map { $0 + "/logs/HEAD" }
        let candidates = [headLog, project + "/package.json"] +
            ["package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb"].map { project + "/" + $0 }
        return candidates.compactMap { $0.flatMap(modificationDate) }.max()
    }

    private static func displayName(_ project: String, roots: [String]) -> String {
        guard let root = roots.first(where: { project.hasPrefix($0 + "/") }) else { return project }
        return String(project.dropFirst(root.count + 1))
    }
}
