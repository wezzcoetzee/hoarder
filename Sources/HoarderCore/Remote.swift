import Foundation

/// A device scanned over SSH. The `hoarder` CLI runs there, so the scanners see that machine's files and
/// tools. The CLI is installed into `~/.local/share/hoarder/<build>/` on first use and again whenever
/// this app's build changes; nothing else on the device is touched until the user runs a cleanup.
public actor Remote {
    public struct Build: Sendable {
        /// The release tag (without its v) that Linux binaries are downloaded from.
        public let version: String
        /// A folder of bundled `hoarder-<os>-<arch>` binaries, used before any download.
        public let binaries: URL?

        public init(version: String, binaries: URL?) {
            self.version = version
            self.binaries = binaries
        }
    }

    /// `uname -sm` of the device, lowercased: "linux", "x86_64".
    public struct Platform: Sendable, Equatable {
        public let os: String
        public let arch: String

        public init(os: String, arch: String) {
            self.os = os
            self.arch = arch
        }

        /// "Linux x86_64", "macOS arm64".
        public var label: String {
            let name = switch os {
            case "darwin": "macOS"
            case "linux": "Linux"
            default: os
            }
            return "\(name) \(arch)"
        }
    }

    public struct Failure: Error, Sendable, Equatable {
        public let message: String
    }

    public nonisolated let host: String
    private let build: Build
    private var platform: Platform?
    private var installed: Set<String> = []

    private static let releases = "https://github.com/wezzcoetzee/hoarder/releases/download"
    /// Never prompt: a background scan has no one to answer a password or host key question.
    private static let sshOptions = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15"]

    public init(host: String, build: Build) {
        self.host = host
        self.build = build
    }

    public func scan(roots: [String]?) async throws(Failure) -> Report {
        let rootArguments = (roots ?? []).flatMap { ["--root", shellQuote($0)] }
        let output = try await hoarder(["--json"] + rootArguments, timeout: 900)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Report.self, from: Data(output.utf8))
        } catch {
            throw Failure(message: "\(host) sent a report this version cannot read")
        }
    }

    public func diskSpace() async throws(Failure) -> DiskSpace {
        let output = try await hoarder(["--free"], timeout: 30)
        guard let disk = try? JSONDecoder().decode(DiskSpace.self, from: Data(output.utf8)) else {
            throw Failure(message: "\(host) did not report its free space")
        }
        return disk
    }

    /// Runs a finding's cleanup command on the device, in its login shell, as `Hoarder.clean` does here.
    public func clean(_ command: String) async -> (ok: Bool, output: String) {
        let output = await ssh(command, includeErrors: true, timeout: 1800)
        return (output.ok, output.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func detectPlatform() async throws(Failure) -> Platform {
        if let platform { return platform }
        let output = await ssh("uname -sm", timeout: 30)
        let parts = output.stdout.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard output.ok, parts.count == 2 else { throw failure(output) }
        let detected = Platform(os: parts[0], arch: parts[1])
        platform = detected
        return detected
    }

    /// Where `ssh` really connects, when a Host entry in ~/.ssh/config points the name elsewhere.
    public nonisolated func resolvedHostName() async -> String? {
        let output = await Shell.run("ssh", ["-G", "--", host], timeout: 10)
        let name = output.stdout.split(separator: "\n").first { $0.hasPrefix("hostname ") }
            .map { String($0.dropFirst("hostname ".count)) }
        return name.flatMap { $0.caseInsensitiveCompare(host) == .orderedSame ? nil : $0 }
    }

    // MARK: Running hoarder there

    private func hoarder(_ arguments: [String], timeout: TimeInterval) async throws(Failure) -> String {
        let platform = try await detectPlatform()
        let (id, bundled) = await self.binary(for: platform)
        let command = (["\"$HOME/.local/share/hoarder/\(id)/hoarder\""] + arguments).joined(separator: " ")
        var output = await ssh(command, timeout: timeout)
        // 127: the shell found no such file, so this build was never installed there.
        if output.status == 127, !installed.contains(id) {
            try await install(id: id, bundled: bundled, platform: platform)
            output = await ssh(command, timeout: timeout)
        }
        guard output.ok else { throw failure(output) }
        return output.stdout
    }

    /// The install folder's name and the bundled binary, if any. A bundled binary's name carries its
    /// hash, so a rebuilt app reinstalls even when the version did not change.
    private func binary(for platform: Platform) async -> (id: String, bundled: URL?) {
        let version = build.version.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        guard let bundled = build.binaries?.appendingPathComponent("hoarder-\(platform.os)-\(platform.arch)"),
              exists(bundled.path) else { return (version, nil) }
        let hash = await Shell.run("shasum", ["-a", "256", bundled.path]).stdout.prefix(12)
        return ("\(version)-\(hash)", bundled)
    }

    /// Writes the binary to a temporary name and renames it, so a cut connection never leaves half a
    /// binary in place, then removes the folders of older builds.
    private func install(id: String, bundled: URL?, platform: Platform) async throws(Failure) {
        let root = "\"$HOME/.local/share/hoarder\""
        let folder = "\"$HOME/.local/share/hoarder/\(id)\""
        let fetch = if bundled != nil {
            "cat > \(folder)/hoarder.part"
        } else {
            "curl -fsSL \(shellQuote("\(Self.releases)/v\(build.version)/hoarder-\(platform.os)-\(platform.arch)")) -o \(folder)/hoarder.part"
        }
        let script = [
            "set -e", "mkdir -p \(folder)", fetch, "chmod +x \(folder)/hoarder.part",
            "mv \(folder)/hoarder.part \(folder)/hoarder",
            "for old in \(root)/*; do [ \"$old\" = \(folder) ] || rm -rf \"$old\"; done",
        ].joined(separator: "; ")
        let output = await ssh(script, includeErrors: bundled == nil, input: bundled, timeout: 300)
        guard output.ok else {
            if output.status == 255 { throw failure(output) }
            throw Failure(message: bundled == nil
                ? "Could not download hoarder \(build.version) for \(platform.os) \(platform.arch) onto \(host)"
                : "Could not copy hoarder onto \(host)")
        }
        installed.insert(id)
    }

    private func ssh(_ command: String, includeErrors: Bool = false, input: URL? = nil,
                     timeout: TimeInterval) async -> Shell.Output {
        // A login shell, so the device's own PATH applies (bun, go, docker in ~/.local/bin).
        let login = "exec \"${SHELL:-sh}\" -lc \(shellQuote(command))"
        return await Shell.run("ssh", Self.sshOptions + ["--", host, login], includeErrors: includeErrors,
                               input: input, timeout: timeout)
    }

    private func failure(_ output: Shell.Output) -> Failure {
        Failure(message: Self.describe(output, host: host))
    }

    /// ssh's last line of complaint, in words that say what to do. ssh exits 255 when the connection
    /// itself failed; anything else is the remote command's own status.
    static func describe(_ output: Shell.Output, host: String) -> String {
        let text = output.stderr.isEmpty ? output.stdout : output.stderr
        let line = text.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let known: [(String, String)] = [
            ("Host key verification failed", "Host key not trusted, run ssh \(host) once to accept it"),
            ("Permission denied", "SSH refused the login to \(host)"),
            ("Could not resolve hostname", "No device named \(host)"),
            ("timed out", "\(host) is unreachable"),
            ("No route to host", "\(host) is unreachable"),
            ("Connection refused", "\(host) refused SSH"),
        ]
        if let match = known.first(where: { line.contains($0.0) }) { return match.1 }
        if output.status == -1 { return "Could not run ssh" }
        return line.isEmpty ? "\(host): exited with status \(output.status)" : "\(host): \(line)"
    }
}
