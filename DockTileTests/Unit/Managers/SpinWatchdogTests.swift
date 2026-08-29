//
//  SpinWatchdogTests.swift
//  DockTileTests
//
//  Regression guards for the helper CPU watchdog's pure seams: the trigger policy
//  (SpinWatchdogPolicy) and the `sample`-report excerpt (DiagnosticsLog.spinExcerpt).
//
//  Motivation: the July 2026 "AI Tile at 82.9 % CPU for 16 h" report left no stack — no hang
//  reporting exists for helper bundles and the 1-hour diagnostics window had already trimmed the
//  incident. The watchdog exists to capture that evidence next time, so its trigger rule must not
//  drift (too eager = a sample on every popover open; too lax = the spin goes uncaptured).
//

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
        // 83 % for hours must trigger; the trigger must take >= 60 s so a popover-open burst can't.
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
