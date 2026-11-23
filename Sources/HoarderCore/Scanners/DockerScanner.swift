import Foundation

/// What `docker system df` says can be pruned, one row per volume worth a decision, plus the VM disk image
/// it all lives in on macOS.
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
        "Build Cache": Prune(
            title: "Build cache", verdict: .reclaimable, command: "docker builder prune -f",
            why: "rebuilt on next build"),
        "Containers": Prune(
            title: "Stopped containers", verdict: .reclaimable, command: "docker container prune -f",
            why: "files go, images stay"),
        "Images": Prune(
            title: "Unused images", verdict: .review, command: "docker image prune -a -f",
            why: "re-pulled on demand"),
    ]

    struct Volume: Decodable {
        let name: String
        let size: String
        /// Containers that mount it, stopped ones included.
        let links: String

        enum CodingKeys: String, CodingKey { case name = "Name", size = "Size", links = "Links" }
    }

    private struct DiskUsage: Decodable {
        let volumes: [Volume]?

        enum CodingKeys: String, CodingKey { case volumes = "Volumes" }
    }

    private struct Builder: Decodable {
        struct Node: Decodable {
            let name: String
            enum CodingKeys: String, CodingKey { case name = "Name" }
        }

        let name: String
        let nodes: [Node]?

        enum CodingKeys: String, CodingKey { case name = "Name", nodes = "Nodes" }
    }

    struct Container: Decodable {
        let name: String
        let image: String
        /// Comma separated volume names and bind mount paths.
        let mounts: String
        /// "running", "exited", "created", …
        let state: String

        enum CodingKeys: String, CodingKey { case name = "Names", image = "Image", mounts = "Mounts", state = "State" }

        var volumes: [String] { mounts.split(separator: ",").map(String.init) }

        /// "registry:2@sha256:…" or "host:5000/library/registry:2" → "registry"
        var isRegistry: Bool {
            let repository = image.split(separator: "@").first?.split(separator: "/").last ?? ""
            return registryImages.contains(String(repository.split(separator: ":").first ?? ""))
        }
    }

    /// Images that serve a registry. Their volumes hold pushed images, which no cache rebuilds.
    private static let registryImages: Set<String> = ["registry", "distribution"]

    /// Sparse VM disks. Pruning frees space inside them; the file on the host shrinks only after the VM trims.
    /// Each runtime lists its disk's names across versions; the first that exists wins.
    private static let vmDisks = [
        (
            "Rancher Desktop VM disk",
            [
                "~/Library/Application Support/rancher-desktop/lima/0/disk",
                "~/Library/Application Support/rancher-desktop/lima/0/diffdisk",
            ]
        ),
        ("Docker Desktop VM disk", ["~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"]),
        ("Colima VM disk", ["~/.colima/_lima/colima/disk", "~/.colima/_lima/colima/diffdisk"]),
    ].compactMap { title, candidates in candidates.map(expand).first(where: exists).map { (title, $0) } }

    /// The VM disk is reported even when the daemon is down; the prunable rows need it running.
    /// `daemonDown` is true only when a VM exists but `docker` cannot reach it.
    static func scan(_ rules: InUseRules) async -> (findings: [Finding], daemonDown: Bool) {
        let sizes = await Shell.sizes(of: vmDisks.map(\.1))
        let disks = vmDisks.map { title, path in
            Finding(
                category: .docker, title: title, detail: "holds Docker's images and volumes",
                paths: [path], bytes: sizes[path] ?? 0, lastActivity: nil, verdict: .keep, cleanup: nil)
        }

        async let summary = Shell.run("docker", ["system", "df", "--format", "{{json .}}"])
        async let volumes = volumeFindings(rules)
        let output = await summary
        guard output.ok else { return (disks, !disks.isEmpty) }
        let rows = lines(Row.self, in: output.stdout)

        let prunable = rows.compactMap { row -> Finding? in
            guard let prune = prunes[row.type], let bytes = parseSize(row.reclaimable), bytes > 0 else { return nil }
            return Finding(
                category: .docker, title: prune.title, detail: prune.why,
                paths: [], bytes: bytes, lastActivity: nil, verdict: prune.verdict, cleanup: prune.command)
        }
        return (prunable + (await volumes) + disks, false)
    }

    /// Volumes are judged one by one rather than with `docker volume prune`: since Docker 23 that skips
    /// named volumes, so it frees little of what `system df` calls reclaimable, and with `-a` it would take
    /// a stopped registry's images too.
    private static func volumeFindings(_ rules: InUseRules) async -> [Finding] {
        async let usage = Shell.run("docker", ["system", "df", "-v", "--format", "json"])
        async let builders = Shell.run("docker", ["buildx", "ls", "--format", "json"])
        async let listing = Shell.run("docker", ["ps", "-a", "--no-trunc", "--format", "{{json .}}"])

        guard let volumes = try? JSONDecoder().decode(DiskUsage.self, from: Data(await usage.stdout.utf8)).volumes
        else { return [] }
        let listed = await builders
        let owners = listed.ok ? builderNodes(lines(Builder.self, in: listed.stdout)) : nil
        let containers = lines(Container.self, in: await listing.stdout)
        return volumes.compactMap { classify($0, builderNodes: owners, containers: containers, rules: rules) }
    }

    /// Builder name by node name. A docker-container builder keeps its cache in `buildx_buildkit_<node>_state`.
    private static func builderNodes(_ builders: [Builder]) -> [String: String] {
        Dictionary(
            builders.flatMap { builder in (builder.nodes ?? []).map { ($0.name, builder.name) } },
            uniquingKeysWith: { first, _ in first })
    }

    /// `builderNodes` is nil when `docker buildx` could not list builders, so a BuildKit volume's owner is
    /// unknown and it is never offered for removal. A volume a container mounts can only go with that
    /// container, so its command removes both, behind a warning naming them.
    static func classify(
        _ volume: Volume, builderNodes: [String: String]?, containers: [Container], rules: InUseRules = InUseRules()
    ) -> Finding? {
        guard let bytes = parseSize(volume.size), bytes > 0 else { return nil }
        let users = containers.filter { $0.volumes.contains(volume.name) }
        let names = listed(users.map(\.name))
        // Links counts containers that mount it; `docker ps` may not have named them all.
        let inUse = volume.links != "0" || !users.isEmpty
        let remove = (users.isEmpty ? "" : "docker rm -f \(users.map(\.name).joined(separator: " ")) && ") + "docker volume rm \(volume.name)"
        let removing = users.isEmpty ? "Deletes" : "Removes \(users.count == 1 ? "container" : "containers") \(names) and deletes"
        let row = { (detail: String, verdict: Verdict, cleanup: String?, warning: String?) in
            Finding(
                category: .docker, title: volume.name, detail: detail, paths: [], bytes: bytes,
                lastActivity: nil, verdict: verdict, cleanup: cleanup, warning: warning)
        }

        if users.contains(where: \.isRegistry) {
            return row(
                "registry data: pushed images, not a cache", rules.registryVolumes.guarded, remove,
                "\(removing) the pushed images; not undoable")
        }
        if let node = buildkitNode(volume.name) {
            if let builder = builderNodes?[node] {
                return row(
                    "BuildKit cache of builder \(builder)", rules.liveBuilderCache,
                    "docker buildx prune --builder \(builder) -f", nil)
            }
            if inUse { return row("BuildKit cache, mounted by \(names.isEmpty ? "a container" : names)", .keep, remove, nil) }
            guard builderNodes != nil else { return row("BuildKit cache, owner unknown without docker buildx", .keep, nil, nil) }
            return row("BuildKit cache left by a removed builder", .review, remove, nil)
        }
        guard inUse else {
            return row("unused, may hold database data", .review, remove, "Deletes the volume's data; not undoable")
        }
        let running = users.contains { $0.state == "running" } ? "running" : "stopped"
        return row(
            users.isEmpty ? "mounted by a container" : "mounted by \(names), \(running)", rules.mountedVolumes.guarded,
            remove, "\(removing) the volume's data; not undoable")
    }

    private static func buildkitNode(_ volume: String) -> String? {
        let prefix = "buildx_buildkit_", suffix = "_state"
        guard volume.hasPrefix(prefix), volume.hasSuffix(suffix), volume.count > prefix.count + suffix.count
        else { return nil }
        return String(volume.dropFirst(prefix.count).dropLast(suffix.count))
    }

    /// Docker's `{{json .}}` prints one object per line.
    private static func lines<T: Decodable>(_ type: T.Type, in output: String) -> [T] {
        output.split(separator: "\n").compactMap { try? JSONDecoder().decode(T.self, from: Data($0.utf8)) }
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
