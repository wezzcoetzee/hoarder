import Foundation

/// Package manager caches, build caches, and agent session data at well-known paths.
enum CacheScanner {
    private struct Known {
        let title: String
        /// Nil where the tool has no such cache on this OS.
        let path: String?
        let verdict: Verdict
        let detail: String
        let cleanup: String?
    }

    private static let regenerable = "re-downloaded when needed"

    /// Caches that macOS keeps under ~/Library and Linux under the XDG dirs.
    private static func path(mac: String?, linux: String?) -> String? {
        #if os(Linux)
        linux
        #else
        mac
        #endif
    }

    private static let known = [
        Known(title: "npm cache", path: "~/.npm/_cacache", verdict: .review, detail: regenerable,
              cleanup: "npm cache clean --force"),
        Known(title: "bun cache", path: "~/.bun/install/cache", verdict: .review, detail: regenerable,
              cleanup: "rm -rf ~/.bun/install/cache"),
        Known(title: "pnpm store", path: path(mac: "~/Library/pnpm/store", linux: "~/.local/share/pnpm/store"),
              verdict: .review, detail: "prune keeps packages in use", cleanup: "pnpm store prune"),
        Known(title: "Yarn cache", path: path(mac: "~/Library/Caches/Yarn", linux: "~/.cache/yarn"),
              verdict: .review, detail: regenerable, cleanup: "yarn cache clean"),
        Known(title: "Go modules", path: "~/go/pkg/mod", verdict: .review, detail: regenerable,
              cleanup: "go clean -modcache"),
        Known(title: "Go build cache", path: path(mac: "~/Library/Caches/go-build", linux: "~/.cache/go-build"),
              verdict: .reclaimable, detail: "rebuilt on next build", cleanup: "go clean -cache"),
        Known(title: "Homebrew downloads", path: path(mac: "~/Library/Caches/Homebrew", linux: "~/.cache/Homebrew"),
              verdict: .reclaimable, detail: "old versions, re-downloaded when needed", cleanup: "brew cleanup --prune=all"),
        Known(title: "Xcode DerivedData", path: path(mac: "~/Library/Developer/Xcode/DerivedData", linux: nil),
              verdict: .reclaimable, detail: "rebuilt on next build",
              cleanup: "rm -rf ~/Library/Developer/Xcode/DerivedData"),
        Known(title: "Playwright browsers", path: path(mac: "~/Library/Caches/ms-playwright", linux: "~/.cache/ms-playwright"),
              verdict: .review, detail: regenerable,
              cleanup: path(mac: "rm -rf ~/Library/Caches/ms-playwright", linux: "rm -rf ~/.cache/ms-playwright")),
        Known(title: "uv cache", path: "~/.cache/uv", verdict: .review, detail: regenerable, cleanup: "uv cache clean"),
        Known(title: "Claude Code transcripts", path: "~/.claude/projects", verdict: .review,
              detail: "set cleanupPeriodDays in ~/.claude/settings.json", cleanup: nil),
        Known(title: "Codex sessions", path: "~/.codex/sessions", verdict: .review, detail: "old session logs, delete by hand", cleanup: nil),
        Known(title: "T3 Code data", path: "~/.t3/userdata", verdict: .keep, detail: "app state and attachments",
              cleanup: nil),
    ]

    static func scan() async -> [Finding] {
        let present = known.compactMap { known in known.path.map { (known, expand($0)) } }.filter { exists($1) }
        let sizes = await Shell.sizes(of: present.map(\.1))
        return present.compactMap { known, path in
            guard let bytes = sizes[path], bytes > 0 else { return nil }
            return Finding(category: .cache, title: known.title, detail: known.detail, paths: [path],
                           bytes: bytes, lastActivity: nil, verdict: known.verdict, cleanup: known.cleanup)
        } + [memoryBackedTmp()].compactMap { $0 }
    }

    /// /tmp on tmpfs lives in RAM and swap, so clearing it frees memory, not the disk Hoarder watches. It is
    /// kept, so its size shows without counting toward what cleaning frees, and has no command because
    /// other programs' live files sit beside the stale ones. Its used space comes from the mount, not du,
    /// which cannot read other users' files.
    private static func memoryBackedTmp() -> Finding? {
        guard let mounts = try? String(contentsOfFile: "/proc/mounts", encoding: .utf8),
              isTmpfs("/tmp", mounts: mounts),
              let space = DiskSpace.current(volume: "/tmp"), space.total > space.free else { return nil }
        return Finding(category: .cache, title: "/tmp", detail: "tmpfs: frees RAM and swap, not disk",
                       paths: ["/tmp"], bytes: space.total - space.free, lastActivity: nil, verdict: .keep,
                       cleanup: nil)
    }

    /// Reads `/proc/mounts`: device, mount point, type, … per line. The last mount at a point is the one in effect.
    static func isTmpfs(_ mountPoint: String, mounts: String) -> Bool {
        let types = mounts.split(separator: "\n").map { $0.split(separator: " ") }
            .filter { $0.count > 2 && $0[1] == mountPoint }.map { $0[2] }
        return types.last == "tmpfs"
    }
}
