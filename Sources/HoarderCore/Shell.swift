import Foundation

enum Shell {
    /// A menu bar app launched from Finder inherits a bare PATH, so the usual tool locations are added.
    private static let path: String = {
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/local/go/bin", "~/go/bin", "~/.bun/bin",
                     "~/Library/pnpm", "~/.local/bin", "~/.rd/bin", "~/.orbstack/bin",
                     "/Applications/Docker.app/Contents/Resources/bin"].map(expand)
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return (inherited.split(separator: ":").map(String.init) + extra).joined(separator: ":")
    }()

    struct Output {
        let status: Int32
        let stdout: String
        /// Empty when `includeErrors` sent it into `stdout`.
        var stderr = ""
        var ok: Bool { status == 0 }
    }

    /// `includeErrors` sends stderr into `stdout`, for commands whose failure message is shown to the user.
    /// `input` is fed to the command's stdin. A command still running after `timeout` is terminated, so a
    /// wedged daemon or an unreachable host cannot stall a scan forever.
    static func run(_ tool: String, _ arguments: [String], includeErrors: Bool = false, input: URL? = nil,
                    timeout: TimeInterval = 300) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [tool] + arguments
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = path
                // Apps launched by launchd have no TERM. Tailscale's bundled CLI takes that to mean it was
                // opened from Finder and tries to start its GUI instead of answering, so `tailscale status`
                // fails from the app but not a terminal.
                environment["TERM"] = environment["TERM"] ?? "dumb"
                process.environment = environment
                let pipe = Pipe(), errors = Pipe()
                process.standardOutput = pipe
                process.standardError = includeErrors ? pipe : errors
                if let input, let handle = try? FileHandle(forReadingFrom: input) {
                    process.standardInput = handle
                } else {
                    process.standardInput = FileHandle.nullDevice
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Output(status: -1, stdout: ""))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { process.terminate() }
                }
                // Drain both pipes before waiting, or a full pipe buffer deadlocks the child.
                nonisolated(unsafe) var errorData = Data()
                let drained = DispatchGroup()
                if !includeErrors {
                    DispatchQueue.global().async(group: drained) {
                        errorData = errors.fileHandleForReading.readDataToEndOfFile()
                    }
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                drained.wait()
                process.waitUntilExit()
                continuation.resume(returning: Output(status: process.terminationStatus,
                                                      stdout: String(decoding: data, as: UTF8.self),
                                                      stderr: String(decoding: errorData, as: UTF8.self)))
            }
        }
    }

    /// Walking a tree is bound by per-file syscalls, so trees are walked in parallel, a few at a time.
    private static let parallelWalks = 8

    /// Allocated size of each path. `excluding` skips entries with that name at any depth (BSD du -I,
    /// GNU du --exclude). du exits non-zero when any file is unreadable but still prints the total, so the
    /// status is ignored.
    static func sizes(of paths: [String], excluding: String? = nil) async -> [String: Int64] {
        #if os(Linux)
        let arguments = ["-sk"] + (excluding.map { ["--exclude=\($0)"] } ?? [])
        #else
        let arguments = ["-sk"] + (excluding.map { ["-I", $0] } ?? [])
        #endif
        return await withTaskGroup(of: (String, Int64?).self) { group in
            var pending = paths.makeIterator()
            func startNext() {
                guard let path = pending.next() else { return }
                group.addTask {
                    let output = await run("du", arguments + [path])
                    return (path, output.stdout.split(separator: "\t").first.flatMap { Int64($0) }.map { $0 * 1024 })
                }
            }
            for _ in 0..<parallelWalks { startNext() }
            var sizes: [String: Int64] = [:]
            for await (path, bytes) in group {
                sizes[path] = bytes
                startNext()
            }
            return sizes
        }
    }
}

func expand(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

func exists(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
}
