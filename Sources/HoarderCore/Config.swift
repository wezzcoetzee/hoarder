import Foundation

/// Read from `~/.config/hoarder/config.json`. Every key is optional; missing keys use the defaults.
public struct Config: Codable, Sendable {
    /// Searched for git repos, their worktrees, and node_modules.
    public var projectRoots = ["~/Development", "~/.t3/worktrees", "~/.codex/worktrees", "~/.cursor/worktrees"]
    /// A clean, unmerged worktree whose branch tip is older than this is flagged for review.
    public var staleWorktreeDays = 14
    /// node_modules in a project untouched for this long is reclaimable.
    public var idleNodeModulesDays = 30
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

    /// Writes the defaults so there is a file to edit. Leaves an existing file alone.
    public static func writeDefaultsIfMissing() throws {
        guard !exists(fileURL.path) else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Config()).write(to: fileURL)
    }

    public var alertLimitBytes: Int64 { Int64(alertBelowGB) * 1_000_000_000 }

    /// The free-space limit for a device: its own, else the one for this Mac.
    public func alertBelowGB(for device: Device?) -> Int {
        device?.alertBelowGB ?? alertBelowGB
    }

    var existingRoots: [String] {
        projectRoots.map(expand).filter(exists)
    }
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
