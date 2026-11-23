import Foundation

/// Words the app also acts on, offering the next step beside them, so both sides use one string.
public enum KnownState {
    /// A cleanup's reason when Docker's daemon is down.
    public static let dockerNotRunning = "Docker is not running"
    /// The scan's note when Docker's daemon is down.
    public static let startDocker = "Start Docker to see what it can clean"
}

/// A failed cleanup in plain words, for its row: the refusals Hoarder knows by name, otherwise the last
/// line of output without git's "fatal: " and with home folders shortened to ~. The full output stays
/// with the app for the row's tooltip.
public func describeFailure(_ output: String) -> String {
    let text = output.lowercased()
    let known = [
        ("contains modified or untracked files", "it has uncommitted changes now"),
        ("cannot remove a locked working tree", "it was locked since the scan"),
        ("volume is in use", "a container is using it now"),
        ("cannot connect to the docker daemon", KnownState.dockerNotRunning),
        // A build (or gopls) writing into a cache while it is deleted: most of it is gone, the rest
        // goes on a second run.
        ("directory not empty", "something wrote to it while cleaning; run again"),
    ]
    if let (_, reason) = known.first(where: { text.contains($0.0) }) { return reason }
    // zsh says "zsh:1: command not found: pnpm", bash "bash: pnpm: command not found". zsh's is tried
    // first, since bash's pattern would also match it and take "zsh:1" for the command.
    if let command = output.firstMatch(of: /command not found: (\S+)/)?.1 ?? output.firstMatch(of: /(\S+): command not found/)?.1 {
        // Cleanups run in a login shell (zsh -lc, or the device's), so that is the PATH that was searched.
        return "\(command) is not on the login shell's PATH"
    }
    let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    guard var line = lines.last(where: { !$0.isEmpty }) else { return "exited with an error" }
    for prefix in ["fatal: ", "error: ", "Error response from daemon: "] where line.hasPrefix(prefix) {
        line = String(line.dropFirst(prefix.count))
    }
    line = line.replacing(/\/(?:Users|home)\/[^\/\s'"]+/, with: "~")
    return String(line.prefix(240))
}
