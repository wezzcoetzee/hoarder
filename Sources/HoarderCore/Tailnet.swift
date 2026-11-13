import Foundation

/// The other machines on this Mac's tailnet, read from `tailscale status --json`, so Settings can offer
/// them as devices to add.
public enum Tailnet {
    public struct Peer: Sendable, Equatable {
        /// The MagicDNS name, which is what `ssh` and `Device.host` take.
        public let name: String
        public let os: String
        public let online: Bool

        /// Hoarder's CLI runs on these; phones and other systems cannot be scanned.
        public var canScan: Bool { os == "linux" || os == "macOS" }
    }

    /// The App Store and standalone apps keep the CLI inside the bundle and off the PATH.
    private static let clis = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "tailscale"]

    /// Nil when Tailscale is not installed or not running.
    public static func peers() async -> [Peer]? {
        for cli in clis where !cli.hasPrefix("/") || exists(cli) {
            let output = await Shell.run(cli, ["status", "--json"], timeout: 10)
            if output.ok, let peers = parse(Data(output.stdout.utf8)) { return peers }
        }
        return nil
    }

    static func parse(_ json: Data) -> [Peer]? {
        struct Status: Decodable {
            struct Node: Decodable {
                let DNSName: String
                let OS: String
                let Online: Bool?
            }
            let Peer: [String: Node]?
        }
        guard let status = try? JSONDecoder().decode(Status.self, from: json) else { return nil }
        return (status.Peer ?? [:]).values.compactMap { node in
            guard let name = node.DNSName.split(separator: ".").first.map(String.init), !name.isEmpty else { return nil }
            return Peer(name: name, os: node.OS, online: node.Online ?? false)
        }.sorted { $0.name < $1.name }
    }
}
