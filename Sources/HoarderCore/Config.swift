import Foundation

/// Read from `~/.config/hoarder/config.json`. Every key is optional; missing keys use the defaults.
public struct Config: Codable, Sendable {
    /// Searched for git repos, their worktrees, and node_modules.
    public var projectRoots = ["~/Development", "~/.t3/worktrees", "~/.codex/worktrees", "~/.cursor/worktrees"]
    /// A clean, unmerged worktree whose branch tip is older than this is flagged for review.
    public var staleWorktreeDays = 14
    /// node_modules in a project untouched for this long is reclaimable.
    public var idleNodeModulesDays = 30
    /// What else counts as in use, beyond the two day counts above.
    public var inUse = InUseRules()
    /// The menu bar turns amber and a notification is sent when free space drops below this.
    public var alertBelowGB = 40
    /// How often the menu bar app runs a full scan. Free space is checked every minute regardless.
    public var scanEveryMinutes = 60
    /// Other machines on the tailnet to scan over SSH, by host name. Opt-in, so nothing is scanned
    /// just for being online.
    public var devices: [Device] = []

    public static let fileURL = URL(fileURLWithPath: expand("~/.config/hoarder/config.json"))

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Config()
        projectRoots = try container.decodeIfPresent([String].self, forKey: .projectRoots) ?? defaults.projectRoots
        staleWorktreeDays = try container.decodeIfPresent(Int.self, forKey: .staleWorktreeDays) ?? defaults.staleWorktreeDays
        idleNodeModulesDays = try container.decodeIfPresent(Int.self, forKey: .idleNodeModulesDays) ?? defaults.idleNodeModulesDays
        alertBelowGB = try container.decodeIfPresent(Int.self, forKey: .alertBelowGB) ?? defaults.alertBelowGB
        scanEveryMinutes = try container.decodeIfPresent(Int.self, forKey: .scanEveryMinutes) ?? defaults.scanEveryMinutes
        devices = try container.decodeIfPresent([Device].self, forKey: .devices) ?? defaults.devices
        inUse = try container.decodeIfPresent(InUseRules.self, forKey: .inUse) ?? defaults.inUse
    }

    public static func load() throws -> Config {
        guard let data = try? Data(contentsOf: fileURL) else { return Config() }
        return try JSONDecoder().decode(Config.self, from: data)
    }

    /// Keys in a config file that Config does not know, such as a misspelling, which decoding ignores.
    public static func unknownKeys(in data: Data) -> [String] {
        guard let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let known = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Config())) as? [String: Any]
        else { return [] }
        return file.keys.filter { known[$0] == nil }.sorted()
    }

    /// Writes the settings that differ from the defaults, so the file stays short and a changed default
    /// still reaches anyone who never touched that setting. Nested groups (`inUse`) are compared key by
    /// key the same way. Keys Config does not know are left as they are, so a misspelling stays visible
    /// instead of being silently dropped.
    public func save(to url: URL = fileURL) throws {
        let saved =
            (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let file = try Self.changes(try Self.object(self), from: try Self.object(Config()), into: saved)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: url, options: .atomic)
    }

    /// `file` with each of `mine` that differs from `defaults` written in and each that matches removed.
    /// A group with fixed keys is merged key by key; a map that defaults to empty (`caches`) is written
    /// whole, so a removed entry goes.
    private static func changes(_ mine: [String: Any], from defaults: [String: Any], into file: [String: Any]) throws -> [String: Any] {
        var file = file
        for (key, value) in mine {
            if let group = value as? [String: Any], let base = defaults[key] as? [String: Any], !base.isEmpty {
                let nested = try changes(group, from: base, into: file[key] as? [String: Any] ?? [:])
                file[key] = nested.isEmpty ? nil : nested
            } else {
                file[key] = try same(value, defaults[key]) ? nil : value
            }
        }
        return file
    }

    private static func object(_ config: Config) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any] ?? [:]
    }

    /// JSON values compared by their serialized form, which works the same on macOS and Linux.
    private static func same(_ a: Any, _ b: Any?) throws -> Bool {
        guard let b else { return false }
        let encode = { try JSONSerialization.data(withJSONObject: ["v": $0], options: .sortedKeys) }
        return try encode(a) == encode(b)
    }

    public static func writeDefaultsIfMissing() throws {
        guard !exists(fileURL.path) else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Config()).write(to: fileURL)
    }

    public func alertBelowGB(for device: Device?) -> Int {
        device?.alertBelowGB ?? alertBelowGB
    }

    var existingRoots: [String] {
        projectRoots.map(expand).filter(exists)
    }
}

/// The rules that make a row in use, each set to the verdict it gives. A rule that guards data (changes,
/// a lock, a volume's contents) never goes past review: the scanners treat "reclaimable" there as review,
/// so Clean safe can never run a command that loses work.
public struct InUseRules: Codable, Sendable, Equatable {
    /// A worktree with uncommitted changes.
    public var uncommittedWorktrees = Verdict.keep
    public var lockedWorktrees = Verdict.keep
    /// Untracked files or folders that do not count as changes, matched by name or by path inside the
    /// worktree ("`.DS_Store`", "`.claude/`"). Removing such a worktree deletes them first.
    public var ignoredUntracked = [".DS_Store"]
    /// A Docker volume a container mounts, running or stopped.
    public var mountedVolumes = Verdict.keep
    /// A volume a registry container stores pushed images in.
    public var registryVolumes = Verdict.keep
    /// The BuildKit cache of a builder `docker buildx ls` still lists.
    public var liveBuilderCache = Verdict.keep
    /// Verdicts by cache name ("Claude Code transcripts"), replacing the built-in one.
    public var caches: [String: Verdict] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = InUseRules()
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        uncommittedWorktrees = try read(.uncommittedWorktrees, defaults.uncommittedWorktrees)
        lockedWorktrees = try read(.lockedWorktrees, defaults.lockedWorktrees)
        ignoredUntracked = try read(.ignoredUntracked, defaults.ignoredUntracked)
        mountedVolumes = try read(.mountedVolumes, defaults.mountedVolumes)
        registryVolumes = try read(.registryVolumes, defaults.registryVolumes)
        liveBuilderCache = try read(.liveBuilderCache, defaults.liveBuilderCache)
        caches = try read(.caches, defaults.caches)
    }
}

/// A cache `InUseRules.caches` can name: its built-in verdict, and whether it has a command, without
/// which it is never reclaimable.
public struct CacheName: Sendable {
    public let title: String
    public let verdict: Verdict
    public let cleanable: Bool
}

/// A machine Hoarder scans over SSH. Its scan runs there, so paths resolve on that machine.
public struct Device: Codable, Sendable, Hashable {
    /// What `ssh` connects to: a tailnet name, an IP, or a Host from ~/.ssh/config.
    public var host: String
    /// Overrides `alertBelowGB` for this device.
    public var alertBelowGB: Int?
    /// Overrides the device's own config; unset uses whatever that machine's config.json says.
    public var projectRoots: [String]?

    public init(host: String, alertBelowGB: Int? = nil, projectRoots: [String]? = nil) {
        self.host = host
        self.alertBelowGB = alertBelowGB
        self.projectRoots = projectRoots
    }
}
