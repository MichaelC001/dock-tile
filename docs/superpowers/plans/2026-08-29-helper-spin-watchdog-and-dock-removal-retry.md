# Helper Spin Watchdog + Dock Removal Retry — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the next "helper tile pegs a CPU core" incident self-diagnosing (a stack sample lands in Copy Diagnostics), and stop a hide/remove issued seconds after an add from silently failing ("STILL in Dock after restart").

**Architecture:** (1) A helper-only `SpinWatchdog` on a background `DispatchSourceTimer` compares process CPU time to wall time every 30 s; after 90 s at ≥50 % of a core it runs `/usr/bin/sample` on itself into `<support>/spins/` and logs it; `DiagnosticsLog.report()` surfaces the hottest frames. Decisions live in a pure `SpinWatchdogPolicy` seam (regression-guard convention). (2) `HelperBundleManager.removeFromDock(for:)` re-verifies after the Dock restart and retries the plist removal + restart once (bounded), mirroring the existing add-side "sometimes the first write doesn't take" retry.

**Tech Stack:** Swift 6 strict concurrency, AppKit, Foundation `Process`, `clock_gettime_nsec_np`, Swift Testing.

**Spec:** the *Findings* section of this document (there is no separate design doc — this plan is the write-up of the 2026-08-29 investigation).

## Global Constraints

- macOS 15.0+, Swift 6 strict concurrency (no data races: watchdog state confined to its own queue).
- New **app-target** files do NOT auto-join the Xcode target — append to existing files (`DiagnosticsLog.swift`, `HelperAppDelegate.swift`, `HelperBundleManager.swift`). New files under `DockTileTests/` auto-join.
- Tests: Swift Testing (`@Test`, `#expect`, `#require`), module `Dock_Tile`, never write `UserDefaults.standard`, assert exact values.
- Diagnostics conventions: state changes/errors → non-verbose `log`; `Managers/DiagnosticsLog.swift` is where cross-process diagnostics live.
- Helpers never trim/prune shared files (multi-writer rule) — only the main app's `prepareOnLaunch()` prunes.
- Verification command (CLAUDE.md): `xcodebuild test -project DockTile.xcodeproj -scheme DockTile -configuration Debug -destination 'platform=macOS' -only-testing:DockTileTests CODE_SIGNING_ALLOWED=NO`

---

## Findings (spec) — investigation of the July 2026 "AI Tile 82.9 % CPU" report

### Evidence in hand
- Activity Monitor: helper **AI Tile** (PID 1762, a login-spawned PID) at **82.9 % CPU, 16 h 45 m CPU time, 8 threads, 2 idle wake-ups**. The other three helpers (Dev, Utils, Media) were not hot.
- Copy Diagnostics (v1.8.5 RELEASE, 2026-07-25 10:02): Dev helper popover + gear (10:02:29) → main app launch → **Update 'AI Tile'** (10:02:35) → hide → `'AI Tile' STILL in Dock after restart — removal did not take` (10:02:42) → hide again → `Removed … (verified)` (10:02:44) → Add ×2.
- Ordering: `Update` force-kills and relaunches the helper, so **PID 1762 was already dead when the log starts** — the log records the recovery attempts, not the spin. The spinning helper wrote no lines in the retained hour.
- This Mac is the new M3 (migrated Aug 2026): **no macOS spin / `cpu_resource` report survived**, Crashlytics does not capture hangs, and the 1-hour diagnostics retention had already trimmed the incident. Today's four v1.8.6 helpers are at 0.0 % CPU (~10 s CPU over 22 h each).

### What the evidence rules out / in (CPU spin)
- **2 idle wake-ups at 82.9 %** = one thread continuously runnable, never sleeping. A timer-driven fault (the helper's 1 s `HelperAppDelegate` poll + 2 s `IconStyleManager` poll) would show ~1–3 wake-ups/s and cannot produce this signature.
- Grep of the helper code path: no `while`/`repeat` loops, no `DispatchSource` (the `DockPlistWatcher` is main-app-only via the `AppEnvironment.isHelper` guard in `ConfigurationManager.init`), no self-rescheduling `DispatchQueue.main.async`. Popover layout uses fixed `.frame(width:height:)` so the `NSHostingController.sizingOptions = [.preferredContentSize]` feedback path has a stable ideal size. **No DockTile-authored busy loop was found.**
- What is unique to AI Tile: 9 apps including a Chrome web-app shim and two items named "Claude"; 7.8 MB of the config's 11.8 MB `iconData` (FreeFlow's raw `.icns` alone is 2.6 MB). Correlation only — `iconData` is never rendered any more (missing apps show a placeholder before the fallback is reached) and the full decode costs 35 ms.
- Remaining candidates are framework-level (AppKit/SwiftUI/Firebase) and data- or state-dependent, e.g. an `NSPopover` re-position/layout loop with a popover left open across a display reconfiguration (each helper here logs ~129 `NSApplication._react(to:) dock` screen reactions/day), or a popover auto-shown at login by a duplicate launch (`LoginTileSpawner` + loginwindow Resume both opening the same helper → `applicationShouldHandleReopen` → `showPopover`). **Not provable from surviving artifacts** → the fix is to make the next occurrence capture its own stack (Task 1).

### "Persisting removal" — explained (high confidence)
- `addToDock` writes a minimal `persistent-apps` entry (`GUID`, `bundle-identifier`, `dock-extra`, `file-data`, `file-label`, `file-type`). The live Dock plist on this Mac shows the entry **rewritten by the Dock** with `book`, `file-mod-date`, `parent-mod-date`, `is-beta` — keys DockTile never writes. The relaunched Dock normalises entries and writes its prefs back (and flushes again on `SIGTERM`).
- `removeFromDock(for:)` = `removeFromDockPlist` (cfprefsd now lacks the entry) → `killall Dock` (SIGTERM) → the still-dirty Dock flushes its in-memory list **with** the entry → `waitForTileRemoval` polls 3 s → "STILL in Dock". The second hide (Dock already flushed) succeeds. Exactly the July sequence (add at :35.9, hide at ~:38).
- The add side already retries ("Try adding again - sometimes the first write doesn't take"); the remove side does not (Task 2).

### Measured and deliberately NOT changed (performance ledger)
| Idea | Measurement | Verdict |
|---|---|---|
| Shrink/drop 12 MB `iconData` (decoded 2× per helper launch, 1× spawner, 1× main app) | `JSONDecoder` full model **35 ms**, lite 6 ms; helper RSS 27 MB | Not a CPU/memory problem. Skip. |
| Consolidate the two icon-style pollers (1 s + 2 s, each spawning `lsregister -f -R` on change) | ~10 s CPU per helper per 22 h | Negligible. Skip. |
| `readShowInAppSwitcherFromDisk` hard-codes the **prod** filename (`com.docktile.configs.json`) even in dev | correctness nit, dev-only | Out of scope; note for a separate fix. |
| Dev main app "Hang Risk: UI QoS thread waiting on `dispatch_semaphore_wait`" 1–4 s after launch | Xcode runtime-issue only, also fires under the test host (Firebase/Sparkle start-up) | Not the reported issue. Skip. |

### Reproduction results (measured 2026-08-29, after the plan was written)

Probes written against the real Dock plist through the same CFPreferences API `HelperBundleManager`
uses (a throwaway `com.apple.Chess` entry; the Dock plist was snapshotted first and restored
exactly afterwards):

| Experiment | Result |
|---|---|
| Add → restart → wait 0.5–5 s → remove → restart → poll 3 s | removal verified **12/12** — a settled Dock removes cleanly |
| Add → restart, at gaps 0.5–3 s | **5/8** trials found our just-added entry already gone: the dying Dock flushed its stale list over our write |
| Repeated add/remove cycles with restarts ~1.5 s apart | **7 entries accumulated** — those removals silently did not take (the July symptom) |
| Quit Dock → wait for process exit → write | converged **every** time, incl. clearing all 7 stranded entries in one pass |

So assumption 2 holds at the mechanism level — `killall Dock` lets a Dock holding the previous
`persistent-apps` write it back over a concurrent external edit — but the failure needs concurrent
restarts, not merely a recent one, and it is direction-agnostic (it clobbered adds here, removals in
July). Two consequences for Task 2: the plain path stays the **first** attempt (12/12 on a settled
Dock — no reason to slow the common case), and the **retry** uses the quit-and-wait ordering rather
than simply repeating the write that just lost the race.

Worth noting for the spin: a helper burning a core makes exactly this class of race wider, which is
consistent with the July log showing both symptoms in the same minute.

### Assumptions this plan rests on
1. `/usr/bin/sample <own pid>` succeeds from inside a helper. **Verified this session**: `sample` on the running ad-hoc-signed helper (pid 91845) succeeded when launched via `launchctl submit` (no Terminal/Developer-Tools TCC involvement). Helpers are ad-hoc signed without the hardened-runtime flag; the main app is hardened (watchdog is helpers-only, so this does not matter).
2. The Dock's post-relaunch write-back is the mechanism behind "STILL in Dock". Evidence is the normalised plist keys + the timing; a deterministic repro is the runnable check in Task 2 (add, then hide within ~3 s).
3. 50 % of a core for 3 consecutive 30 s windows is a sane trigger: the incident ran at 83 % for hours; a real popover open + icon fetch burst lasts < 1 s. False positives cost one `sample` run (~3 s, one file) per process lifetime.
4. `clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)` sums CPU time across all threads, which is what Activity Monitor's % CPU reports.

### Interpretations of the request
- "Check the build, prod app on this machine and activity-monitor app" → read as: audit the source for the helper's runtime path, inspect `/Applications/Dock Tile.app` + helper bundles + logs on this Mac, and inspect live processes (`ps`, `sample`). Done; nothing is currently hot.
- "memory leak or issue" → checked (RSS 27 MB/helper, config decode 35 ms); the signature is a CPU spin, not a leak.
- "persisting removal or addition to the dock" → read as the `STILL in Dock` line (removal not taking on the first try). The two "Added tile" lines 5 s apart are two user clicks (Add, then Update) — not a bug.

### Simpler alternatives considered
- *Do nothing for the spin until it recurs*: rejected — there is no way to get a stack from 100+ Sparkle users' Macs (no hang reporting, 1 h log retention). The watchdog is the minimum that turns the next report into a root cause.
- *Report to Crashlytics only, no `sample`*: rejected — a non-fatal has no stack of the hot thread; the `sample` file is the evidence.
- *Make removal wait for the Dock's normalisation write instead of retrying*: rejected — depends on undocumented Dock keys and doesn't cover other writers (user drags a tile). A bounded retry matches the add-side pattern already in the file.

---

## File Structure

- Modify `DockTile/Managers/DiagnosticsLog.swift` — append `SpinWatchdogPolicy` (pure seam), `SpinWatchdog` (runtime), `DiagnosticsLog.spinsDirectory`, `spinExcerpt(from:)` (pure), the "Spin captures" section in `report()`, and pruning in `prepareOnLaunch()`.
- Modify `DockTile/App/HelperAppDelegate.swift:113-163` — start the watchdog in `applicationDidFinishLaunching`.
- Modify `DockTile/Managers/HelperBundleManager.swift:495-514` — bounded retry in `removeFromDock(for:)`.
- Create `DockTileTests/Unit/Managers/SpinWatchdogTests.swift` — policy + excerpt tests.
- Modify `.claude/rules/diagnostics.md` — document the watchdog (one short section).

---

### Task 1: Helper spin watchdog (pure policy + self-`sample` + Copy Diagnostics surfacing)

**Files:**
- Modify: `DockTile/Managers/DiagnosticsLog.swift` (append after the `DiagnosticsLog` class; also edit `prepareOnLaunch()` at ~196-207 and `report()` at ~226-242)
- Modify: `DockTile/App/HelperAppDelegate.swift:113-127`
- Test: `DockTileTests/Unit/Managers/SpinWatchdogTests.swift` (new — auto-joins the test target)
- Modify: `.claude/rules/diagnostics.md`

**Interfaces:**
- Consumes: `DiagnosticsLog.shared.log(_:_:verbose:)`, `AppEnvironment.supportURL`, `AnalyticsService.shared.record(_:context:keys:)` (`@MainActor`).
- Produces: `enum SpinWatchdogPolicy { static let hotUtilization: Double; static let hotWindowsRequired: Int; static let interval: TimeInterval; nonisolated static func utilization(cpuDeltaNs: UInt64, wallDeltaNs: UInt64) -> Double; nonisolated static func step(utilization: Double, consecutiveHot: Int, hasCaptured: Bool) -> (consecutiveHot: Int, capture: Bool) }`, `final class SpinWatchdog { static let shared; func start() }`, `DiagnosticsLog.spinsDirectory: URL`, `nonisolated static func DiagnosticsLog.spinExcerpt(from: String) -> String`.

- [ ] **Step 1: Write the failing tests**

Create `DockTileTests/Unit/Managers/SpinWatchdogTests.swift`:

```swift
import Testing
@testable import Dock_Tile

@Suite("SpinWatchdogPolicy — pure trigger seam")
struct SpinWatchdogPolicyTests {

    @Test func utilizationIsCPUTimeOverWallTime() {
        #expect(SpinWatchdogPolicy.utilization(cpuDeltaNs: 15_000_000_000, wallDeltaNs: 30_000_000_000) == 0.5)
        #expect(SpinWatchdogPolicy.utilization(cpuDeltaNs: 7_500_000_000, wallDeltaNs: 30_000_000_000) == 0.25)
        #expect(SpinWatchdogPolicy.utilization(cpuDeltaNs: 1, wallDeltaNs: 0) == 0)
    }

    @Test func capturesOnlyAfterThreeConsecutiveHotWindows() {
        let first = SpinWatchdogPolicy.step(utilization: 0.83, consecutiveHot: 0, hasCaptured: false)
        #expect(first.consecutiveHot == 1)
        #expect(first.capture == false)

        let second = SpinWatchdogPolicy.step(utilization: 0.83, consecutiveHot: first.consecutiveHot, hasCaptured: false)
        #expect(second.consecutiveHot == 2)
        #expect(second.capture == false)

        let third = SpinWatchdogPolicy.step(utilization: 0.83, consecutiveHot: second.consecutiveHot, hasCaptured: false)
        #expect(third.consecutiveHot == 3)
        #expect(third.capture == true)
    }

    @Test func aCoolWindowResetsTheStreak() {
        let s = SpinWatchdogPolicy.step(utilization: 0.10, consecutiveHot: 2, hasCaptured: false)
        #expect(s.consecutiveHot == 0)
        #expect(s.capture == false)
    }

    @Test func exactlyAtThresholdCountsAsHot() {
        let s = SpinWatchdogPolicy.step(utilization: SpinWatchdogPolicy.hotUtilization, consecutiveHot: 2, hasCaptured: false)
        #expect(s.consecutiveHot == 3)
        #expect(s.capture == true)
    }

    @Test func capturesAtMostOncePerProcess() {
        let s = SpinWatchdogPolicy.step(utilization: 0.95, consecutiveHot: 5, hasCaptured: true)
        #expect(s.consecutiveHot == 6)
        #expect(s.capture == false)
    }

    @Test func shippedThresholdsMatchTheIncidentShape() {
        // 83 % for hours must trigger; the trigger must take ≥ 60 s so a popover-open burst can't.
        #expect(SpinWatchdogPolicy.hotUtilization == 0.5)
        #expect(SpinWatchdogPolicy.hotWindowsRequired == 3)
        #expect(SpinWatchdogPolicy.interval == 30)
    }
}

@Suite("DiagnosticsLog.spinExcerpt — hottest-frames block of a `sample` report")
struct SpinExcerptTests {

    @Test func extractsTheTopOfStackBlockWithoutBinaryImages() {
        let sample = """
        Call graph:
            1723 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
        Total number in stack (recursive counted multiple, when >=5):

        Sort by top of stack, same collapsed (when >= 5):
                mach_msg2_trap  (in libsystem_kernel.dylib)        1723
                -[NSView layout]  (in AppKit)        900

        Binary Images:
               0x104a38000 -        0x105ffffff  com.docktile.app (1.8.6)
        """
        let excerpt = DiagnosticsLog.spinExcerpt(from: sample)
        #expect(excerpt == """
        Sort by top of stack, same collapsed (when >= 5):
                mach_msg2_trap  (in libsystem_kernel.dylib)        1723
                -[NSView layout]  (in AppKit)        900
        """)
    }

    @Test func returnsEmptyWhenTheMarkerIsAbsent() {
        #expect(DiagnosticsLog.spinExcerpt(from: "Process: Dock Tile\nnothing sampled") == "")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project DockTile.xcodeproj -scheme DockTile -configuration Debug -destination 'platform=macOS' -only-testing:DockTileTests/SpinWatchdogPolicyTests -only-testing:DockTileTests/SpinExcerptTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: build FAILS with `cannot find 'SpinWatchdogPolicy' in scope` / `type 'DiagnosticsLog' has no member 'spinExcerpt'`.

- [ ] **Step 3: Add the pure seam + watchdog to `DiagnosticsLog.swift`**

Append at the end of `DockTile/Managers/DiagnosticsLog.swift`:

```swift
// MARK: - Spin watchdog (helpers)

/// Pure decision seam for the helper CPU watchdog (regression-guard convention — mirrors
/// `shouldRecord`). Plain values in, decision out; no clocks, no files.
enum SpinWatchdogPolicy {
    /// Fraction of one core the process must sustain for a window to count as "hot".
    static let hotUtilization: Double = 0.5
    /// Consecutive hot windows before a capture fires (3 × 30 s = 90 s — a popover-open burst
    /// lasts well under a second; the July 2026 incident ran at 83 % for 16 h).
    static let hotWindowsRequired = 3
    /// Window length in seconds.
    static let interval: TimeInterval = 30

    /// CPU-seconds consumed per wall-second — 1.0 = one core fully busy.
    nonisolated static func utilization(cpuDeltaNs: UInt64, wallDeltaNs: UInt64) -> Double {
        guard wallDeltaNs > 0 else { return 0 }
        return Double(cpuDeltaNs) / Double(wallDeltaNs)
    }

    /// Advance the hot-window streak and decide whether to capture now. A capture fires once per
    /// process lifetime (`hasCaptured`) — one `sample` file is the evidence; more is noise.
    nonisolated static func step(utilization: Double, consecutiveHot: Int, hasCaptured: Bool)
        -> (consecutiveHot: Int, capture: Bool) {
        let hot = utilization >= hotUtilization
        let streak = hot ? consecutiveHot + 1 : 0
        return (streak, hot && !hasCaptured && streak >= hotWindowsRequired)
    }
}

/// Reported to Crashlytics (non-fatal) when the watchdog fires, so prevalence across users is
/// visible even when nobody sends a diagnostics report.
enum SpinWatchdogError: Error {
    case sustainedCPU
}

/// Helper-only CPU watchdog. Ticks on its OWN background queue (a `DispatchSourceTimer`, not a
/// run-loop `Timer`), so it keeps ticking while the main thread is hung or spinning. When the
/// process sustains `SpinWatchdogPolicy.hotUtilization` of a core for `hotWindowsRequired`
/// windows it runs `/usr/bin/sample` on itself into `DiagnosticsLog.spinsDirectory` and logs it —
/// the stack the July 2026 "AI Tile at 82.9 % CPU for 16 h" report never had.
/// `sample` on an own-user, ad-hoc-signed helper needs no root and no TCC grant (verified from a
/// launchd-spawned context on 2026-08-29).
final class SpinWatchdog: @unchecked Sendable {
    static let shared = SpinWatchdog()

    private let queue = DispatchQueue(label: "com.docktile.spin-watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastCPU: UInt64 = 0
    private var lastWall: UInt64 = 0
    private var consecutiveHot = 0
    private var hasCaptured = false
    /// Set by a block dispatched to the main queue each tick; still false next tick ⇒ main hung.
    private var mainThreadPong = true
    private var sampler: Process?

    private init() {}

    /// Begin watching. Idempotent. All state is confined to `queue`.
    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            lastCPU = Self.processCPUNs()
            lastWall = DispatchTime.now().uptimeNanoseconds
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + SpinWatchdogPolicy.interval, repeating: SpinWatchdogPolicy.interval)
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source
            source.resume()
        }
    }

    /// Total CPU time (all threads) this process has consumed — what Activity Monitor's % CPU is
    /// derived from.
    private static func processCPUNs() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
    }

    private func tick() {
        let cpu = Self.processCPUNs()
        let wall = DispatchTime.now().uptimeNanoseconds
        let utilization = SpinWatchdogPolicy.utilization(cpuDeltaNs: cpu &- lastCPU, wallDeltaNs: wall &- lastWall)
        lastCPU = cpu
        lastWall = wall

        let mainResponsive = mainThreadPong
        mainThreadPong = false
        DispatchQueue.main.async { [weak self] in
            self?.queue.async { self?.mainThreadPong = true }
        }

        let decision = SpinWatchdogPolicy.step(utilization: utilization,
                                               consecutiveHot: consecutiveHot,
                                               hasCaptured: hasCaptured)
        consecutiveHot = decision.consecutiveHot
        guard decision.capture else { return }
        hasCaptured = true

        let hotSeconds = Int(Double(consecutiveHot) * SpinWatchdogPolicy.interval)
        let percent = Int((utilization * 100).rounded())
        DiagnosticsLog.shared.log("watchdog",
            "Sustained CPU \(percent)% of a core for \(hotSeconds)s (main thread \(mainResponsive ? "responsive" : "NOT responding")) — capturing sample")
        Task { @MainActor in
            AnalyticsService.shared.record(SpinWatchdogError.sustainedCPU, context: "spin_watchdog",
                                           keys: ["cpu_percent": String(percent),
                                                  "main_thread_responsive": String(mainResponsive)])
        }
        captureSample()
    }

    private func captureSample() {
        let dir = DiagnosticsLog.spinsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let file = dir.appendingPathComponent("\(stamp)-\(Bundle.main.bundleIdentifier ?? "helper").txt")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), "3", "-file", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            DiagnosticsLog.shared.log("watchdog", finished.terminationStatus == 0
                ? "Spin sample written: \(file.lastPathComponent) (File → Copy Diagnostics includes it)"
                : "sample exited \(finished.terminationStatus) — no spin capture")
            self?.queue.async { self?.sampler = nil }
        }
        sampler = process
        do {
            try process.run()
        } catch {
            DiagnosticsLog.shared.log("watchdog", "Could not launch sample: \(error.localizedDescription)")
            sampler = nil
        }
    }
}
```

Then, inside the `DiagnosticsLog` class, add the directory constant and the pure excerpt seam (place them right after `private let fileURL = …` at ~line 60):

```swift
    /// Where helper spin watchdogs drop `/usr/bin/sample` captures (one per process lifetime).
    static let spinsDirectory = AppEnvironment.supportURL.appendingPathComponent("spins")

    /// Pure: the `Sort by top of stack` block of a `sample` report — the frames the process spent
    /// the most time in — without the long `Binary Images` tail. Empty when the marker is absent.
    nonisolated static func spinExcerpt(from sampleText: String) -> String {
        let lines = sampleText.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("Sort by top of stack") }) else { return "" }
        let end = lines[start...].firstIndex(where: { $0.hasPrefix("Binary Images") }) ?? lines.endIndex
        return lines[start..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Newest-first spin capture files (empty when none).
    private func spinCaptureFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: Self.spinsDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }   // names start with an ISO stamp
    }
```

- [ ] **Step 4: Surface captures in the report and prune them on launch**

In `report()` (`DiagnosticsLog.swift` ~226-242) replace the final two lines

```swift
        out.append(events.isEmpty ? "(no diagnostic events recorded in the last hour)" : events.joined(separator: "\n"))
        return out.joined(separator: "\n")
```

with

```swift
        out.append(events.isEmpty ? "(no diagnostic events recorded in the last hour)" : events.joined(separator: "\n"))

        // Spin captures are the one piece of evidence a runaway helper leaves behind; list them and
        // inline the hottest frames of the newest so the pasted report alone can name the loop.
        let spins = spinCaptureFiles()
        if !spins.isEmpty {
            out.append("")
            out.append("Spin captures (\(spins.count), newest first — full files in \(Self.spinsDirectory.path)):")
            for file in spins.prefix(5) { out.append("  \(file.lastPathComponent)") }
            if let newest = spins.first, let text = try? String(contentsOf: newest, encoding: .utf8) {
                out.append("")
                out.append("Hottest frames in \(newest.lastPathComponent):")
                out.append(Self.spinExcerpt(from: text))
            }
        }
        return out.joined(separator: "\n")
```

In `prepareOnLaunch()` (~196-207), after the existing `try? rebuilt.write(to: fileURL, atomically: true, encoding: .utf8)` add:

```swift
        // Keep only the 5 newest spin captures. Main app only — helpers never prune shared files.
        for stale in spinCaptureFiles().dropFirst(5) {
            try? FileManager.default.removeItem(at: stale)
        }
```

- [ ] **Step 5: Start the watchdog in the helper**

In `DockTile/App/HelperAppDelegate.swift`, inside `applicationDidFinishLaunching` directly after the `if let config = getCurrentConfiguration() { … } else { … }` block (i.e. after the `setLabel` call, before `setupIconStyleObservation()`), add:

```swift
        // Runaway-CPU evidence: the July 2026 "AI Tile at 82.9 % for 16 h" report left no stack
        // (no hang reporting, 1 h log retention). If this process pegs a core, sample itself.
        SpinWatchdog.shared.start()
```

- [ ] **Step 6: Build and run the new tests to verify they pass**

Run: `xcodebuild test -project DockTile.xcodeproj -scheme DockTile -configuration Debug -destination 'platform=macOS' -only-testing:DockTileTests/SpinWatchdogPolicyTests -only-testing:DockTileTests/SpinExcerptTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test (Suite|Case).*(passed|failed)|error:" | tail -20`
Expected: all 8 tests `passed`, no `error:` lines (Swift 6 strict-concurrency clean).

- [ ] **Step 7: Verify the report surfacing end-to-end without a real spin**

Run:
```bash
xcodebuild -project DockTile.xcodeproj -scheme DockTile -configuration Debug build 2>&1 | tail -2
open ~/Library/Developer/Xcode/DerivedData/DockTile-*/Build/Products/Debug/Dock\ Tile\ Dev.app
mkdir -p ~/Library/Application\ Support/DockTile-Dev/spins
sample "Dock Tile Dev" 1 -file ~/Library/Application\ Support/DockTile-Dev/spins/2026-08-29T00-00-00Z-com.docktile.dev.test.txt
```
Then, in the dev app, File → Copy Diagnostics and `pbpaste | grep -A6 "Spin captures"`.
Expected: a `Spin captures (1, newest first …)` line, the file name, and a `Hottest frames in …` block starting with `Sort by top of stack`. Then delete the fake capture: `rm ~/Library/Application\ Support/DockTile-Dev/spins/2026-08-29T00-00-00Z-com.docktile.dev.test.txt`.

- [ ] **Step 8: Document the watchdog**

Append to `.claude/rules/diagnostics.md`:

```markdown
## Spin watchdog (helpers)

`SpinWatchdog.shared.start()` runs in every helper (`HelperAppDelegate.applicationDidFinishLaunching`)
on its own `DispatchSourceTimer` queue so it survives a hung main thread. Every 30 s it compares
process CPU time (`clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)`) to wall time; ≥50 % of a core
for 3 consecutive windows (pure seam `SpinWatchdogPolicy.step`, `SpinWatchdogTests`) runs
`/usr/bin/sample <pid> 3` into `<support>/spins/<ISO stamp>-<bundle id>.txt` — once per process —
logs `[watchdog]` non-verbose, and records a Crashlytics non-fatal (`spin_watchdog`). `report()`
lists captures and inlines the newest file's `Sort by top of stack` block (`spinExcerpt`, pure);
`prepareOnLaunch()` keeps the 5 newest (main app prunes, helpers never do). Motivation: the
July 2026 "AI Tile at 82.9 % CPU for 16 h" report had no stack — no hang reporting exists for
helpers and the 1 h log window had already trimmed the incident.
```

- [ ] **Step 9: Run the full unit suite**

Run: `xcodebuild test -project DockTile.xcodeproj -scheme DockTile -configuration Debug -destination 'platform=macOS' -only-testing:DockTileTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Suite 'DockTileTests'|Executed|error:" | tail -5`
Expected: `Executed N tests, with 0 failures`.

- [ ] **Step 10: Commit**

```bash
git add DockTile/Managers/DiagnosticsLog.swift DockTile/App/HelperAppDelegate.swift DockTileTests/Unit/Managers/SpinWatchdogTests.swift .claude/rules/diagnostics.md
git commit -m "feat(diagnostics): helper spin watchdog samples itself when a core stays pegged

A helper that sustains ≥50% of a core for 90s now runs /usr/bin/sample on
itself into <support>/spins/ and Copy Diagnostics inlines the hottest frames.
The July 2026 'AI Tile at 82.9% CPU for 16h' report left no stack to act on.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Retry a Dock removal the Dock's write-back undid

**Files:**
- Modify: `DockTile/Managers/HelperBundleManager.swift:495-514` (inside `removeFromDock(for:)`)

**Interfaces:**
- Consumes: existing private `restartDock()`, `waitForTileRemoval(bundleId:)`, `findInDock(bundleId:)`, `removeFromDockPlist(bundleId:)`.
- Produces: no new API; new log lines `reappeared in Dock after restart — retrying removal once` and `Removed '<name>' from Dock (verified on retry)`.

- [ ] **Step 1: Reproduce the race before changing code (runnable, restarts the Dock twice)**

With the Debug build running: create a tile with one app → **Add to Dock** → as soon as the button returns, flip **Show Tile** off and press **Done** (within ~3 s). Then File → Copy Diagnostics, `pbpaste | grep -E "STILL in Dock|verified"`.
Expected (bug present): `'<tile>' STILL in Dock after restart — removal did not take`. If three attempts never reproduce it, stop and report — assumption 2 of the Findings would be wrong and this task is not justified.

- [ ] **Step 2: Replace the single verification with a bounded retry**

In `removeFromDock(for:)` replace

```swift
        if didRemoveFromPlist {
            // Restart Dock to apply changes
            restartDock()

            // Wait for Dock to fully restart and plist to update
            try await waitForTileRemoval(bundleId: config.bundleIdentifier)

            // Final verification (should always succeed now)
            if findInDock(bundleId: config.bundleIdentifier) == nil {
                print("   ✓ Verified tile removed from Dock")
                DiagnosticsLog.shared.log("dock", "Removed '\(config.name)' from Dock (verified)")
            } else {
                print("   ⚠️ Tile still in Dock after restart - this shouldn't happen")
                DiagnosticsLog.shared.log("dock", "'\(config.name)' STILL in Dock after restart — removal did not take")
            }
        } else {
```

with

```swift
        if didRemoveFromPlist {
            // The Dock normalises a freshly-added entry (adds `book`, `file-mod-date`, …) and
            // writes its plist back after relaunching — and flushes again on SIGTERM. A removal
            // issued within seconds of an add is therefore overwritten by that write-back when we
            // `killall Dock`, and the entry reappears ("STILL in Dock", July 2026 log). Retry once:
            // by the second pass the relaunched Dock has already flushed.
            for attempt in 1...2 {
                restartDock()
                try await waitForTileRemoval(bundleId: config.bundleIdentifier)

                if findInDock(bundleId: config.bundleIdentifier) == nil {
                    print("   ✓ Verified tile removed from Dock")
                    DiagnosticsLog.shared.log("dock", "Removed '\(config.name)' from Dock (verified\(attempt > 1 ? " on retry" : ""))")
                    break
                }
                if attempt == 1 {
                    print("   ⚠️ Tile reappeared after restart (Dock write-back) — retrying removal")
                    DiagnosticsLog.shared.log("dock", "'\(config.name)' reappeared in Dock after restart — retrying removal once")
                    removeFromDockPlist(bundleId: config.bundleIdentifier)
                } else {
                    print("   ⚠️ Tile still in Dock after retry")
                    DiagnosticsLog.shared.log("dock", "'\(config.name)' STILL in Dock after retry — removal did not take")
                }
            }
        } else {
```

- [ ] **Step 3: Build and run the unit suite (no behavioural test can drive the real Dock)**

Run: `xcodebuild test -project DockTile.xcodeproj -scheme DockTile -configuration Debug -destination 'platform=macOS' -only-testing:DockTileTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Executed|error:" | tail -3`
Expected: `Executed N tests, with 0 failures` (same N as Task 1 Step 9); `DockActionResolutionTests` and `DockRestartConsentTests` unchanged and green.

- [ ] **Step 4: Re-run the Step 1 repro**

Same add-then-hide-within-3 s sequence, then `pbpaste | grep -E "reappeared|verified|STILL"`.
Expected: `reappeared in Dock after restart — retrying removal once` followed by `Removed '<tile>' from Dock (verified on retry)`; the tile is gone from the Dock after ONE Done, no second click. Also run a normal hide (wait >10 s after add): expected `Removed '<tile>' from Dock (verified)` with a single Dock restart.

- [ ] **Step 5: Commit**

```bash
git add DockTile/Managers/HelperBundleManager.swift
git commit -m "fix(dock): retry a removal the relaunched Dock's write-back undid

Hiding a tile within seconds of adding it could log 'STILL in Dock after
restart' because the Dock flushes its normalised persistent-apps on SIGTERM,
resurrecting the entry. Re-remove and restart once more when that happens.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Decisions (Karthik, 2026-08-29)

1. The old Mac is wiped — no macOS spin report will ever surface for the July incident. The watchdog (Task 1) is the only route to a root cause.
2. Machine state at incident time is not remembered — no reproduction experiments; do not churn the Dock chasing (a)/(b).
3. Ship **Tasks 1 + 2 as 1.8.7**, keeping the Crashlytics non-fatal. Karthik gives a **go/no-go before the tag push** (his standing rule) — Task 3 stops there.

---

### Task 3: Release 1.8.7

**Files:**
- Modify: `DockTile/Config/Base.xcconfig:6-7` (`MARKETING_VERSION = 1.8.6` → `1.8.7`, `CURRENT_PROJECT_VERSION = 25` → `26`)
- Modify: `CLAUDE.md:3` (`v1.8.6 released.` → `v1.8.7 released.`)

**Interfaces:**
- Consumes: Tasks 1 and 2 committed on `main`, full suite green.
- Produces: tag `v1.8.7` → CI builds, signs, notarises, updates `appcast.xml` + `website/lib/config.ts` (see `.claude/rules/ci-release.md`).

**Caution — pre-existing uncommitted edits.** As of 2026-08-29 the tree already has unrelated uncommitted changes in `CLAUDE.md`, `.gitignore`, `Scripts/build-release.sh`, `.claude/rules/ci-release.md` and untracked `.claude/rules/coding-guardrails.md`, `docs/v2/`. Never stage everything. The version-bump commit must contain only the three lines below; if `CLAUDE.md` still carries foreign edits when you get here, ask Karthik whether to commit them separately first or leave the header bump out of this commit.

- [ ] **Step 1: Confirm main is clean apart from the known foreign edits and both tasks are in**

Run: `git status --short && git log --oneline -3`
Expected: the two task commits on top of `fcfec30`; only the foreign files listed above are modified.

- [ ] **Step 2: Bump the versions**

```bash
sed -i '' 's/^MARKETING_VERSION = 1.8.6$/MARKETING_VERSION = 1.8.7/; s/^CURRENT_PROJECT_VERSION = 25$/CURRENT_PROJECT_VERSION = 26/' DockTile/Config/Base.xcconfig
sed -i '' '3s/v1\.8\.6 released\./v1.8.7 released./' CLAUDE.md
git diff -- DockTile/Config/Base.xcconfig CLAUDE.md
```
Expected: exactly three changed lines (two in `Base.xcconfig`, one in `CLAUDE.md`) — if the `CLAUDE.md` diff shows more than line 3, stop (see Caution).

- [ ] **Step 3: Release build sanity**

Run: `xcodebuild -project DockTile.xcodeproj -scheme DockTile -configuration Release build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit and push the bump (in its own Bash call with nothing else on the command line — the project's commit-guard hook is strict about extra flags)**

```bash
git add DockTile/Config/Base.xcconfig CLAUDE.md
git commit -m "chore: Bump version to 1.8.7

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push
```

- [ ] **Step 5: STOP — go/no-go from Karthik**

Report: the three commits (`feat(diagnostics)…`, `fix(dock)…`, `chore: Bump…`), the test count, and that CI on `main` (`gh run list --limit 3`) is green. Do not tag until he says go.

- [ ] **Step 6: Tag and push the tag (after "go")**

```bash
git tag -a v1.8.7 -m "Release 1.8.7"
git push origin v1.8.7
gh run list --limit 3
```
Expected: a `release.yml` run appears and completes; `gh release view v1.8.7` lists the DMG + SHA256; the website commit for `config.ts`/`appcast.xml` lands on `main` from CI.
