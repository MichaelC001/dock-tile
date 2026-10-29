# Dock Write Race (2.6.2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every Dock change Dock Tile makes sticks at the path where the tile's helper actually lives, even when it lands seconds after another Dock restart. That covers add, update, rename, hide and delete, the migration and self-heal batches, and Popover Apply.

**Architecture:** Four changes in `HelperBundleManager`, plus two in its callers:
1. Restart the Dock with SIGKILL instead of SIGTERM, so the exiting Dock can't save its stale list over ours.
2. Use one shared "is this Dock entry current?" predicate. `addToDock` uses it to replace a stale entry in its slot. Verification and self-heal use the same predicate, so they can never disagree.
3. Send every restart through one `restartDockAndVerify` step. It waits for the new Dock, checks each tile's entry, and retries once. Tile Detail actions show a failure in the existing red error text under the editor; background batches only log it.
4. The Dock-plist watcher skips any tile whose Dock operation is still in flight, including tiles a batch is verifying.

Separately, self-heal repairs a pinned entry that has gone stale, which heals users already stranded on 2.6.1, and the launch sequence (migrate, scan, self-heal) runs once per launch.

**Tech Stack:** Swift 6, CFPreferences (`com.apple.dock` / `persistent-apps`), Swift Testing, GitHub Actions.

**Spec:** there is no separate design doc. The plan argues from three sources:
- [docs/dock-modification-prior-art.md](../../dock-modification-prior-art.md), §6 in particular: the on-Mac experiment of 2026-10-29 on macOS 27.0.1.
  - Write-then-SIGTERM lost the write 14 times out of 14 within 2.5 s of a restart, and kept it 3 times out of 3 on a settled Dock.
  - Write-then-SIGKILL kept it 13 out of 13.
  - Kill-then-write split the plist from the running Dock whenever launchd relaunched the Dock before the write landed.
  - The Dock writes its list back a few seconds after launch, so a plist read soon after a SIGTERM restart can report a success that doesn't last.
- The incident. Dev tile `DevX` was renamed to `Dev` and Updated about 2.7 s after the 2.6.1 launch migration restarted the Dock. Update deleted `DevX.app` and built `Dev.app`, but the Dock ended up with an entry that had the right bundle ID and pointed at the deleted `DevX.app`. Every check matches by bundle ID only, so nothing noticed. Self-heal keys on the bundle on disk, so it considered the tile healthy.
- The owner's decisions from the plan grill (2026-10-29), Q1–Q11, and from three plan gates, Q12–Q19. Each is restated in the task it shapes. Q4's "resolved path or exists on disk" predicate was replaced by Q14 (same file, by device and inode).

## Global Constraints

- **Platform:** macOS 15.0 floor, Swift 6 strict concurrency. `HelperBundleManager`, `HelperMigrationManager` and `ConfigurationManager` are `@MainActor`.
- **SIGKILL assumption:** the approach depends on launchd relaunching a killed Dock (the Dock agent has `KeepAlive` with `SuccessfulExit` false and `ThrottleInterval` 1). That has been read and measured on macOS 27 only. Task 6 proves it on macOS 15 and macOS 26 CI runners BEFORE any app code is written (Q17), and Task 7 proves the shipped code path on the owner's Mac. Tasks 1–5 don't start until Task 6 passes, and the fix doesn't merge until Task 7 passes (Q2).
- **Execution order (Q17):** Task 0 Step 1 → Task 6 (its own branch, merged to `main`) → Task 0 Steps 2–3 → Tasks 1–5 → Task 7. Task 6 keeps its number so the Q references stay stable.
- **Bundle-ID assumption:** every check finds a tile's entries by `tile-data.bundle-identifier`, which our `addToDock` writes. That relies on the Dock keeping the key when it writes its list back. §6 matched every entry by that key after every restart on macOS 27, and Task 6 matches by it on macOS 15 and 26, so it proves the key survives there too.
- **SIGKILL's accepted cost (Q1):** any Dock edit the Dock hasn't saved yet when we kill it is lost, for example an icon dragged a second before Update. This is accepted. Task 7 measures it; it doesn't gate on it.
- **New decision logic** is a `nonisolated static func` taking plain values, with unit tests (testing.md, "Regression-Guard Convention"). Filesystem access is passed in as closures, so the seams stay pure.
- **Tests and files:** new tests go in `DockTileTests/` (auto-joins the target). No new app-target files; append to existing files instead (a new one needs a pbxproj edit). `Scripts/ci/` files aren't in any target.
- **No default parameter values** on new or changed seams (`classifyHelperHealth`, `resolveDockVisibility`, the predicate seams), so a missed caller is a compile error. Defaults in test-file helpers are fine.
- **Dock writes** stay on CFPreferences (`CFPreferencesSetAppValue` + `CFPreferencesAppSynchronize`). Never write the plist file.
- **Never pin a tile the user didn't pin.** Verification and retry may only expect presence for a tile that was in the Dock before the operation, or that the operation is adding (architecture.md, "Never-pinned guard"). A retry also never re-adds a tile that another of our operations is building or removing at that moment (Q16).
- **A removal with nothing to remove** still must not restart the Dock (`shouldPerformDockRemoval`, unchanged).
- **Logging:**
  - Logs that name a tile use `config.diagnosticName`.
  - Verification failures, stale-entry replacements and restart failures are non-verbose, on the `dock` category.
  - The per-restart "pid A → B" line is verbose (dev only), on `dock`.
- **Strings:** user-visible text goes through `AppStrings` and the String Catalog workflow (localization-macos.md).
- **Branch and commits:** work on `fix/dock-write-race` off `main`. Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Run `/simplify` right before each code commit (Tasks 1–6), never for docs-only commits.
- **Out of scope:**
  - the 2.6.2 version bump and release;
  - MDM-locked Docks (`contents-immutable`);
  - batching the launch reconcile's one restart per stuck tile;
  - install's early plist removal (Q7, option (c) — its own change, with its own experiment);
  - an orphaned Dock entry left by a delete whose removal didn't stick, since self-heal only walks existing configs. That case is logged only;
  - two bundles with one bundle ID, left when the rename's `try? FileManager.default.removeItem` ([HelperBundleManager.swift:173](../../../DockTile/Managers/HelperBundleManager.swift)) fails. `helperPath(for:)` returns whichever copy the folder listing gives first, and the checks compare against that copy. Removing the leftover is its own change;
  - `findInDock` still skips an entry whose URL can't be parsed, so the watcher reads such a tile as absent. That's unchanged behaviour for a Dock state never observed. The writers this plan relies on (`removeFromDockPlist`, `refreshDockEntry`, `reconciledDockApps`) do match it by bundle ID;
  - `removeFromDockPlist`'s existing rule that also drops any entry whose path contains `DockTile` and whose Info.plist is missing, which can clean another tile's stranded entry. Unchanged.
- **No cross-tile operation queue.** Every read-modify-write of `persistent-apps` runs synchronously on the main actor, so two of our operations can't lose each other's write. The only lost-update source measured is the Dock's own write-back, which SIGKILL and verification address.

## Review Focus

1. **The URL is stored two ways.** `addToDock` writes `file:///…/Application Support/…/` unencoded, and the Dock rewrites it with `%20`. Both must compare equal to the helper's path. Pinned in Task 2 (`encodedAndUnencodedURLsGiveTheSamePath`).
2. **The same bundle, spelled differently.** A symlinked folder or a `/System/Volumes/Data` prefix must not read as stale, or self-heal would rebuild and restart the Dock on every launch. Q14's predicate treats an entry as current only when `stat()` on its path and on the helper's path give the same device and inode. `stat()` follows symlinks, and the Data-volume spelling is the same file. Pinned in Task 2 against real temp folders (`symlinkedPathIsCurrent`, `dataVolumeSpellingIsCurrent`).
3. **A path that exists but is the wrong bundle.** Two cases:
   - another tile's bundle took over the old path: "Utils" renamed to "Tools", then a new tile named "Utils" got `Utils.app`. Clicking the old entry would launch the other tile.
   - a leftover copy of this tile's own bundle.

   Both must read as stale. Two tiles that share a name must not touch each other's entries either: `Utils.app` belongs to another tile, and this tile's helper is `Utils-B4EF96A2.app`. Pinned in Task 2 (`otherBundleWithSameIdIsStale`, `entryAtAnotherTilesBundleIsReplaced`, `otherTileWithSameNameIsUntouched`).
4. **Duplicate entries for one bundle ID, or an unparseable one.**
   - Two entries for one bundle ID collapse to exactly one, at the helper path.
   - An entry whose URL can't be parsed counts as stale and is replaced in its slot (Q11).
   - "Expect absent" fails on ANY entry with that bundle ID, whatever its path.
   - Pinned in Task 2 (`duplicateCollapsesToOne`, `unparseableEntryIsReplacedInItsSlot`) and Task 3 (`duplicateIsUnmet`, `absentButStaleEntryIsUnmet`).
5. **A batch rebuild of a tile that isn't pinned.** Popover Apply rebuilds `isVisibleInDock && helperExists` tiles, which includes one the user dragged off the Dock before the watcher marked it. The batch's retry must not re-pin it. Pinned in Task 3 (`unpinnedConfigGetsNoExpectation`).
   - **Where verification sits (Q9, Q12):** the batch's verification runs after every per-tile `regenerateHelperBundle`, outside the `buildingBundleIds` locks. If a later change moves it inside, a Hide pressed during the batch would be refused for seconds longer. For those seconds the tiles being verified sit in a separate `verifyingBundleIds` set. The watcher treats them as in flight, so it can't mark a tile hidden that the retry is about to re-pin (which would leave it hidden in config but pinned, and the next launch's reconcile would remove it). The build lock ignores that set. Pinned in Task 5 (`verifyingCountsAsInFlight`); the build-lock half is structural (Task 5 Step 4).
   - **A Hide, Update or Add pressed while another operation verifies (Q16, Q18):** that operation's retry skips the tile, so the user's action isn't undone. Pinned in Task 3 (`retrySkipsTileBeingHidden`, `retrySkipsAbsentWhileTileIsBeingAdded`, `retryKeepsCallersOwnTile`, `busyTileIsNotRetried`).
   - **Accepted, not fixed (Q8):** a tile dragged off within about 1 s of a restart, while the new Dock is still starting, can be re-pinned by the retry. That's smaller than the window install's current step 8 already has. architecture.md documents it.

---

### Task 0: Branch setup and baseline repro (no code)

- [ ] **Step 1 (Q10):** On `main`, commit only `.claude/rules/ci-release.md` as `docs(rules): two CI false alarms from 2026-10-28` and push it. `.claude/` isn't matched by `paths-ignore`'s `'*.md'`, so the push runs CI once, which is expected.
- [ ] **Now run Task 6** (Q17). Continue with Step 2 only after Task 6 has merged to `main`.
- [ ] **Step 2:** `git switch main && git pull --ff-only && git switch -c fix/dock-write-race`. Commit `docs/dock-modification-prior-art.md` and this plan as `docs: Dock write-race prior art, experiment and 2.6.2 plan`. Both files stay untracked in the working tree until then; keep them out of Task 6's branch.
- [ ] **Step 3: same-session A/B, before any change (performance-measurement.md).** This needs the owner's OK, because it restarts the Dock and drives the dev app through AX.
  1. Rebuild Debug signed (`xcodebuild -project DockTile.xcodeproj -scheme DockTile -configuration Debug build`).
  2. Check `codesign --verify` on the product, then launch it.
  3. On a pinned dev tile, change its Name (folder rename pending), run `killall Dock`, wait 1 s, and press **Update** (AX, by button name).
  4. After 15 s, read that bundle ID's `_CFURLString` (`defaults read com.apple.dock persistent-apps`) and the Dock's AX item names.
  5. Repeat three times, renaming back and forth. On today's code, expect at least one run to leave the entry at the OLD folder path. Record the counts for the PR description. If it never reproduces, say so and carry on: §6 already reproduces the underlying race.

---

### Task 1: Restart the Dock with SIGKILL, and log the restart

**Files:**
- Modify: `DockTile/Managers/HelperBundleManager.swift:1884-1900` (`restartDock`)
- Modify: `.claude/rules/architecture.md`, the paragraph "The dying Dock can undo your write (critical)"
- Test: `DockTileTests/Unit/Managers/DockEntryVerificationTests.swift` (new)

**Interfaces:**
- Produces: `nonisolated static let dockRestartArguments: [String]` on `HelperBundleManager`, equal to `["-KILL", "Dock"]`. `restartDock()` passes it to `/usr/bin/killall`.

- [ ] **Step 1: Write the failing test.** New file, suite `DockRestartSignalTests`:

```swift
@Test("The Dock is restarted with SIGKILL, so the exiting Dock cannot save its stale list over our write")
func restartSendsSIGKILL() {
    #expect(HelperBundleManager.dockRestartArguments == ["-KILL", "Dock"])
}
```

- [ ] **Step 2:** Run `xcodebuild test … -only-testing:DockTileTests/DockRestartSignalTests CODE_SIGNING_ALLOWED=NO` (the full flags are in CLAUDE.md). Expected: build failure, `dockRestartArguments` not found.
- [ ] **Step 3: Implement.**
  - Add the constant, and have `restartDock()` use it as `process.arguments`.
  - Replace `try? process.run()` with `do { try process.run(); process.waitUntilExit() } catch { … }`. killall returns in milliseconds.
  - Log non-verbose on `dock` when `run()` throws or `terminationStatus != 0` (exit 1 means no Dock process matched). That replaces a silent swallow.
  - Rewrite the doc comment: it sends SIGKILL, and why, in one line with the §6 numbers and a link to the doc.
  - Keep the `.dockDidRestart` post.
- [ ] **Step 4:** Re-run Step 2. Expected: PASS. The test pins only the constant; it can't fail if `restartDock()` stops using it. So also run `grep -n "dockRestartArguments" DockTile/Managers/HelperBundleManager.swift`. Expected: the definition and exactly one use, `process.arguments = Self.dockRestartArguments` in `restartDock()`. The behavioural guards are Task 6 (CI) and Task 7 Step 3's pid lines.
- [ ] **Step 5: Update the architecture.md paragraph.**
  - The mechanism is now write, then SIGKILL (§6), replacing "verify, then retry via quit-and-wait". Keep the 2026-08-29 history in one clause.
  - Add the accepted cost: an unsaved Dock edit is lost.
  - Add that it depends on launchd relaunching the Dock, proven by Task 6's CI job (macOS 15 and 26) and Task 7 (macOS 27).

  Commit as `fix(dock): restart the Dock with SIGKILL so a dying Dock can't undo our write`.

---

### Task 2: One "is this entry current?" predicate; `addToDock` replaces a stale entry

Q14 (replacing Q4): an entry is **current** when it is the same file as the helper: `stat()` on both paths succeeds and gives the same `st_dev` and `st_ino`. Everything else is **stale**: a missing path, another tile's bundle at the old path, a leftover copy of this tile's bundle, or an entry that can't be parsed (Q11). The tile's entries are current only when there is exactly ONE entry and that one is current. This exact predicate is used in three places: `addToDock` (here), verification (Task 3) and self-heal (Task 4).

Why not compare bundle IDs: `helperPath(for:)` already finds the bundle by ID ([HelperBundleManager.swift:377-383](../../../DockTile/Managers/HelperBundleManager.swift)), so a second path carrying the same ID is a leftover copy, which would launch old code. And `Bundle(path:)` caches by path, so it would report a replaced bundle's old ID.

**Files:**
- Modify: `DockTile/Managers/HelperBundleManager.swift`, `addToDock(at:atIndex:)` (1755-1837), with the new static seams just above it
- Test: `DockTileTests/Unit/Managers/DockEntryVerificationTests.swift`, suites `DockEntryPathTests` and `DockEntryReconcileTests`

**Interfaces:**
- Produces, all on `HelperBundleManager`:
  - `nonisolated static func dockEntryPath(_ entry: [String: Any]) -> String?` returns the entry's `tile-data.file-data._CFURLString` as a file path: `"/" + URL(string:).path` with slashes trimmed, the same normalisation `findInDock` uses. A string that is already an absolute path (starts with `/`) is accepted as is, trimmed the same way, because `findInDock`'s `URL(string:)` accepts it too. The owner's Dock shows only `_CFURLStringType` 15 (URL) entries, but a stricter reader than `findInDock` would make self-heal rebuild a type-0 entry on every launch. It returns `nil` when the string is missing or is any other scheme.
  - `nonisolated static func dockEntryPaths(bundleId: String, in apps: [[String: Any]]) -> [String?]` returns one element per entry whose `tile-data.bundle-identifier == bundleId`, in Dock order, with `nil` for an unparseable one. It's pure, so it does no Info.plist fallback; our `addToDock` always writes `bundle-identifier`.
  - `nonisolated static func dockEntriesAreCurrent(_ paths: [String?], helperPath: String, sameFile: (String, String) -> Bool) -> Bool` returns `paths.count == 1`, AND that one is non-nil, AND `sameFile(p, helperPath)`.
  - `nonisolated static func reconciledDockApps(_ apps: [[String: Any]], bundleId: String, path: String, newEntry: [String: Any], atIndex: Int?, sameFile: (String, String) -> Bool) -> [[String: Any]]?`
    - Returns `nil` (no write needed) when `dockEntriesAreCurrent(dockEntryPaths(…), helperPath: path, sameFile:)`.
    - Otherwise removes every entry with `bundleId` and inserts `newEntry`: at the index of the first removed entry if there was one, so a stale entry keeps its slot; else at `atIndex` when that's in `0...count`; else at the end.
  - The production closure is `nonisolated static func isSameFile(_ a: String, _ b: String) -> Bool`. It's internal, not private, so tests call it. It uses Darwin `stat()`, which follows symlinks, and returns `false` when either call fails. Otherwise it returns `st_dev` and `st_ino` both equal.

- [ ] **Step 1: Write the failing tests.**
  - Test-file helper: `func entry(_ id: String, _ url: String?) -> [String: Any]` builds `["tile-type": "file-tile", "tile-data": ["bundle-identifier": id, "file-data": url.map { ["_CFURLString": $0, "_CFURLStringType": 15] } ?? [:]]]`.
  - Fake closure: `sameFile = { a, b in a == b || aliases.contains([a, b]) }`, where a test passes a set of path pairs that name one file. Every test that needs real file identity uses `isSameFile` against a temp folder, created per test and removed in a `defer`.

```swift
// DockEntryPathTests
@Test func encodedAndUnencodedURLsGiveTheSamePath() {
    let p = "/Users/a/Library/Application Support/DockTile/Dev.app"
    #expect(HelperBundleManager.dockEntryPath(entry("x", "file:///Users/a/Library/Application%20Support/DockTile/Dev.app/")) == p)
    #expect(HelperBundleManager.dockEntryPath(entry("x", "file:///Users/a/Library/Application Support/DockTile/Dev.app/")) == p)
}
@Test func unparseableURLGivesNil()             // entry("x", nil) and entry("x", "https://e.com/") → nil
@Test func absolutePathStringIsAccepted()       // entry("x", "/Users/a/Dev.app/") → "/Users/a/Dev.app"
@Test func pathsAreOnlyThatBundleIdsInDockOrder() {
    let apps = [entry("a", "file:///A.app/"), entry("t", "file:///Old.app/"), entry("b", "file:///B.app/"), entry("t", nil)]
    #expect(HelperBundleManager.dockEntryPaths(bundleId: "t", in: apps) == ["/Old.app", nil])
}
@Test func symlinkedPathIsCurrent()             // real temp dir: Real.app + Link -> Real.app; isSameFile;
                                                //   [Link] vs helperPath Real → true, and [Real] vs helperPath Link → true
@Test func dataVolumeSpellingIsCurrent()        // real temp Real.app; #require that "/System/Volumes/Data" + its resolved path exists;
                                                //   [that spelling] vs helperPath Real → true
@Test func otherBundleWithSameIdIsStale()       // real temp dir: Old.app and New.app, two folders; isSameFile;
                                                //   [Old] vs New → false (a leftover copy, or another tile's bundle at the old path)
@Test func missingPathIsStale()                 // real temp dir: New.app exists, Gone.app doesn't; isSameFile; [Gone] vs New → false
@Test func twoEntriesAreNeverCurrent()          // fake; [/New.app, /New.app] vs /New.app → false
@Test func noEntryIsNotCurrent()                // fake; [] → false; [nil] → false

// DockEntryReconcileTests — fake sameFile; compare results by each element's bundle id + dockEntryPath
@Test func alreadyCorrectNeedsNoWrite()            // [a, t@/New.app] → nil
@Test func stalePathIsReplacedInItsSlot()          // [a, t@/Old.app, b], path /New.app → 3 entries; [1] is newEntry; [0], [2] unchanged
@Test func unparseableEntryIsReplacedInItsSlot()   // [a, t@nil, b] → [1] is newEntry
@Test func sameFileOtherSpellingIsLeftAlone()      // aliases {[/Link.app, /New.app]}; [t@/Link.app], path /New.app → nil
@Test func duplicateCollapsesToOne()               // [t@/Old.app, t@/New.app] → exactly one t entry, at index 0, path /New.app
@Test func missingIsInsertedAtIndex()              // [a, b], atIndex 1 → newEntry at 1; atIndex nil → appended; atIndex 99 → appended
@Test func otherTileWithSameNameIsUntouched()      // [u2@/DT/Utils.app, t@/DT/Gone.app], path /DT/Utils-B4EF96A2.app
                                                   //   → u2 entry identical at 0, t at index 1 with the new path
@Test func entryAtAnotherTilesBundleIsReplaced()   // [u2@/DT/Utils.app, t@/DT/Utils.app], path /DT/Tools.app (the F5 rename case)
                                                   //   → u2 entry identical at 0, t at index 1 with /DT/Tools.app
```

Each `@Test` body asserts exact counts, indices and paths; the comments give the values.

- [ ] **Step 2:** Run `-only-testing:DockTileTests/DockEntryPathTests -only-testing:DockTileTests/DockEntryReconcileTests`. Expected: build failure, symbols missing.
- [ ] **Step 3: Implement the seams, then change `addToDock`.**
  - `addToDock` keeps its Info.plist read and its `newEntry` construction, with the fields unchanged.
  - It replaces the `findInDock(bundleId:) != nil` early return with `reconciledDockApps(currentApps, …)`.
  - When that returns `nil`, it logs `"Already in Dock at this path - no action needed"` and returns.
  - When existing entries are replaced, it logs `"Replacing stale Dock entry at <old paths>"`, non-verbose, on `dock`.
- [ ] **Step 4:** Re-run Step 2. Expected: PASS.
- [ ] **Step 5:** Add a line to the testing.md seam list: "`dockEntriesAreCurrent` / `reconciledDockApps` / `isSameFile`: one entry that is the same file as the helper (device + inode, so symlinks and the Data-volume spelling pass) is current; a missing path, another bundle at the path, an unparseable entry or a duplicate is replaced in the first slot; another tile's entry is never touched; `DockEntryPathTests` + `DockEntryReconcileTests`." Commit as `fix(dock): addToDock replaces an entry left at an old helper path`.

---

### Task 3: One verified restart for every Dock change

Q5: verify once the new Dock process appears, plus 1 s, then retry once. With SIGKILL there's no exit flush to wait out: the new Dock rereads our plist, and its own write-back a few seconds later keeps our entry.

**Limits, stated in architecture.md:**
- Verification reads the plist, so it can't detect the plist and the running Dock disagreeing. Seeing what the Dock shows needs Accessibility, which the main app only has with Dock Lock on.
- **The +1 s read can come before the new Dock's write-back** (a few seconds after launch, §6). That's accepted. The write-back carries the list the new Dock loaded, which is ours. It would only differ if the Dock dropped an entry when it loads it. The incident suggests it doesn't, even for a missing bundle: the Dock kept an entry pointing at the deleted `DevX.app`. In any case, every path we expect present was just built. Waiting out the write-back would add several seconds to every Update. A drop that happens later anyway is caught by self-heal on the next launch (Task 4).

**Cancellation (decided):** once we've killed the Dock, verification must finish. `restartDockAndVerify` runs its body in an unstructured `Task { @MainActor in … }` and awaits its `.value`. An unstructured task doesn't inherit the caller's cancellation, so when the main window's `.task` (migration, self-heal) is cancelled because the window closed, `Task.sleep` can't return early and turn the 5 s poll into a spin. `performDockAction` already runs in an unstructured `Task`.

Q12: while `restartDockAndVerify` runs, the expectations' bundle IDs are counted in `verifyingCounts` (exposed as `verifyingBundleIds`): incremented at its start and decremented in a `defer`. It's a count so overlapping verifications of one tile don't clear each other (Q19). Task 5 makes the watcher skip them. It's scoped there because the batch's re-seat (`refreshDockEntry`) is synchronous on the main actor, so the watcher can't run in the middle of it. The only suspensions with a stale or missing entry are inside this function.

Q13: when verification still fails after the retry, Tile Detail actions (Add to Dock, Update, Hide) throw a new error. `performDockAction`'s existing catch shows it in the red error text under the editor ([DockTileDetailView.swift:590-591](../../../DockTile/Views/DockTileDetailView.swift)), like every other failure on that button. There's no new UI. Delete and the background batches only log.

**Files:**
- Modify: `DockTile/Managers/HelperBundleManager.swift`
  - `installHelper` steps 6–8 (204-228) and the end of the function
  - `removeFromDock(for:)` (716-746)
  - `uninstallHelper` (337-342)
  - `removeFromDockPlist(bundleId:)` (1657): check `tile-data.bundle-identifier` BEFORE the `file-data` URL guard (1668-1677), which currently keeps an unparseable entry whatever its bundle ID. Otherwise an "expect absent" retry could never remove the entry the shared predicate counts.
  - a new `private var verifyingCounts: [String: Int] = [:]` beside `removingBundleIds` (47). It's a count, not a set (Q19): two verifications can overlap on one tile (an Update during a batch's check, or Apply overlapping the launch batch), and with a set the first to finish would clear the tile while the second still checks it.
  - `HelperBundleError` (2037) and `errorDescription`
  - Delete `quitDockAndWaitForExit` (1912), `waitForTileRemoval` (1928) and `performDockRestart` (2018): this task orphans each of them. Keep `removeFromDock(at:)` (1841). It was already uncalled before this change, so removing it is not this change's cleanup.
- Modify: `DockTile/Managers/HelperMigrationManager.swift`, `regenerateBatch` (244-259)
- Modify: `DockTile/Views/DockTileDetailView.swift`, `performDockAction`'s generic catch (739-745): one line, see Step 4
- Unchanged, but a caller of the changed `removeFromDock(for:)`: the launch reconcile's stuck-tile sweep (`ConfigurationManager.syncDockVisibility`, about 672-680). Its catch already logs non-verbose on `sync`, so a `dockChangeNotKept` there is logged only.
- Modify: `DockTile/Constants/AppStrings.swift` (`Error`, after `bundleBuildInProgress` at 1506), `DockTile/Resources/Localizable.xcstrings` (via `l10n.py`), `docs/l10n/*.md`
- Modify: `.claude/rules/architecture.md` (the same paragraph as Task 1, the verification half, plus the Q8 note), `.claude/rules/testing.md`
- Test: `DockTileTests/Unit/Managers/DockEntryVerificationTests.swift`, suite `DockExpectationTests`

**Interfaces:**
- Consumes: `dockEntryPaths(bundleId:in:)` and `dockEntriesAreCurrent(…)` (Task 2); `addToDock(at:atIndex:)`, which now reconciles; `restartDock()` (SIGKILL, Task 1).
- Produces:
  - `struct DockExpectation: Equatable, Sendable { let bundleId: String; let path: String?; let index: Int?; let name: String }`, nested in `HelperBundleManager`, nonisolated.
    - `path == nil` means "must be absent".
    - `index` is where a missing entry is re-added.
    - `name` is the `diagnosticName`, for logs.
  - `nonisolated static func unmetExpectations(_ expectations: [DockExpectation], in apps: [[String: Any]], sameFile: (String, String) -> Bool) -> [DockExpectation]` returns, in input order, the expectations NOT met. An absent expectation is met when `dockEntryPaths` is empty. A present one is met when `dockEntriesAreCurrent(dockEntryPaths(…), helperPath: path, sameFile:)`.
  - `nonisolated static func incrementingCounts(_ counts: [String: Int], for ids: [String]) -> [String: Int]` and `decrementingCounts(_:for:)`, which drops a key when it reaches 0. `restartDockAndVerify` applies the first at its start and the second in its `defer`, and is their only caller.
  - `var verifyingBundleIds: Set<String> { Set(verifyingCounts.keys) }`, read by Task 5.
  - `nonisolated static func batchExpectations(_ tiles: [(bundleId: String, path: String, name: String)], pinnedIndices: [String: Int]) -> [DockExpectation]` returns one present expectation per tile whose `bundleId` is a key of `pinnedIndices`, with `index` taken from it. Tiles that weren't pinned get none.
  - `nonisolated static func retryableExpectations(_ unmet: [DockExpectation], busy: Set<String>, owned: Set<String>) -> [DockExpectation]` (Q16, made symmetric by Q18) drops every expectation, present or absent, whose `bundleId` is in `busy` and not in `owned`. It keeps everything else in input order. In production, `busy` is `buildingBundleIds ∪ removingBundleIds`, never `verifyingBundleIds`, and `owned` is the caller's own tile. Why:
    - **Present:** a Hide or Update the user starts while a batch verifies would otherwise be undone by the batch's retry. The retry would re-add the entry the Hide just removed, leaving the tile stored hidden but pinned until the next launch's reconcile.
    - **Absent:** the launch reconcile's removal of a stuck tile (`ConfigurationManager.swift:673-681`) would otherwise delete the entry an Add the user just pressed wrote. It converged only through extra restarts and could show a false `dockChangeNotKept`.
    - `owned` keeps each single-tile caller's retry for its own tile, which it holds in `buildingBundleIds` (install) or `removingBundleIds` (hide).
  - `static func runDockVerification(_ expectations: [DockExpectation], ownedBundleIds: Set<String>, restartAndWait: () async -> Void, readApps: () -> [[String: Any]], busy: () -> Set<String>, applyFix: (DockExpectation) -> Void, sameFile: (String, String) -> Bool) async -> Bool`. It's a plain `static` on the `@MainActor` class, so its closures need not be Sendable. It holds Step 3's steps 2–10 with everything external injected, like `runRegenerationBatch`, so "retry once, never loop" and "filter before fix" are unit-tested. `restartDockAndVerify` is the counts plus the unstructured task around it, passing the production closures: the restart-and-PID-wait plus 1 s, the synchronized read, `buildingBundleIds ∪ removingBundleIds`, the fix from step 7, and `isSameFile`.
  - `func restartDockAndVerify(_ expectations: [DockExpectation], ownedBundleIds: Set<String>) async -> Bool` (not `@discardableResult`: each caller decides what a failure means; no default on `ownedBundleIds`).
  - `HelperBundleError.dockChangeNotKept`, with `errorDescription` set to `AppStrings.Error.dockChangeNotKept`.
  - `AppStrings.Error.dockChangeNotKept`: key `error.dockChangeNotKept`, value `"The Dock didn't keep this change. Try again."`, comment `"Error when Dock Tile wrote a change to the Dock (add, update or hide a tile) but the Dock did not keep it, even after one retry"`.

- [ ] **Step 1: Write the failing tests** in suite `DockExpectationTests`, reusing `entry(_:_:)` and the fake closures.

```swift
@Test func presentAtPathIsMet()                    // [t@/New.app], expect t@/New.app → []
@Test func presentAtMissingWrongPathIsUnmet()      // [t@/Old.app (missing)], expect t@/New.app → [that expectation]
@Test func presentButMissingIsUnmet()              // [a], expect t@/New.app → [it]
@Test func absentIsMet()                           // [a], expect t absent → []
@Test func absentButStaleEntryIsUnmet()            // [t@/Old.app], expect t absent → [it]
@Test func duplicateIsUnmet()                      // [t@/New.app, t@/New.app], expect t@/New.app → [it]
@Test func onlyUnmetReturnedInInputOrder()         // three expectations, 1st and 3rd unmet → [1st, 3rd]
@Test func unpinnedConfigGetsNoExpectation()       // tiles [p, q], pinnedIndices [p: 4] → exactly [p@its path, index 4]
@Test func noPinnedConfigsGiveNoExpectations()     // tiles [q], pinnedIndices [:] → []
@Test func retrySkipsTileBeingHidden()             // unmet [t@/New.app], busy {t}, owned {} → []
@Test func retrySkipsAbsentWhileTileIsBeingAdded() // unmet [t absent], busy {t}, owned {} → [] (Q18)
@Test func retryKeepsCallersOwnTile()              // unmet [t@/New.app], busy {t}, owned {t} → [it] (installHelper's own retry);
                                                   //   unmet [t absent], busy {t}, owned {t} → [it] (removeFromDock(for:)'s own retry)
@Test func overlappingVerificationsKeepTheTile()   // increment [t] twice, decrement [t] once → [t: 1]; decrement again → [:] (Q19)
@Test func retryKeepsIdleTiles()                   // unmet [t@/New.app, u@/U.app], busy {u}, owned {} → [t]

// runDockVerification — @MainActor tests; fakes count restarts and fixes; readApps returns a scripted sequence
@Test func metOnFirstCheckRestartsOnce()           // apps already met → restarts 1, fixes 0, true
@Test func verifiedOnRetry()                       // unmet, then met → restarts 2, fixes 1, true
@Test func retriesOnceThenGivesUp()                // always unmet → restarts exactly 2, fixes 1, false (never loops)
@Test func busyTileIsNotRetried()                  // unmet t, busy {t}, owned {} → restarts 1, fixes 0, true
@Test func tileThatBecomesBusyDuringRetryIsNotAFailure() // unmet t; busy {} at the first check, {t} at the second → restarts 2, true
@Test func droppedTileIsNotReCheckedAfterRetry()   // expectations t, u; first check: both unmet, busy {u} → only t is fixed;
                                                   //   second check: t met, u still unmet, busy {} → true, fixes 1 (u never reported STILL)
```

- [ ] **Step 2:** Run `-only-testing:DockTileTests/DockExpectationTests`. Expected: build failure.
- [ ] **Step 3: Implement `unmetExpectations`, `batchExpectations`, `retryableExpectations`, the count helpers, `runDockVerification` and `restartDockAndVerify`.** Together the last two work like this; step 1 and the unstructured task belong to `restartDockAndVerify`, and steps 2–10 to `runDockVerification`, through its closures:
  1. `verifyingCounts = incrementingCounts(verifyingCounts, for: ids)`, with a `defer` that applies `decrementingCounts` for the same ids.
  2. Note the Dock's PID and call `restartDock()`. The PID is the first instance of `NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")` that is `!isTerminated`. When none is running, the old PID is `nil`: `restartDock()` still runs (killall's exit 1 is logged, Task 1), and step 3 waits for any Dock to appear.
  3. Poll every 50 ms with `Task.sleep`, for up to 5 s, until that list contains an instance that is `!isTerminated` with a PID different from the old one. The killed instance can still be listed for a moment, so `.first` isn't enough. Log verbose on `dock`: `"Dock restarted (pid A → B)"`, or `"no new Dock within 5 s (pid A)"` non-verbose. Then sleep 1 s.
     - **Assumption, unproven until Task 7:** `NSRunningApplication` updates this list and `isTerminated` while the main actor is suspended in `Task.sleep`. Nothing in the codebase shows it yet; the old `quitDockAndWaitForExit` blocked the thread with `usleep`.
     - If the assumption is wrong, every restart silently costs about 6 s (twice with a retry). Task 7 Step 3 makes the pid line a stop condition.
  4. Read `persistent-apps` (synchronize first) and compute the unmet expectations, passing `sameFile: isSameFile`. If there are none, return `true`.
  5. Filter them through `retryableExpectations(unmet, busy: buildingBundleIds.union(removingBundleIds), owned: ownedBundleIds)`. Log each dropped one non-verbose: `"<name> has another Dock operation in flight — leaving it to that operation"`. Dropped ones aren't failures. If none remain, return `true`.
  6. Otherwise, per remaining expectation, log non-verbose: `"<name> not at its expected Dock path after restart (found: <paths>) — retrying"`.
  7. Apply each fix with an `if`/`else`, since the two calls return different types: `if let path { addToDock(at: URL(fileURLWithPath: path), atIndex: index) } else { removeFromDockPlist(bundleId:) }`. Steps 4–7 contain no `await`, so a Hide can't start between the filter and the fix.
  8. Restart, wait and re-check exactly once more, the same way, including the pid log. The re-check covers **only the expectations retried in step 7**. One dropped as busy in step 5 is left to its own operation for good: if that operation has finished by step 8, it would read unmet and not busy, which would be a false STILL. The retried subset's final unmet list goes through `retryableExpectations` again, with `busy` read at that moment. An expectation whose tile became busy during the retry wait is dropped and logged as in step 5, not reported as STILL. Otherwise a Hide pressed during the retry would produce a false non-verbose failure line.
  9. If it still fails, log `"<name> STILL not at its expected Dock path after retry"` and return `false`. If it passes, log `"… verified on retry"` and return `true`.
  10. Never loop. An empty expectation list still restarts once and returns `true`.

  **Considered, not taken: no verification at all** (SIGKILL, plus `addToDock`'s reconcile, plus self-heal). After SIGKILL, verification fails only if the new Dock drops an entry within ~1 s, so this would usually work. It was rejected by Q5 and Q13: verification is the only thing that tells the user in the same session, and its log lines are the only evidence from production.

  **Residual (delete during a batch's check):** `uninstallHelper` never registers in `removingBundleIds`, so a batch checking a tile the user just deleted keeps its present expectation. The retry's `addToDock` then no-ops, because the bundle is gone and the Info.plist guard at `HelperBundleManager.swift:1765` returns. The result is a false "STILL not at its expected Dock path" line, logged only. Accepted, and listed with the residuals in architecture.md.

  **Residual (Q16):** a Hide that starts after the batch's restart and finishes, verified, before the batch's check is no longer in `removingBundleIds` when the batch looks. The retry then re-pins the tile, and the next launch's reconcile removes it, so the user's intent wins one launch late. That needs a whole Hide cycle (a restart plus ≥ 1 s) to fit inside the batch's ~1 s window, so it's narrow.
- [ ] **Step 4: Wire the single-tile callers.**
  - **`ownedBundleIds` per caller (Q18):** every single-tile caller (`installHelper`, `removeFromDock(for:)`, `uninstallHelper`) passes `[config.bundleIdentifier]`; the batch passes `[]`.
  - **`installHelper`:** steps 6–8 become `let dockKept = await restartDockAndVerify([.init(bundleId: config.bundleIdentifier, path: helperPath.path, index: originalDockIndex, name: config.diagnosticName)], ownedBundleIds: [config.bundleIdentifier])`. Keep the breadcrumb and step 9 (launch). Just before the function's successful return, add `guard dockKept else { throw HelperBundleError.dockChangeNotKept }`. The helper is still built and launched, and the user is told the Dock didn't keep it.
  - **`removeFromDock(for:)`:** inside `if didRemoveFromPlist`, the restart, both `waitForTileRemoval` calls and the quit-and-wait retry become one `restartDockAndVerify([.init(…, path: nil, index: nil, …)], ownedBundleIds: [config.bundleIdentifier])`. On `false`, throw `.dockChangeNotKept`. On `true`, keep the existing "Removed … from Dock (verified)" log line.
  - **`uninstallHelper`:** `restartDock()` becomes the same absent expectation. A `false` result is logged only: deletion has already removed the config, and its caller only records errors.
  - **`removeFromDockPlist`:** move the `bundle-identifier` match above the URL guard, as listed under Files. No unit test reaches this private CFPreferences writer; the same rule's pure half is pinned by `pathsAreOnlyThatBundleIdsInDockOrder`, which counts an unparseable entry.
  - **What a `dockChangeNotKept` from `installHelper` or `removeFromDock(for:)` skips in `performDockAction`:** the throw lands in the generic catch, so none of the success path runs:
    - the `lastDockIndex` clear and the `helperAppVersion` stamp (the next launch's migration rebuilds the tile, which is harmless);
    - the analytics event;
    - `updateConfiguration` (edits are already saved by the debounced auto-save; `isVisibleInDock` stays as stored, which is the visibility-ownership rule);
    - `commitDisplayName` (the sidebar keeps the old name until a retry succeeds);
    - `appliedContentSignature` (the button stays enabled, which invites the retry);
    - `updateDockState`.

    That's accepted: one successful retry completes all of it. The generic catch also calls `AnalyticsService.record`, so every `dockChangeNotKept` becomes a Crashlytics non-fatal (context `performDockAction`). That's intended: it's the only production count of how often the Dock still refuses a change after SIGKILL, and it needs no new GA4 parameter. Add one line to the generic catch: `if (error as? HelperBundleError) == .dockChangeNotKept { updateDockState() }`. The button's label then follows the real Dock (Add to Dock vs Update) rather than the state from before the attempt.
- [ ] **Step 5: Wire the batch.**
  - In `regenerateBatch`, before the `refreshDockEntry` loop, build `pinnedIndices` from `findDockIndex(bundleId:)` for each regenerated config. `refreshDockEntry` only re-seats tiles it found pinned, so this matches it.
  - After the loop, replace `performDockRestart()` and the 1 s sleep with `_ = await helperManager.restartDockAndVerify(HelperBundleManager.batchExpectations(regeneratedConfigs.map { ($0.bundleIdentifier, helperManager.helperPath(for: $0).path, $0.diagnosticName) }, pinnedIndices: pinnedIndices), ownedBundleIds: [])`. A failure is already logged inside.
  - Why: `reapply` rebuilds `isVisibleInDock && helperExists` tiles, including one the user just dragged off. Expecting presence for it would make the retry re-pin it.
- [ ] **Step 6: Add the string.**
  - Add `AppStrings.Error.dockChangeNotKept` in the three-argument shape.
  - Run `python3 -I Scripts/l10n/l10n.py sync-keys`, then `export`.
  - Add the row's machine translation to each of `docs/l10n/{zh-Hans,ja,de,ru,fr}.md`, following `GLOSSARY.md`: zh-Hans "Dock" is 程序坞, and keep French spacing as U+00A0. Then `import <lang>` for each.
  - Run `python3 -I -m unittest discover -s Scripts/l10n -p 'test_*.py'` and `python3 -I Scripts/l10n/l10n.py check`. Expected: both pass.
- [ ] **Step 7:** Delete the three orphaned functions. Grep each name across `DockTile/` and `DockTileTests/`: expect zero hits, and no stale mentions in comments. The `removeFromDock(for:)` comments describing the quit-and-wait retry go too (coding-guardrails: grep the old description).
- [ ] **Step 8:** Run `-only-testing:DockTileTests/DockExpectationTests -only-testing:DockTileTests/DockActionResolutionTests -only-testing:DockTileTests/LocalizationCatalogTests`. Expected: PASS. Then build Debug without the flag. Expected: BUILD SUCCEEDED, with no new warnings in the changed files.
- [ ] **Step 9: Update the rules.**
  - architecture.md:
    - every Dock change goes through `restartDockAndVerify`, which uses the shared predicate and retries once;
    - Tile Detail shows `dockChangeNotKept` in its red error text, while batches, delete and the stuck-tile sweep log;
    - a plist read can't see a plist/Dock split, and the +1 s read can come before the Dock's write-back (accepted, with the reason above);
    - verification ignores the caller's cancellation;
    - a drag-off within about 1 s of a restart can be re-pinned by the retry (accepted, Q8);
    - batch verification sits outside the per-tile locks (Q9), its tiles are held in `verifyingBundleIds` for the watcher (Q12), and its retry skips a tile another operation is building or removing (Q16, Q18, with the residual above);
    - **delete during a batch's check (accepted):** a false STILL log line, nothing else (residual above);
    - **overlapping batches (Q19, accepted):** Popover Apply has no guard against the launch batch. Two batches then restart the Dock in turns, but each retries once at most and the result converges. A tile one batch is rebuilding is refused by the other's build lock; that's harmless, because the first batch relaunches it with the already-saved popover settings. The cost is extra restarts, possibly a false STILL log line, and wasted rebuilds, with no user-visible error.
  - testing.md: add the `unmetExpectations` / `batchExpectations` / `retryableExpectations` line.

  Commit as `fix(dock): verify every Dock change after the restart and retry once; tell the user when it didn't stick`.

---

### Task 4: Self-heal a stale entry; run launch maintenance once per launch

**Files:**
- Modify: `DockTile/Managers/HelperMigrationManager.swift`
  - `classifyHelperHealth` (314-325)
  - `selfHealIfNeeded` (136-164)
  - a new static flag and `beginLaunchMaintenance()` beside `didSelfHeal` (21)
- Modify: `DockTile/App/DockTileApp.swift`, the launch `.task` (57-74): one guard line
- Modify: `DockTile/Managers/HelperBundleManager.swift`:
  - a new `pinnedEntryPaths()` beside `pinnedBundleIds()` (481). `pinnedBundleIds()` keeps its caller at 521.
  - `refreshDockEntry(for:)` (1743): guard on `findDockIndex(bundleId:) != nil` instead of `findInDock(bundleId:) != nil`. `findDockIndex` matches `bundle-identifier` before parsing the URL, while `findInDock` skips an unparseable entry. Without this, the re-seat would no-op for the very entry self-heal flags as stale (Q11).
- Test: `DockTileTests/Unit/Managers/HelperSelfHealTests.swift`

**Interfaces:**
- Consumes: `dockEntryPath(_:)`, `dockEntriesAreCurrent(…)` and `isSameFile(_:_:)` (Task 2).
- Produces:
  - `func pinnedEntryPaths() -> [String: [String?]]`: one synchronized read, mapping each bundle ID to its entries' paths in Dock order.
  - `classifyHelperHealth(isPinnedInDock:bundleExists:iconsComplete:bakedVersionMatchesCurrent:dockEntryIsCurrent:)`, with no default on the new parameter.

- [ ] **Step 1: Write the failing tests.** Change the suite's private `classify` helper to take `entry: Bool = true` and pass it as `dockEntryIsCurrent:`. The default lives in the test helper, so the five existing cases stay unchanged. Add:

```swift
@Test("Pinned + healthy bundle, but the Dock entry is stale → heal (the 2026-10-29 stranded entry)")
func pinnedStaleDockEntry() {
    #expect(classify(pinned: true, exists: true, icons: true, baked: true, entry: false) == .heal)
}
@Test("Unpinned tile with a stale entry is still never a repair target")
func unpinnedStaleDockEntryNeverHeals() {
    #expect(classify(pinned: false, exists: true, icons: true, baked: true, entry: false) == .healthy)
}
```

- [ ] **Step 2:** Run `-only-testing:DockTileTests/HelperSelfHealClassifyTests`. Expected: build failure (extra argument).
- [ ] **Step 3: Implement.**
  - Add the parameter. The rule, after the existing checks, is `if !dockEntryIsCurrent { return .heal }`.
  - In `selfHealIfNeeded`, read `let entries = helperManager.pinnedEntryPaths()` and set `pinned = Set(entries.keys)`, replacing the `pinnedBundleIds()` call.
  - Per config: `dockEntryIsCurrent = bundlePath.map { HelperBundleManager.dockEntriesAreCurrent(entries[config.bundleIdentifier] ?? [], helperPath: $0.path, sameFile: HelperBundleManager.isSameFile) } ?? true`. A missing bundle already heals through `bundleExists`. An unparseable entry is stale (Q11).
  - Add `entry=\(…)` to the existing "needs repair" log line.
  - Change `refreshDockEntry`'s guard, as listed under Files.

  The repair is the existing `regenerateBatch`: `refreshDockEntry` re-seats the entry at `helperPath(for:)`, `addToDock` reconciles it, and Task 3 verifies it. All three use the same predicate, so a repaired entry reads as current on the next launch and nothing loops.

  **Hidden tiles too (accepted):** self-heal walks every pinned config whatever its `isVisibleInDock` (`HelperMigrationManager.swift:148`), so a hidden tile with a stale or unparseable pinned entry is rebuilt and re-seated. The next launch's reconcile then removes it. That's two extra restarts, after which it settles. For an unparseable entry this is also the only path that ever clears it, because Hide's `findInDock` skips such an entry.

  **Considered, not taken:** for a stale entry on an otherwise healthy bundle, a lighter repair would skip the rebuild and just call `refreshDockEntry` plus `restartDockAndVerify`. That saves about 1 s per stranded tile, once. It isn't worth a second repair path for a rare case that heals once.
- [ ] **Step 4 (Q6, widened by Q15):** run the whole launch sequence once per launch, not just migration.
  - Add `private static var didStartLaunchMaintenance = false` to `HelperMigrationManager`, beside `didSelfHeal`, and `static func beginLaunchMaintenance() -> Bool`. It returns `false` when the flag is already set; otherwise it sets the flag and returns `true`.
  - In `DockTileApp`'s `.task` (57-74), right after the `isRunningTests` guard, add `guard HelperMigrationManager.beginLaunchMaintenance() else { return }`. A reopened window then runs none of migrate, scan and self-heal. `didSelfHeal` and `hasScannedForMissingApps` stay as they are.
  - Doc comment reason: the main window's `.task` runs again when the window is reopened during a launch (Dock click, deep link, ⌘,), while the first `.task` is still suspended inside its batch. Its cancellation doesn't stop that batch.
    - With a migration-only guard, the second pass skipped migration and went straight to self-heal. Self-heal saw the tile mid-rebuild as having incomplete icons and the batch's unreached tiles as built by an older version, flagged them all, and started a second batch.
    - Two batches then kill the Dock in alternation.
  - Convergence across launches is unchanged: each launch starts with the flag cleared.
  - **No unit test:** the flag is process-global and the sequence it guards would mutate the live dev config and Dock (testing.md, "Test-host guard"). Task 7 Step 6 checks it by hand.
- [ ] **Step 5:** Re-run Step 2. Expected: PASS (7 classify cases: the 5 existing plus 2 new).
- [ ] **Step 6:** Update architecture.md's "Version-independent self-heal" bullet (a pinned entry that's stale by the shared predicate now heals) and "Convergent, not one-shot" (the launch sequence runs once per launch, with the reason above). Update the testing.md `classifyHelperHealth` line. Commit as `fix(selfheal): repair a pinned Dock entry left at an old helper path; run launch maintenance once per launch`.

---

### Task 5: The Dock-plist watcher skips a tile with a Dock operation in flight

Q7: `installHelper` removes the tile's entry from the plist at its start ([HelperBundleManager.swift:146](../../../DockTile/Managers/HelperBundleManager.swift)) and re-adds it seconds later. The watcher fires 0.5 s after our own removal and marks the tile hidden. On success `performDockAction` writes it visible again. On failure, including Task 3's new error, it would leave "hidden in config but still pinned".

**Files:**
- Modify: `DockTile/Managers/ConfigurationManager.swift`: `resolveDockVisibility` (699-716) and `syncDockVisibility` (619-660)
- Modify: `DockTile/Managers/HelperBundleManager.swift`: a new pure seam and a new instance method that delegates to it
- Test: `DockTileTests/Unit/Managers/DockVisibilityReconcileTests.swift`, plus a new suite `DockOperationInFlightTests` in `DockTileTests/Unit/Managers/DockEntryVerificationTests.swift`

**Interfaces:**
- Consumes: `verifyingBundleIds` (Task 3).
- Produces:
  - `nonisolated static func dockOperationInFlight(bundleId: String, building: Set<String>, removing: Set<String>, verifying: Set<String>) -> Bool`: true when any of the three contains `bundleId`.
  - `func isDockOperationInFlight(bundleId: String) -> Bool`, which passes `buildingBundleIds`, `removingBundleIds` and `verifyingBundleIds` to that seam.
  - `resolveDockVisibility(isVisibleInConfig:isActuallyInDock:helperExists:reconcileDockedHiddenTiles:operationInFlight:)`, with no default. When `operationInFlight` is true it returns `.inSync` before any other rule.

- [ ] **Step 1: Write the failing tests.** In `DockOperationInFlightTests`:

```swift
@Test func verifyingCountsAsInFlight()         // building [], removing [], verifying [t] → true (Q12: a batch tile mid-verify)
@Test func buildingOrRemovingCountsAsInFlight() // building [t] → true; removing [t] → true
@Test func otherTilesDoNotCount()              // all three hold only u → false for t
```

Then give `DockVisibilityReconcileTests`' private `resolve` helper `inFlight: Bool = false` and pass it through. Add:

```swift
@Test("A tile mid-install is not marked hidden by its own plist removal")
func inFlightOverridesMarkHidden() {
    #expect(resolve(visible: true, inDock: false, helperExists: true, reconcile: false, inFlight: true) == .inSync)
}
@Test("A tile mid-operation is never removed by the launch reconcile")
func inFlightOverridesRemoveFromDock() {
    #expect(resolve(visible: false, inDock: true, helperExists: true, reconcile: true, inFlight: true) == .inSync)
}
```

- [ ] **Step 2:** Run `-only-testing:DockTileTests/DockVisibilityReconcileTests -only-testing:DockTileTests/DockOperationInFlightTests`. Expected: build failure.
- [ ] **Step 3: Implement.**
  - Add the seam, the instance method, the parameter and its early return.
  - `syncDockVisibility` passes `HelperBundleManager.shared.isDockOperationInFlight(bundleId: config.bundleIdentifier)`.
  - Log verbose on `sync`: `"<name> Dock operation in flight — not reconciling"`.
  - **What the skip can and can't do:** it only suppresses `markHidden` and the launch reconcile's removal. So the worst case is "visible in config but absent from the Dock", and never "hidden but pinned".
  - That state lasts until the next watcher event or, at the latest, the next launch's sync (`ConfigurationManager.swift:648-650`, direction 1). The Dock's write-back a few seconds after launch (§6) often produces such an event, but nothing guarantees it lands after the sets clear: `installHelper` keeps `buildingBundleIds` through its launch wait of up to 2 s, and the write-back may not change the file.
  - Accepted, and stated in architecture.md as "until the next Dock change or launch". A forced sync after every operation would be more code for a state the next launch fixes.
- [ ] **Step 4:** Re-run Step 2. Expected: PASS, with every existing case unchanged. Then check the build-lock half of Q12, which is structural (no unit test can see a call site): `grep -n "canBeginBundleBuild(" DockTile/Managers/HelperBundleManager.swift` shows the definition and exactly three calls (installHelper, removeFromDock(for:), regenerateHelperBundle), each passing `inFlight: buildingBundleIds`, never `verifyingBundleIds`. So Hide is never refused because a batch is verifying (Q9). Then check the wiring no unit test reaches:
  - `grep -n "verifying: verifyingBundleIds" DockTile/Managers/HelperBundleManager.swift` shows `isDockOperationInFlight` passing the verifying set.
  - `grep -n "incrementingCounts\|decrementingCounts" DockTile/Managers/HelperBundleManager.swift` shows exactly one increment and one decrement in `restartDockAndVerify`, over the same `ids`.
- [ ] **Step 5:** In architecture.md's "Visibility ownership" paragraph, add one sentence: the watcher skips tiles with an operation in flight (building, removing, or being verified after a batch), and why. Update the testing.md `resolveDockVisibility` mention. Commit as `fix(sync): don't reconcile a tile's visibility while its Dock operation is in flight`.

---

### Task 6: Prove SIGKILL relaunch on macOS 15 and macOS 26 runners (Q2) — runs FIRST, on its own branch (Q17)

`workflow_dispatch` needs the ref on GitHub, and pushing a branch doesn't trigger CI on its own (`ci.yml:3-17`). The check needs no app code, so it lives on its own branch, `ci/dock-kill-check`, cut from `main` after Task 0 Step 1. That keeps the fix branch unpushed until its own `--dev` gate, and tests the plan's riskiest assumption before any code depends on it.

**Files:**
- Create: `Scripts/ci/dock-kill-check.swift`
- Modify: `.github/workflows/ci.yml`: a new `workflow_dispatch` input `dock_kill_check` (boolean, default false), and a new job `dock-kill-check`
- Modify: `.claude/rules/ci-release.md`: one paragraph beside "Dock render check"

**What the script does.** It runs only when `GITHUB_ACTIONS` is set, and exits 2 otherwise, like `dock-check.sh`.
1. Print `launchctl print gui/<uid>/com.apple.Dock.agent` (the KeepAlive evidence), with `<uid>` from `getuid()` (it's a Swift script, so no `$(id -u)`), and `sw_vers`.
2. Create a stub bundle in a temp directory with `CFBundleIdentifier` `com.docktile.ci.killcheck`, the same stub shape as `dock-check.sh`.
3. Run six trials inside the race window, the case that broke, in this fixed order: (1) 0.5 s add, (2) 0.5 s remove, (3) 2.5 s add, (4) 2.5 s remove, (5) 10 s add, (6) 10 s remove. Each trial:
   - first restarts the Dock (`killall -KILL Dock`), standing in for the migration's restart, waits for a new PID, then waits the gap;
   - writes through CFPreferences, then `killall -KILL Dock`;
   - requires a Dock with a NEW PID within 5 s, matched as any Dock process whose PID differs from the old one;
   - waits for the same PID for 3 s, then reads `persistent-apps`. The stub's entry, matched by `bundle-identifier` (the Global Constraints assumption), must be present or absent, as written;
   - requires `swift Scripts/ci/dock-measure.swift <png> --count-only` to show the baseline count +1 when present and the baseline when absent. That's the running Dock's own evidence, not the plist's.
   - **Evidence weight:** the plist read can come before the new Dock's write-back (§6), so the capture count is the primary evidence and the plist line supports it. `--count-only` counts every icon before the largest gap, running apps included, so a runner app starting or quitting between trials reads as a FAIL. That's a safe false alarm: re-run before concluding.
4. **Control, reported but not counted:** one extra trial, run LAST after the six counted ones, writes 0.5 s after a restart and uses SIGTERM (`killall Dock`). It prints `control (SIGTERM at 0.5 s): lost` or `kept`. `lost` shows the runner reproduces the race, so the SIGKILL passes prove the fix. `kept` means the runner doesn't reproduce it, so the SIGKILL passes prove only that the Dock relaunches with our write. The script prints that, and the owner weighs it at the merge gate.
5. Print one line per trial, `plist: ok|FAIL` and `capture: ok|FAIL|unavailable`, and a final `dock-kill-check: N/6 OK`.
6. Exit 0 only at 6/6. Exit 1 on any miss, including no new Dock or an unmeasurable capture: a check that can't measure must fail (testing.md, "A guard must be able to fail").
   - The capture is proven on macos-15 only (`dock-check-macos-15`). On macos-26, Screen Recording permission might refuse it. That trial then reads `capture: unavailable` and the job fails, which keeps "couldn't look" distinct from "lost the write".
   - If that happens, the merge gate becomes the owner's call: are the plist and PID lines for that OS enough?

**The job.**
- `if: github.event_name == 'workflow_dispatch' && inputs.dock_kill_check`, with `strategy.matrix.os: [macos-15, macos-26]` and `runs-on: ${{ matrix.os }}`. No `needs`: it uses no build products.
- Steps: checkout (pinned to the same SHA the other jobs use), then `swift Scripts/ci/dock-kill-check.swift`. On `always()`, upload the captures and the log as `dock-kill-check-${{ matrix.os }}` (upload-artifact pinned to the existing SHA).

- [ ] **Step 1:** `git switch main && git switch -c ci/dock-kill-check`. Write the script and the job, and add the ci-release.md paragraph: what the job proves, how to run it, and that it rewrites the runner's Dock. Run `actionlint` if it's available locally, or read the workflow carefully: every `uses:` must be SHA-pinned (ci-release.md). Commit as `ci: on-demand proof that a SIGKILLed Dock relaunches with our write (macOS 15 + 26)`.
- [ ] **Step 2:** Run `stage-gate --dev` (a fresh reviewer) on this branch's diff. Fix anything it finds before pushing.
- [ ] **Step 3: Push.** The owner authorised this push on 2026-10-29 (Q17). Say so in the session right before pushing, so they can stop it. Then `git push -u origin ci/dock-kill-check`.
- [ ] **Step 4: Negative control (the check must be able to fail).** On a throwaway branch `ci/dock-kill-check-negative`, cut from Step 3's commit, add one commit that inverts trial 3's expectation (2.5 s add, expected absent). Pushing it, and later deleting it on origin, are pushes outside Q17's authorisation. So at Step 3, ask the owner once for all of them together: pushing this branch, deleting it on origin, and deleting `ci/dock-kill-check` on origin in Step 6. Push it and run `gh workflow run ci.yml --ref ci/dock-kill-check-negative -f dock_kill_check=true`. Expected on both OSes: trial 3 FAILs on both the plist and the capture count, the summary reads `5/6`, and the job exits 1. If the inverted trial reads OK, the script isn't measuring: fix it on `ci/dock-kill-check` and repeat. Then delete the throwaway branch locally and on origin. A separate branch keeps the inverted commit out of `main` without a force push.
- [ ] **Step 5:** Run `gh workflow run ci.yml --ref ci/dock-kill-check -f dock_kill_check=true`, then `gh run download <run>` for both artifacts. Expected on both OSes: `dock-kill-check: 6/6 OK`, `launchctl` showing KeepAlive, a new Dock PID in every trial, and the control line (ideally `lost`). Read the verdict from the log lines, never from the job colour. **Gate:** if either OS fails, or reads `capture: unavailable`, or the control reads `kept`, stop and bring the evidence back to the owner. Don't start Task 1 without the owner's decision; the whole approach rests on this.
- [ ] **Step 6:** On green, `git switch main && git merge --ff-only ci/dock-kill-check && git push` (Q17), then delete `ci/dock-kill-check` locally and on origin (the origin delete is covered by Step 3's ask). The `dock_kill_check` input then exists on every branch cut from `main`.

---

### Task 7: Full suite and hands-on verification (no code)

- [ ] **Step 1:** Put the Mac on the Default icon style (CLAUDE.md), then run the full `xcodebuild test … -only-testing:DockTileTests CODE_SIGNING_ALLOWED=NO`. Expected: `TEST SUCCEEDED`. Report executed counts per suite for the new and changed ones (testing.md: never grep a whole log): `DockRestartSignalTests`, `DockEntryPathTests`, `DockEntryReconcileTests`, `DockExpectationTests`, `HelperSelfHealClassifyTests`, `DockVisibilityReconcileTests`, `DockOperationInFlightTests`.
- [ ] **Step 2:** Rebuild Debug WITHOUT the flag. `codesign --verify` must pass before launching.
- [ ] **Step 3 (owner's OK, as in Task 0): the repro.** Repeat Task 0 Step 3 three times on the new build. Expected each time:
  - the entry's path is the NEW folder;
  - the Dock shows the tile;
  - the dev `diagnostics.log` has no `STILL not at its expected Dock path` line;
  - exactly one `Dock restarted (pid A → B)` line per Update, or two with a `retrying` line between them.
  - **Stop condition (the PID-detection assumption, Task 3 Step 3):** if any Update logs `no new Dock within 5 s` while the Dock visibly restarted, stop. `NSRunningApplication` isn't updating during the wait. Bring that back to the owner; don't ship a 6 s wait per restart.
- [ ] **Step 4 (owner's OK): self-heal of 2.6.1 damage.**
  1. Quit the dev app.
  2. Compile and run this one-off scratch script (outside the repo), with the tile's bundle ID and its support folder:

     ```swift
     // seed-stale.swift — usage: seed-stale <bundleId> <supportDir>
     import Foundation
     let d = "com.apple.dock" as CFString, k = "persistent-apps" as CFString
     let (id, dir) = (CommandLine.arguments[1], CommandLine.arguments[2])
     CFPreferencesAppSynchronize(d)
     var apps = CFPreferencesCopyAppValue(k, d) as! [[String: Any]]
     let i = apps.firstIndex { ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String == id }!
     var td = apps[i]["tile-data"] as! [String: Any], fd = td["file-data"] as! [String: Any]
     fd["_CFURLString"] = URL(fileURLWithPath: "\(dir)/Gone.app", isDirectory: true).absoluteString
     td["file-data"] = fd; apps[i]["tile-data"] = td
     CFPreferencesSetAppValue(k, apps as CFArray, d); CFPreferencesAppSynchronize(d)
     ```

     then run `killall -KILL Dock`.
  3. Relaunch the dev app.

  Expected: a `selfheal` "needs repair (… entry=false)" line, then the entry at the real path, and on a second relaunch no repair line. The other possible outcome: the relaunched Dock drops the seeded `Gone.app` entry itself. The tile then isn't pinned, so there's no repair line, and the plist shows no entry for it. If so, record it, re-seed with the dev app running (so the Dock is restarted only by `killall -KILL Dock`), and note which outcome happened in the PR.
- [ ] **Step 5 (owner, by eye): what SIGKILL keeps and loses.**
  - With a second desktop holding a window, press Update on a tile. Expected: both desktops and the window's placement survive.
  - Then, three times: drag a non-tile Dock icon to a new position, and within 1–2 s press Update. Record whether the drag survived each time. It's accepted if it didn't (Q1); note the count in the PR.
  - Hide, show and delete a scratch dev tile. Each should log exactly one restart and no `STILL` line.
- [ ] **Step 6 (owner): watcher and once-per-launch checks.**
  - Q7: press Update on a pinned tile and watch the log during the build. Expected: an `in flight — not reconciling` line, and no `gone from Dock → marking hidden` for that tile.
  - Review Focus 5 has no hands-on check. By hand, the watcher's 0.5 s debounce marks a dragged-off tile hidden before Apply starts, and `reapply`'s filter (`HelperMigrationManager.swift:189-191`) then excludes it, so `batchExpectations` is never exercised. The seam test `unpinnedConfigGetsNoExpectation` is the only guard.
  - Q6: turn **Dock Lock on** in the dev app first. Without it, closing the main window quits the app ([AppDelegate.swift:359-365](../../../DockTile/App/AppDelegate.swift)), and no second `.task` can run. Dock Lock needs Accessibility for the dev build (docs/dock-lock-accessibility.md). Then, without bumping anything, quit the dev app with a dev tile left unstamped (set its `helperAppVersion` to `"0"` in the dev config while the app is quit). Launch, close the main window as soon as migration starts, and reopen it from the Dock. Expected: one batch **in total** (no migration batch followed by a self-heal batch) and one restart for it in the log, with no second `▶` migration or self-heal line (Q15). Turn Dock Lock back off afterwards.
  - Q12 and Q16 have no hands-on check. Each needs an event inside the ~1 s verification window (the new Dock dropping an entry, or a Hide landing there), which can't be produced by hand. They rest on `verifyingCountsAsInFlight`, Task 5 Step 4's grep and the `retry…` seam tests. An `in flight — not reconciling` line during a batch's verification shows the set is populated, if a plist event happens to land there; its absence proves nothing.
- [ ] **Step 7:** Run `stage-gate --dev` (a fresh reviewer) on the branch diff. Only after it passes, and with the owner's OK for this push (Q17 authorised only `ci/dock-kill-check`), push `fix/dock-write-race`. Then use ONE dispatch, `gh workflow run ci.yml --ref fix/dock-write-race -f dock_kill_check=true`, which re-runs the kill check beside build-and-test and the macOS 15 leg. Don't start a second run on the same ref while it's going: `ci.yml` cancels in-progress runs per ref (`ci.yml:24-26`). All jobs must be green, with the kill-check verdict read from its log lines, before merging. Merging to `main` (fast-forward plus push) is a separate owner OK; ask for it with the evidence in hand, not in advance.
