import Foundation

/// Filesystem-level git lookups, done in-process so discovering hundreds of repos spawns no processes.
enum Git {
    /// Every `.git` file or directory under the roots, without descending into dependency trees.
    static func dotGits(under roots: [String]) async -> [String] {
        guard !roots.isEmpty else { return [] }
        let output = await Shell.run("find", roots + [
            "-maxdepth", "6",
            "(", "-name", "node_modules", "-o", "-name", ".build", "-o", "-name", "Library", ")", "-prune",
            "-o", "-name", ".git", "-print", "-prune",
        ])
        return output.stdout.split(separator: "\n").map(String.init)
    }

    /// The git dir a `.git` entry points at: itself for a main clone, the `gitdir:` target for a
    /// linked worktree or submodule.
    static func gitDir(forDotGit path: String) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return standardize(path) }
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8),
              let line = contents.split(separator: "\n").first, line.hasPrefix("gitdir: ") else { return nil }
        return resolve(String(line.dropFirst("gitdir: ".count)), relativeTo: (path as NSString).deletingLastPathComponent)
    }

    /// The repo a `.git` entry belongs to. A linked worktree's git dir names it in `commondir`.
    static func commonDir(forDotGit path: String) -> String? {
        guard let gitDir = gitDir(forDotGit: path) else { return nil }
        guard let common = try? String(contentsOfFile: gitDir + "/commondir", encoding: .utf8) else { return gitDir }
        return resolve(common.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: gitDir)
    }

    private static func resolve(_ path: String, relativeTo base: String) -> String {
        standardize(path.hasPrefix("/") ? path : base + "/" + path)
    }

    private static func standardize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

func modificationDate(_ path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
}

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func days(since date: Date, now: Date = .now) -> Int {
    Int(now.timeIntervalSince(date) / 86_400)
}
