import Foundation
import Testing
@testable import HoarderCore

@Test func parsesWorktreePorcelainSkippingMain() {
    let blocks = [
        ["worktree /repo", "HEAD abc", "branch refs/heads/main"],
        ["worktree /wt/new\nline", "HEAD def", "branch refs/heads/feat/x"],
        ["worktree /wt/detached", "HEAD 123", "detached", "locked reason here"],
    ]
    let porcelain = blocks.map { $0.map { $0 + "\0" }.joined() + "\0" }.joined()
    #expect(WorktreeScanner.parse(porcelain: porcelain) == [
        .init(path: "/wt/new\nline", branch: "feat/x"),
        .init(path: "/wt/detached", branch: nil, locked: true),
    ])
}

@Test(arguments: [
    // present, locked, dirty, merged, pushed, ageDays, expected
    (false, false, false, false, false, 1, Verdict.reclaimable),  // orphan, whatever its age
    (true, false, true, true, true, 90, .keep),                   // dirty beats merged
    (true, true, false, true, true, 90, .keep),                   // locked
    (true, false, false, true, true, 3, .keep),                   // too recent to judge
    (true, false, false, true, true, 20, .reclaimable),           // clean and merged
    (true, false, false, false, false, 20, .review),              // clean, stale, unmerged
])
func classifiesWorktrees(present: Bool, locked: Bool, dirty: Bool, merged: Bool, pushed: Bool, age: Int,
                         expected: Verdict) {
    let now = Date.now
    let worktree = WorktreeScanner.Worktree(
        repo: "r", gitDir: "/r/.git", entry: .init(path: "/wt", branch: "b", locked: locked), present: present,
        dirty: dirty, merged: merged, pushed: pushed, tip: now.addingTimeInterval(-Double(age) * 86_400))
    #expect(WorktreeScanner.classify(worktree, staleAfterDays: 14, now: now).0 == expected)
}

@Test(arguments: [
    // present, locked, dirty, expected flags (nil: no command)
    (true, false, false, Optional("worktree remove '/wt'")),
    (true, false, true, "worktree remove --force '/wt'"),
    (true, true, false, "worktree remove -f -f '/wt'"),
    (true, true, true, "worktree remove -f -f '/wt'"),
    (false, true, false, nil),
])
func forcesWorktreeRemovalOnlyPastWhatTheScanSaw(present: Bool, locked: Bool, dirty: Bool, expected: String?) {
    let worktree = WorktreeScanner.Worktree(
        repo: "r", gitDir: "/r/.git", entry: .init(path: "/wt", branch: "b", locked: locked), present: present,
        dirty: dirty, merged: false, pushed: false, tip: nil)
    #expect(WorktreeScanner.removeCommand(worktree) == expected.map { "git --git-dir='/r/.git' " + $0 })
}

@Test func parsesDockerSizes() {
    #expect(DockerScanner.parseSize("14.18GB (44%)") == 14_180_000_000)
    #expect(DockerScanner.parseSize("20.48kB") == 20_480)
    #expect(DockerScanner.parseSize("0B") == 0)
    #expect(DockerScanner.parseSize("garbage") == nil)
}

@Test(arguments: [
    // volume, links, expected verdict and command (nil verdict: no row)
    ("infrastructure_registry-data", "0", Optional(Verdict.keep), String?.none),
    ("buildx_buildkit_ci-release0_state", "1", .keep, "docker buildx prune --builder ci-release -f"),
    ("buildx_buildkit_gone-checks0_state", "0", .review, "docker volume rm buildx_buildkit_gone-checks0_state"),
    ("buildx_buildkit_gone-checks0_state", "1", .keep, nil),
    ("postgres-data", "1", nil, nil),
    ("old-data", "0", .review, "docker volume rm old-data"),
])
func judgesVolumesByOwner(name: String, links: String, verdict: Verdict?, command: String?) {
    let volume = DockerScanner.Volume(name: name, size: "3GB", links: links)
    let row = DockerScanner.classify(volume, builderNodes: ["ci-release0": "ci-release"],
                                     registryVolumes: ["infrastructure_registry-data"])
    #expect(row?.verdict == verdict)
    #expect(row?.cleanup == command)
}

@Test func neverOffersBuildKitVolumesWhenBuildersAreUnknown() {
    let volume = DockerScanner.Volume(name: "buildx_buildkit_gone0_state", size: "3GB", links: "0")
    let row = DockerScanner.classify(volume, builderNodes: nil, registryVolumes: [])
    #expect(row?.verdict == .keep && row?.cleanup == nil)
}

@Test func findsTmpfsByTheMountInEffect() {
    let mounts = "/dev/sda1 / ext4 rw 0 0\n/dev/sda2 /tmp ext4 rw 0 0\ntmpfs /tmp tmpfs rw,nosuid 0 0\ntmpfs /run tmpfs rw 0 0\n"
    #expect(CacheScanner.isTmpfs("/tmp", mounts: mounts))
    #expect(!CacheScanner.isTmpfs("/", mounts: mounts))
    #expect(!CacheScanner.isTmpfs("/var/tmp", mounts: mounts))
}

private func finding(_ path: String, _ bytes: Int64) -> Finding {
    Finding(category: .worktree, title: path, detail: "", paths: [path], bytes: bytes, lastActivity: nil,
            verdict: .reclaimable, cleanup: nil)
}

@Test func totalsSkipPathsNestedInsideCountedOnes() {
    let report = Report(findings: [finding("/wt/a/node_modules", 40), finding("/wt/a", 100), finding("/wt/ab", 5)],
                        notes: [], scannedAt: .now, duration: 0)
    #expect(report.total(.reclaimable) == 105)
}

@Test func cleaningDropsNestedRowsAndShrinksTheContainingOne() {
    let worktree = finding("/wt/a", 100), modules = finding("/wt/a/node_modules", 40), sibling = finding("/wt/ab", 5)
    let report = Report(findings: [worktree, modules, sibling], notes: [], scannedAt: .now, duration: 0)
    #expect(report.removing(worktree).findings.map(\.paths) == [["/wt/ab"]])
    let afterModules = report.removing(modules)
    #expect(afterModules.findings.map(\.bytes) == [60, 5])
}

@Test func alertsOncePerDipAndAgainAfterSnooze() {
    let gb: Int64 = 1_000_000_000
    let limit = 40 * gb
    let now = Date.now
    var state = AlertState()
    #expect(state.evaluate(free: 50 * gb, limit: limit, now: now) == false)
    #expect(state.evaluate(free: 30 * gb, limit: limit, now: now) == true)
    #expect(state.evaluate(free: 25 * gb, limit: limit, now: now) == false)   // still the same dip
    #expect(state.evaluate(free: 41 * gb, limit: limit, now: now) == false)   // inside the margin, stays fired
    #expect(state.evaluate(free: 39 * gb, limit: limit, now: now) == false)
    state.snooze(until: now.addingTimeInterval(60))
    #expect(state.evaluate(free: 25 * gb, limit: limit, now: now) == false)   // snoozed
    #expect(state.evaluate(free: 25 * gb, limit: limit, now: now.addingTimeInterval(61)) == true)  // snooze over
    state.snooze(until: now.addingTimeInterval(60))
    #expect(state.evaluate(free: 45 * gb, limit: limit, now: now) == false)   // recovered: re-arms, ends snooze
    #expect(state.evaluate(free: 30 * gb, limit: limit, now: now) == true)
}

@Test func unsnoozingWhileLowCountsAsTheAlertButNotWhileAbove() {
    let gb: Int64 = 1_000_000_000
    let limit = 40 * gb
    let now = Date.now
    var state = AlertState()
    state.snooze(until: now.addingTimeInterval(60))
    state.unsnooze(low: true)
    #expect(!state.isSnoozed(now: now))
    #expect(state.evaluate(free: 30 * gb, limit: limit, now: now) == false)   // seen in the popover
    state.snooze(until: now.addingTimeInterval(60))
    state.unsnooze(low: false)   // inside the margin, so the snooze never ended on its own
    #expect(state.evaluate(free: 30 * gb, limit: limit, now: now) == true)    // the next dip still alerts
}

@Test func namesMisspelledConfigKeys() {
    let file = Data(#"{"alertBelowGB": 30, "alertBelowGb": 20, "projectRoot": []}"#.utf8)
    #expect(Config.unknownKeys(in: file) == ["alertBelowGb", "projectRoot"])
    #expect(Config.unknownKeys(in: Data("not json".utf8)).isEmpty)
}

@Test func readsDevicesWithTheirOverrides() throws {
    let file = Data(#"{"alertBelowGB": 40, "devices": [{"host": "homeserver", "alertBelowGB": 20}, {"host": "mini"}]}"#.utf8)
    let config = try JSONDecoder().decode(Config.self, from: file)
    #expect(config.devices == [Device(host: "homeserver", alertBelowGB: 20), Device(host: "mini")])
    #expect(config.alertBelowGB(for: config.devices[0]) == 20)
    #expect(config.alertBelowGB(for: config.devices[1]) == 40)
    #expect(Config.unknownKeys(in: file).isEmpty)
}

@Test(arguments: [
    (255, "Host key verification failed.\n", "Host key not trusted, run ssh box once to accept it"),
    (255, "ssh: connect to host box port 22: Operation timed out\n", "box is unreachable"),
    (255, "wezz@box: Permission denied (publickey).\n", "SSH refused the login to box"),
    (1, "warning: noise\nCould not read free space\n", "box: Could not read free space"),
    (2, "", "box: exited with status 2"),
])
func describesSSHFailuresInWordsThatSayWhatToDo(status: Int32, stderr: String, expected: String) {
    #expect(Remote.describe(Shell.Output(status: status, stdout: "", stderr: stderr), host: "box") == expected)
}

@Test func readsTailnetPeersByTheirMagicDNSName() {
    let json = Data(#"{"Self": {"DNSName": "me.tail.ts.net."}, "Peer": {"a": {"HostName": "Wes's Mac mini", "DNSName": "wesleys-mac-mini.tail.ts.net.", "OS": "macOS", "Online": true}, "b": {"HostName": "localhost", "DNSName": "phone.tail.ts.net.", "OS": "iOS", "Online": false}}}"#.utf8)
    #expect(Tailnet.parse(json) == [
        .init(name: "phone", os: "iOS", online: false),
        .init(name: "wesleys-mac-mini", os: "macOS", online: true),
    ])
    #expect(Tailnet.parse(json)?.filter(\.canScan).map(\.name) == ["wesleys-mac-mini"])
}

@Test func savesOnlyChangedSettingsAndKeepsUnknownKeys() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hoarder-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(#"{"alertBelowGb": 20, "scanEveryMinutes": 30}"#.utf8).write(to: url)
    var config = Config()
    config.alertBelowGB = 25
    config.devices = [Device(host: "homeserver", projectRoots: ["~/development"])]
    try config.save(to: url)
    let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
    // scanEveryMinutes went back to its default, so it leaves the file; the misspelling stays.
    #expect(saved.keys.sorted() == ["alertBelowGB", "alertBelowGb", "devices"])
    #expect(try JSONDecoder().decode(Config.self, from: Data(contentsOf: url)).devices == config.devices)
}
