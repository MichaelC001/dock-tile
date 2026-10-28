import Foundation
import Testing
@testable import Dock_Tile

/// cfprefsd rewrites the Dock plist by ATOMIC REPLACE. A watcher holding one descriptor sees the
/// first replacement and then watches a dead inode. Failing value: the callback count never rises
/// after the second replacement.
@MainActor
@Suite("DockPlistWatcher across atomic replaces", .serialized)
struct DockPlistWatcherReplaceTests {

    @Test("A change after an atomic replace is still reported")
    func survivesAtomicReplace() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("watcher-\(UUID().uuidString).plist")
        try Data("one".utf8).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let watcher = DockPlistWatcher(path: url.path, debounceInterval: 0.2)
        var callbacks = 0
        watcher.onDockChanged = { callbacks += 1 }
        watcher.startWatching()
        defer { watcher.stopWatching() }

        // Poll rather than sleep a fixed span: a loaded machine can delay a filesystem event well
        // past any margin worth hard-coding, and polling also returns as soon as the event lands.
        //
        // The deadline is deliberately generous. At 5 s this test passed in 0.43 s when run alone
        // but failed inside the full parallel suite, where it took over 7 s — the re-arm and its
        // event delivery both land on `.main`, which every other main-actor test is contending for.
        // A longer deadline does NOT weaken the guard: when the re-arm fix is reverted the watcher
        // never fires again, so the wait cannot succeed at any deadline and the test still fails,
        // just later. Trading a slower failure for a flake-free pass is the right way round, since
        // a test that fails under load teaches people to re-run rather than to read it.
        //
        // 20 s still flaked on GitHub's macos-26 runners on 2026-10-28 (6 of 10 runs, with old and
        // new action pins alike; 40/40 locally), so the deadline is 60 s. The test host's stdout
        // reaches no CI log, so the timing travels in the failure message: a slow first event
        // there means main-actor contention, a fast one means the watcher really went deaf.
        func waitForCallbackCount(above baseline: Int, timeout: TimeInterval = 60) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if callbacks > baseline { return true }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return callbacks > baseline
        }

        let firstStart = Date()
        try Data("two".utf8).write(to: url, options: .atomic)
        #expect(await waitForCallbackCount(above: 0), "no change reported for the first atomic replace within 60 s")
        let firstWait = String(format: "%.1f", Date().timeIntervalSince(firstStart))

        // Count AFTER the first replace has settled, so the second assertion cannot be satisfied by
        // leftover events from the first — that loophole would let this pass against the old code.
        let afterFirstReplace = callbacks

        try Data("three".utf8).write(to: url, options: .atomic)
        #expect(await waitForCallbackCount(above: afterFirstReplace),
                "first event took \(firstWait) s; no event within 60 s after the second replace — the descriptor was left on the unlinked inode")
    }
}
