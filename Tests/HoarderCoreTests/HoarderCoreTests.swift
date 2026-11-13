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

@Test func parsesDockerSizes() {
    #expect(DockerScanner.parseSize("14.18GB (44%)") == 14_180_000_000)
    #expect(DockerScanner.parseSize("20.48kB") == 20_480)
    #expect(DockerScanner.parseSize("0B") == 0)
    #expect(DockerScanner.parseSize("garbage") == nil)
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

@Test func namesMisspelledConfigKeys() {
    let file = Data(#"{"alertBelowGB": 30, "alertBelowGb": 20, "projectRoot": []}"#.utf8)
    #expect(Config.unknownKeys(in: file) == ["alertBelowGb", "projectRoot"])
    #expect(Config.unknownKeys(in: Data("not json".utf8)).isEmpty)
}
