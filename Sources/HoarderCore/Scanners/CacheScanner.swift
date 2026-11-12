import Foundation

/// Package manager caches, build caches, and agent session data at well-known paths.
enum CacheScanner {
    private struct Known {
        let title: String
        let path: String
        let verdict: Verdict
        let detail: String
        let cleanup: String?
    }

    private static let regenerable = "regenerable, costs a re-download"

    private static let known = [
        Known(title: "npm cache", path: "~/.npm/_cacache", verdict: .review, detail: regenerable,
              cleanup: "npm cache clean --force"),
        Known(title: "bun cache", path: "~/.bun/install/cache", verdict: .review, detail: regenerable,
              cleanup: "bun pm cache rm"),
        Known(title: "pnpm store", path: "~/Library/pnpm/store", verdict: .review,
              detail: "prune drops packages no project references", cleanup: "pnpm store prune"),
        Known(title: "Yarn cache", path: "~/Library/Caches/Yarn", verdict: .review, detail: regenerable,
              cleanup: "yarn cache clean"),
        Known(title: "Go modules", path: "~/go/pkg/mod", verdict: .review, detail: regenerable,
              cleanup: "go clean -modcache"),
        Known(title: "Go build cache", path: "~/Library/Caches/go-build", verdict: .reclaimable,
              detail: "rebuilt on next build", cleanup: "go clean -cache"),
        Known(title: "Homebrew downloads", path: "~/Library/Caches/Homebrew", verdict: .reclaimable,
              detail: "old bottles and downloads", cleanup: "brew cleanup --prune=all"),
        Known(title: "Xcode DerivedData", path: "~/Library/Developer/Xcode/DerivedData", verdict: .reclaimable,
              detail: "rebuilt on next build", cleanup: "rm -rf ~/Library/Developer/Xcode/DerivedData"),
        Known(title: "Playwright browsers", path: "~/Library/Caches/ms-playwright", verdict: .review,
              detail: regenerable, cleanup: "rm -rf ~/Library/Caches/ms-playwright"),
        Known(title: "uv cache", path: "~/.cache/uv", verdict: .review, detail: regenerable, cleanup: "uv cache clean"),
        Known(title: "Claude Code transcripts", path: "~/.claude/projects", verdict: .review,
              detail: "set cleanupPeriodDays in ~/.claude/settings.json to cap", cleanup: nil),
        Known(title: "Codex sessions", path: "~/.codex/sessions", verdict: .review, detail: "session logs", cleanup: nil),
        Known(title: "T3 Code data", path: "~/.t3/userdata", verdict: .keep, detail: "app state and attachments",
              cleanup: nil),
    ]

    static func scan() async -> [Finding] {
        let present = known.map { ($0, expand($0.path)) }.filter { exists($1) }
        let sizes = await Shell.sizes(of: present.map(\.1))
        return present.compactMap { known, path in
            guard let bytes = sizes[path], bytes > 0 else { return nil }
            return Finding(category: .cache, title: known.title, detail: known.detail, paths: [path],
                           bytes: bytes, lastActivity: nil, verdict: known.verdict, cleanup: known.cleanup)
        }
    }
}
