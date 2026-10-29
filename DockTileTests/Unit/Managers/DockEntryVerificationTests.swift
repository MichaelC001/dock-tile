//
//  DockEntryVerificationTests.swift
//  DockTileTests
//
//  Guards the 2.6.2 Dock write-race fix (docs/dock-modification-prior-art.md §6):
//    1. `dockRestartArguments` — the Dock is restarted with SIGKILL, so a dying Dock cannot
//       save its stale persistent-apps over the write we just made.
//    2. `dockEntryPath` / `dockEntryPaths` / `dockEntriesAreCurrent` / `isSameFile` — ONE predicate
//       for "is this tile's Dock entry current?": exactly one entry, and it is the same FILE as the
//       helper (device + inode). The 2026-10-29 incident left an entry with the right bundle id at a
//       deleted folder, and every bundle-id-only check called it fine.
//    3. `reconciledDockApps` — `addToDock` replaces a stale, unparseable or duplicate entry in its
//       slot and never touches another tile's entry.
//

import Testing
import Foundation
@testable import Dock_Tile

/// A persistent-apps entry with the fields the seams read. `url: nil` = no `_CFURLString` at all.
private func entry(_ id: String, _ url: String?) -> [String: Any] {
    ["tile-type": "file-tile",
     "tile-data": ["bundle-identifier": id,
                   "file-data": url.map { ["_CFURLString": $0, "_CFURLStringType": 15] as [String: Any] } ?? [:]] as [String: Any]]
}

/// Same file when the paths are equal or listed together in `aliases` (a symlink stand-in).
private func fakeSameFile(aliases: Set<[String]> = []) -> (String, String) -> Bool {
    { a, b in a == b || aliases.contains([a, b]) }
}

/// `"<bundle id>@<path>"` per entry, in order — what the reconcile tests compare.
private func summary(_ apps: [[String: Any]]) -> [String] {
    apps.map { app in
        let id = (app["tile-data"] as? [String: Any])?["bundle-identifier"] as? String ?? "?"
        return "\(id)@\(HelperBundleManager.dockEntryPath(app) ?? "nil")"
    }
}

/// A fresh temp folder, removed by the caller's `defer`. The path is the real one (`realpath`, so
/// `/private/var/…`) so a test can build the `/System/Volumes/Data` spelling from it —
/// `URL.resolvingSymlinksInPath()` deliberately strips `/private` and would give `/var/…`.
private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("DockEntryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let real = try #require(realpath(dir.path, nil))
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

@Suite("Dock entry path + same-file predicate")
struct DockEntryPathTests {

    @Test("The Dock's %20-encoded URL and our unencoded one give the same path")
    func encodedAndUnencodedURLsGiveTheSamePath() {
        let p = "/Users/a/Library/Application Support/DockTile/Dev.app"
        #expect(HelperBundleManager.dockEntryPath(entry("x", "file:///Users/a/Library/Application%20Support/DockTile/Dev.app/")) == p)
        #expect(HelperBundleManager.dockEntryPath(entry("x", "file:///Users/a/Library/Application Support/DockTile/Dev.app/")) == p)
    }

    @Test("A missing or non-file URL gives no path")
    func unparseableURLGivesNil() {
        #expect(HelperBundleManager.dockEntryPath(entry("x", nil)) == nil)
        #expect(HelperBundleManager.dockEntryPath(entry("x", "https://e.com/")) == nil)
    }

    @Test("A plain absolute path is accepted, like findInDock accepts it")
    func absolutePathStringIsAccepted() {
        #expect(HelperBundleManager.dockEntryPath(entry("x", "/Users/a/Dev.app/")) == "/Users/a/Dev.app")
    }

    @Test("Only that bundle id's entries, in Dock order, nil for an unparseable one")
    func pathsAreOnlyThatBundleIdsInDockOrder() {
        let apps = [entry("a", "file:///A.app/"), entry("t", "file:///Old.app/"), entry("b", "file:///B.app/"), entry("t", nil)]
        #expect(HelperBundleManager.dockEntryPaths(bundleId: "t", in: apps) == ["/Old.app", nil])
    }

    @Test("A symlinked spelling of the helper is the same file, in both directions")
    func symlinkedPathIsCurrent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("Real.app").path
        let link = dir.appendingPathComponent("Link.app").path
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)

        #expect(HelperBundleManager.dockEntriesAreCurrent([link], helperPath: real, sameFile: HelperBundleManager.isSameFile))
        #expect(HelperBundleManager.dockEntriesAreCurrent([real], helperPath: link, sameFile: HelperBundleManager.isSameFile))
    }

    @Test("The /System/Volumes/Data spelling of the helper is the same file")
    func dataVolumeSpellingIsCurrent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("Real.app").path
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        let dataSpelling = "/System/Volumes/Data" + real
        try #require(FileManager.default.fileExists(atPath: dataSpelling))

        #expect(HelperBundleManager.dockEntriesAreCurrent([dataSpelling], helperPath: real, sameFile: HelperBundleManager.isSameFile))
    }

    @Test("Another bundle at the entry's path is stale (a leftover copy, or another tile's bundle)")
    func otherBundleWithSameIdIsStale() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("Old.app").path
        let new = dir.appendingPathComponent("New.app").path
        try FileManager.default.createDirectory(atPath: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: new, withIntermediateDirectories: true)

        #expect(!HelperBundleManager.dockEntriesAreCurrent([old], helperPath: new, sameFile: HelperBundleManager.isSameFile))
    }

    @Test("An entry at a path that no longer exists is stale (the 2026-10-29 incident)")
    func missingPathIsStale() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let new = dir.appendingPathComponent("New.app").path
        let gone = dir.appendingPathComponent("Gone.app").path
        try FileManager.default.createDirectory(atPath: new, withIntermediateDirectories: true)

        #expect(!HelperBundleManager.dockEntriesAreCurrent([gone], helperPath: new, sameFile: HelperBundleManager.isSameFile))
    }

    @Test("Two entries for one tile are never current")
    func twoEntriesAreNeverCurrent() {
        #expect(!HelperBundleManager.dockEntriesAreCurrent(["/New.app", "/New.app"], helperPath: "/New.app", sameFile: fakeSameFile()))
    }

    @Test("No entry, or only an unparseable one, is not current")
    func noEntryIsNotCurrent() {
        #expect(!HelperBundleManager.dockEntriesAreCurrent([], helperPath: "/New.app", sameFile: fakeSameFile()))
        #expect(!HelperBundleManager.dockEntriesAreCurrent([nil], helperPath: "/New.app", sameFile: fakeSameFile()))
    }
}

@Suite("addToDock reconcile")
struct DockEntryReconcileTests {

    private func reconcile(_ apps: [[String: Any]], path: String, atIndex: Int? = nil,
                           sameFile: @escaping (String, String) -> Bool = fakeSameFile()) -> [[String: Any]]? {
        HelperBundleManager.reconciledDockApps(apps, bundleId: "t", path: path,
                                               newEntry: entry("t", "file://\(path)/"),
                                               atIndex: atIndex, sameFile: sameFile)
    }

    @Test("An entry already at the helper's path needs no write")
    func alreadyCorrectNeedsNoWrite() {
        #expect(reconcile([entry("a", "file:///A.app/"), entry("t", "file:///New.app/")], path: "/New.app") == nil)
    }

    @Test("A stale path is replaced in its own slot")
    func stalePathIsReplacedInItsSlot() throws {
        let result = try #require(reconcile([entry("a", "file:///A.app/"), entry("t", "file:///Old.app/"), entry("b", "file:///B.app/")],
                                            path: "/New.app"))
        #expect(summary(result) == ["a@/A.app", "t@/New.app", "b@/B.app"])
    }

    @Test("An unparseable entry is replaced in its own slot (Q11)")
    func unparseableEntryIsReplacedInItsSlot() throws {
        let result = try #require(reconcile([entry("a", "file:///A.app/"), entry("t", nil), entry("b", "file:///B.app/")],
                                            path: "/New.app"))
        #expect(summary(result) == ["a@/A.app", "t@/New.app", "b@/B.app"])
    }

    @Test("Another spelling of the same file is left alone")
    func sameFileOtherSpellingIsLeftAlone() {
        #expect(reconcile([entry("t", "file:///Link.app/")], path: "/New.app",
                          sameFile: fakeSameFile(aliases: [["/Link.app", "/New.app"]])) == nil)
    }

    @Test("Two entries for one tile collapse to one, in the first slot")
    func duplicateCollapsesToOne() throws {
        let result = try #require(reconcile([entry("t", "file:///Old.app/"), entry("t", "file:///New.app/")], path: "/New.app"))
        #expect(summary(result) == ["t@/New.app"])
    }

    @Test("A missing entry is inserted at the index, or appended when there is none or it's out of range")
    func missingIsInsertedAtIndex() throws {
        let apps = [entry("a", "file:///A.app/"), entry("b", "file:///B.app/")]
        #expect(summary(try #require(reconcile(apps, path: "/New.app", atIndex: 1))) == ["a@/A.app", "t@/New.app", "b@/B.app"])
        #expect(summary(try #require(reconcile(apps, path: "/New.app", atIndex: nil))) == ["a@/A.app", "b@/B.app", "t@/New.app"])
        #expect(summary(try #require(reconcile(apps, path: "/New.app", atIndex: 99))) == ["a@/A.app", "b@/B.app", "t@/New.app"])
    }

    @Test("Another tile with the same name is never touched")
    func otherTileWithSameNameIsUntouched() throws {
        let result = try #require(reconcile([entry("u2", "file:///DT/Utils.app/"), entry("t", "file:///DT/Gone.app/")],
                                            path: "/DT/Utils-B4EF96A2.app"))
        #expect(summary(result) == ["u2@/DT/Utils.app", "t@/DT/Utils-B4EF96A2.app"])
    }

    @Test("This tile's entry left at a path another tile now owns is replaced (rename, then a new tile takes the name)")
    func entryAtAnotherTilesBundleIsReplaced() throws {
        let result = try #require(reconcile([entry("u2", "file:///DT/Utils.app/"), entry("t", "file:///DT/Utils.app/")],
                                            path: "/DT/Tools.app"))
        #expect(summary(result) == ["u2@/DT/Utils.app", "t@/DT/Tools.app"])
    }
}

@Suite("Dock restart signal")
struct DockRestartSignalTests {

    @Test("The Dock is restarted with SIGKILL, so the exiting Dock cannot save its stale list over our write")
    func restartSendsSIGKILL() {
        #expect(HelperBundleManager.dockRestartArguments == ["-KILL", "Dock"])
    }
}

private func present(_ id: String, _ path: String, index: Int? = nil) -> HelperBundleManager.DockExpectation {
    .init(bundleId: id, path: path, index: index, name: id)
}

private func absent(_ id: String) -> HelperBundleManager.DockExpectation {
    .init(bundleId: id, path: nil, index: nil, name: id)
}

@Suite("Verified Dock restart")
@MainActor
struct DockExpectationTests {

    private func unmet(_ e: [HelperBundleManager.DockExpectation], _ apps: [[String: Any]]) -> [HelperBundleManager.DockExpectation] {
        HelperBundleManager.unmetExpectations(e, in: apps, sameFile: fakeSameFile())
    }

    // MARK: unmetExpectations

    @Test("An entry at the expected path meets a present expectation")
    func presentAtPathIsMet() {
        #expect(unmet([present("t", "/New.app")], [entry("t", "file:///New.app/")]).isEmpty)
    }

    @Test("An entry left at another path does not meet a present expectation")
    func presentAtMissingWrongPathIsUnmet() {
        #expect(unmet([present("t", "/New.app")], [entry("t", "file:///Old.app/")]) == [present("t", "/New.app")])
    }

    @Test("No entry does not meet a present expectation")
    func presentButMissingIsUnmet() {
        #expect(unmet([present("t", "/New.app")], [entry("a", "file:///A.app/")]) == [present("t", "/New.app")])
    }

    @Test("No entry meets an absent expectation")
    func absentIsMet() {
        #expect(unmet([absent("t")], [entry("a", "file:///A.app/")]).isEmpty)
    }

    @Test("Any entry for the tile, whatever its path, fails an absent expectation")
    func absentButStaleEntryIsUnmet() {
        #expect(unmet([absent("t")], [entry("t", "file:///Old.app/")]) == [absent("t")])
    }

    @Test("Two entries for the tile fail a present expectation")
    func duplicateIsUnmet() {
        #expect(unmet([present("t", "/New.app")], [entry("t", "file:///New.app/"), entry("t", "file:///New.app/")]) == [present("t", "/New.app")])
    }

    @Test("Only the unmet expectations come back, in input order")
    func onlyUnmetReturnedInInputOrder() {
        let e = [present("a", "/A.app"), present("b", "/B.app"), present("c", "/C.app")]
        #expect(unmet(e, [entry("b", "file:///B.app/")]) == [present("a", "/A.app"), present("c", "/C.app")])
    }

    // MARK: batchExpectations

    @Test("A batch expects presence only for tiles that were pinned before it, at their index")
    func unpinnedConfigGetsNoExpectation() {
        let tiles = [(bundleId: "p", path: "/P.app", name: "p"), (bundleId: "q", path: "/Q.app", name: "q")]
        #expect(HelperBundleManager.batchExpectations(tiles, pinnedIndices: ["p": 4]) == [present("p", "/P.app", index: 4)])
    }

    @Test("A batch with no pinned tiles expects nothing")
    func noPinnedConfigsGiveNoExpectations() {
        #expect(HelperBundleManager.batchExpectations([(bundleId: "q", path: "/Q.app", name: "q")], pinnedIndices: [:]).isEmpty)
    }

    // MARK: retryableExpectations (Q16, Q18)

    @Test("A retry skips a tile the user is hiding")
    func retrySkipsTileBeingHidden() {
        #expect(HelperBundleManager.retryableExpectations([present("t", "/New.app")], busy: ["t"], owned: []).isEmpty)
    }

    @Test("A retry that expects absence skips a tile the user is adding")
    func retrySkipsAbsentWhileTileIsBeingAdded() {
        #expect(HelperBundleManager.retryableExpectations([absent("t")], busy: ["t"], owned: []).isEmpty)
    }

    @Test("A single-tile caller keeps retrying its own tile, present or absent")
    func retryKeepsCallersOwnTile() {
        #expect(HelperBundleManager.retryableExpectations([present("t", "/New.app")], busy: ["t"], owned: ["t"]) == [present("t", "/New.app")])
        #expect(HelperBundleManager.retryableExpectations([absent("t")], busy: ["t"], owned: ["t"]) == [absent("t")])
    }

    @Test("Idle tiles are retried while another tile is busy")
    func retryKeepsIdleTiles() {
        #expect(HelperBundleManager.retryableExpectations([present("t", "/New.app"), present("u", "/U.app")], busy: ["u"], owned: [])
                == [present("t", "/New.app")])
    }

    // MARK: verifying counts (Q19)

    @Test("Overlapping verifications of one tile keep it verifying until the last one ends")
    func overlappingVerificationsKeepTheTile() {
        var counts = HelperBundleManager.incrementingCounts([:], for: ["t"])
        counts = HelperBundleManager.incrementingCounts(counts, for: ["t"])
        counts = HelperBundleManager.decrementingCounts(counts, for: ["t"])
        #expect(counts == ["t": 1])
        counts = HelperBundleManager.decrementingCounts(counts, for: ["t"])
        #expect(counts.isEmpty)
    }

    // MARK: runDockVerification — restarts, fixes and the verdict, with every effect faked

    /// Runs the verification with `reads[n]` returned after restart n+1 and `busy[n]` at check n+1
    /// (the last element repeats). Returns (verdict, restarts, fixed bundle ids).
    private func verify(_ expectations: [HelperBundleManager.DockExpectation], owned: Set<String> = [],
                        reads: [[[String: Any]]], busy: [Set<String>] = [[]]) async -> (Bool, Int, [String]) {
        var restarts = 0
        var fixes: [String] = []
        let ok = await HelperBundleManager.runDockVerification(
            expectations, ownedBundleIds: owned,
            restartAndWait: { restarts += 1 },
            readApps: { reads[min(restarts, reads.count) - 1] },
            busy: { busy[min(restarts, busy.count) - 1] },
            applyFix: { fixes.append($0.bundleId) },
            sameFile: fakeSameFile())
        return (ok, restarts, fixes)
    }

    @Test("Already right after the restart: one restart, no fix, success")
    func metOnFirstCheckRestartsOnce() async {
        let (ok, restarts, fixes) = await verify([present("t", "/New.app")], reads: [[entry("t", "file:///New.app/")]])
        #expect(ok)
        #expect(restarts == 1)
        #expect(fixes.isEmpty)
    }

    @Test("Missing, fixed, then right: two restarts, one fix, success")
    func verifiedOnRetry() async {
        let (ok, restarts, fixes) = await verify([present("t", "/New.app")], reads: [[], [entry("t", "file:///New.app/")]])
        #expect(ok)
        #expect(restarts == 2)
        #expect(fixes == ["t"])
    }

    @Test("Still wrong after the retry: exactly two restarts and one fix, then failure — never a loop")
    func retriesOnceThenGivesUp() async {
        let (ok, restarts, fixes) = await verify([present("t", "/New.app")], reads: [[]])
        #expect(!ok)
        #expect(restarts == 2)
        #expect(fixes == ["t"])
    }

    @Test("A tile another operation is busy with is not retried, and is not a failure")
    func busyTileIsNotRetried() async {
        let (ok, restarts, fixes) = await verify([present("t", "/New.app")], reads: [[]], busy: [["t"]])
        #expect(ok)
        #expect(restarts == 1)
        #expect(fixes.isEmpty)
    }

    @Test("A tile that becomes busy during the retry is not reported as a failure")
    func tileThatBecomesBusyDuringRetryIsNotAFailure() async {
        let (ok, restarts, fixes) = await verify([present("t", "/New.app")], reads: [[]], busy: [[], ["t"]])
        #expect(ok)
        #expect(restarts == 2)
        #expect(fixes == ["t"])
    }

    @Test("A tile dropped as busy is left to its own operation, not re-checked after the retry")
    func droppedTileIsNotReCheckedAfterRetry() async {
        let (ok, restarts, fixes) = await verify([present("t", "/T.app"), present("u", "/U.app")],
                                                 reads: [[], [entry("t", "file:///T.app/")]],
                                                 busy: [["u"], []])
        #expect(ok)
        #expect(restarts == 2)
        #expect(fixes == ["t"])
    }
}
