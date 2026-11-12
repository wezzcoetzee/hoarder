import Foundation
import Testing
@testable import HoarderCore

@Test func parsesWorktreePorcelainSkippingMain() {
    let porcelain = """
    worktree /repo
    HEAD abc
    branch refs/heads/main

    worktree /wt/feature
    HEAD def
    branch refs/heads/feat/x

    worktree /wt/detached
    HEAD 123
    detached
    locked reason here

    """
    #expect(WorktreeScanner.parse(porcelain: porcelain) == [
        .init(path: "/wt/feature", branch: "feat/x"),
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

@Test func totalsSkipPathsNestedInsideCountedOnes() {
    func finding(_ path: String, _ bytes: Int64) -> Finding {
        Finding(category: .worktree, title: path, detail: "", paths: [path], bytes: bytes, lastActivity: nil,
                verdict: .reclaimable, cleanup: nil)
    }
    let report = Report(findings: [finding("/wt/a/node_modules", 40), finding("/wt/a", 100), finding("/wt/ab", 5)],
                        notes: [], scannedAt: .now, duration: 0)
    #expect(report.total(.reclaimable) == 105)
}

@Test func alertsOncePerDipAndAgainAfterSnooze() {
    let limit: Int64 = 40
    let now = Date.now
    var state = AlertState()
    #expect(state.evaluate(free: 50, limit: limit, now: now) == false)
    #expect(state.evaluate(free: 30, limit: limit, now: now) == true)
    #expect(state.evaluate(free: 25, limit: limit, now: now) == false)    // still the same dip
    state.snooze(until: now.addingTimeInterval(60))
    #expect(state.evaluate(free: 25, limit: limit, now: now) == false)    // snoozed
    #expect(state.evaluate(free: 25, limit: limit, now: now.addingTimeInterval(61)) == true)  // snooze over, still low
    #expect(state.evaluate(free: 45, limit: limit, now: now) == false)    // recovered, re-arms
    #expect(state.evaluate(free: 30, limit: limit, now: now) == true)
}
