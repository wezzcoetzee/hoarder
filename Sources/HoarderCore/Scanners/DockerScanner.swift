import Foundation

/// What `docker system df` says can be pruned, plus the VM disk image it all lives in on macOS.
enum DockerScanner {
    private struct Row: Decodable {
        let type: String
        let totalCount: String
        let active: String
        let size: String
        let reclaimable: String

        enum CodingKeys: String, CodingKey {
            case type = "Type", totalCount = "TotalCount", active = "Active", size = "Size", reclaimable = "Reclaimable"
        }
    }

    private struct Prune {
        let title: String
        let verdict: Verdict
        let command: String
        let why: String
    }

    private static let prunes: [String: Prune] = [
        "Build Cache": Prune(title: "Build cache", verdict: .reclaimable, command: "docker builder prune -f",
                             why: "rebuilt on next build"),
        "Containers": Prune(title: "Stopped containers", verdict: .reclaimable, command: "docker container prune -f",
                            why: "not running"),
        "Images": Prune(title: "Unused images", verdict: .review, command: "docker image prune -a -f",
                        why: "re-pulled on demand"),
        "Local Volumes": Prune(title: "Unused volumes", verdict: .review, command: "docker volume prune -f",
                               why: "may hold database data"),
    ]

    /// Sparse VM disks. Pruning frees space inside them; the file on the host shrinks only after the VM trims.
    /// Each runtime lists its disk's names across versions; the first that exists wins.
    private static let vmDisks = [
        ("Rancher Desktop VM disk", ["~/Library/Application Support/rancher-desktop/lima/0/disk",
                                     "~/Library/Application Support/rancher-desktop/lima/0/diffdisk"]),
        ("Docker Desktop VM disk", ["~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"]),
        ("Colima VM disk", ["~/.colima/_lima/colima/disk", "~/.colima/_lima/colima/diffdisk"]),
    ].compactMap { title, candidates in candidates.map(expand).first(where: exists).map { (title, $0) } }

    /// The VM disk is reported even when the daemon is down; the prunable rows need it running.
    /// `daemonDown` is true only when a VM exists but `docker` cannot reach it.
    static func scan() async -> (findings: [Finding], daemonDown: Bool) {
        let sizes = await Shell.sizes(of: vmDisks.map(\.1))
        let disks = vmDisks.map { title, path in
            Finding(category: .docker, title: title, detail: "holds every image, volume and cache below",
                    paths: [path], bytes: sizes[path] ?? 0, lastActivity: nil, verdict: .keep, cleanup: nil)
        }

        let output = await Shell.run("docker", ["system", "df", "--format", "{{json .}}"])
        guard output.ok else { return (disks, !disks.isEmpty) }
        let rows = output.stdout.split(separator: "\n")
            .compactMap { try? JSONDecoder().decode(Row.self, from: Data($0.utf8)) }

        let prunable = rows.compactMap { row -> Finding? in
            guard let prune = prunes[row.type], let bytes = parseSize(row.reclaimable), bytes > 0 else { return nil }
            return Finding(category: .docker, title: prune.title,
                           detail: "\(row.totalCount) total, \(row.active) in use, \(prune.why)",
                           paths: [], bytes: bytes, lastActivity: nil, verdict: prune.verdict, cleanup: prune.command)
        }
        return (prunable + disks, false)
    }

    /// Docker prints decimal units ("14.18GB (44%)", "20.48kB", "0B").
    static func parseSize(_ text: String) -> Int64? {
        let token = text.split(separator: " ").first.map(String.init) ?? text
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("B", 1)]
        for (suffix, multiplier) in units where token.hasSuffix(suffix) {
            return Double(token.dropLast(suffix.count)).map { Int64($0 * multiplier) }
        }
        return nil
    }
}
