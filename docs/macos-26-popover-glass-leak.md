# macOS 26: every `NSPopover` instance leaks its Liquid Glass backdrop

Found 2026-09-21 while chasing a slow memory creep in helper tiles. Status: **no longer reproduces
on macOS 27.0; the workaround stays in Dock Tile for macOS 26 users** (see "macOS 27" below). No
Feedback report was filed: by the time it was due, the leak no longer reproduced on 27.

**If you are adapting Dock Tile to macOS 27 or later: keep the workaround.** Do not gate
`FloatingPanel.popover` behind `#available(macOS 27, *)` and do not return to a popover per open.
The deployment target reaches back to macOS 15, macOS 26 users still leak without it, and one
reused popover costs nothing on 27.

## What happens

On macOS 26 (observed on 26.6.2, build 25G83) each `NSPopover` instance is given a Liquid Glass
backdrop: an `NSGlassView`, a `_NSCoreHostingView<NSGlassEffectView.RootView>` with its SwiftUI view
graph, and an `IOSurface` sized to the popover. When the popover closes and the `NSPopover` is
released, its `NSPopoverFrame` and window go away, but the glass views do not. A `leaks --traceTree`
on an orphan shows it retained by a block AppKit registers itself,
`-[NSView _commonAwake]_block_invoke`, held in an `NSNotificationCenter` registrar and never removed.

Cost: one orphaned set per `NSPopover` instance, forever. For Dock Tile that was 3–5 MB per Dock
click depending on popover size. A production 2.0.1 tile's footprint went from 85 MB to 149 MB over
six days of use; the leak is the per-click component of that, not necessarily all of it.

## Reproduction, no Dock Tile code

`docs/repro/popover-glass-leak.swift` is a self-contained AppKit program with three modes.

    swiftc -O -o popleak docs/repro/popover-glass-leak.swift
    ./popleak fresh 8 &     # new NSPopover per open
    heap $! | grep -E " NSGlassView|NSGlassEffectView.RootView"     # macOS 26 class names ONLY

Results on macOS 26.6.2 (25G83):

| Mode | What it does | `NSGlassView` after 8 opens | Footprint |
|---|---|---|---|
| `fresh` | new `NSPopover` each open | 7 | 28 → 40 MB, climbing |
| `reuse` | one `NSPopover`, one content controller | none extra | 28 MB, flat |
| `swap` | one `NSPopover`, content controller released on close and replaced on open | none extra | 28 MB, flat |

## Measured on real tiles, 2026-09-21

Optimised builds swapped into the same dev tile, `footprint` before and after open/close cycles.

| 102-app tile | New popover per open | One reused popover |
|---|---|---|
| Opens 1–5 | +17 to +31 MB | +8 MB (one-time: icon cache, first window) |
| Opens 6–10 | +25 MB | 0 MB (62 → 62) |

Also checked on a bare probe: a reused popover given different-sized content on each open sizes
correctly at show (no stale frame), and `close()` on a closed popover posts no `popoverDidClose`.

## macOS 27: no longer reproduces, re-tested 2026-09-29

On macOS 27.0 (26A428) the same program in `fresh` mode, a new `NSPopover` per open, no longer
leaks: no class grows with opens.

| `fresh` mode, 8 opens | macOS 26.6.2 | macOS 27.0 |
|---|---|---|
| Orphaned glass objects | 7 | none |
| Footprint, 1 open → 8 opens | 28 → 40 MB | 22 → 24 MB |

**Class names change between releases, so never re-test with a name grep.** The macOS 26 `grep`
above returns zero on 27 whether or not anything leaks: the class it looks for is gone. Taken alone,
that zero cannot tell "fixed" from "renamed". The 27 result comes from a class-agnostic check: run
`fresh` once and eight times, take every `heap` class matching
`Glass|Popover|IOSurface|CABackingStore|NSVisualEffect`, and compare
counts. On 27, glass classes exist (`DesignLibrary.GlassMaterialProvider`, `NSGlassEffectView`
internals) but every one sits at the same count after 1 and 8 popovers. A leak shows as a class whose
count grows with opens, whatever it is called.

Real tiles agree. After 3.5 days of normal use on 2.0.2 and macOS 27, the production AI Tile and
Utils helpers sit at 33 MB and 34 MB, against 149 MB for AI Tile on 2.0.1 and macOS 26 after six
days. These tiles run the workaround, so they cannot show the upstream change on their own; the
bare program is the evidence for that.

**How far this goes.** It is one bare-app probe, eight opens, on one build (27.0, 26A428), and
Apple's release notes mention no fix. Treat it as "no longer reproduces on 27.0", not as a
guarantee for every 27.x. It does not change what Dock Tile does either way.

## The workaround Dock Tile ships

`FloatingPanel.popover` is a `let`: one `NSPopover` per helper process, configured afresh and given a
new `NSHostingController` on every open (the `swap` row), so Popover Appearance settings are still
re-read on each click. Making it a constant blocks one specific regression, assigning a fresh
`NSPopover()` to that property per open. It does not stop someone constructing a `FloatingPanel` per
open; both current owners hold one for their lifetime. The leak itself is invisible to unit tests,
so the check is the ten-open `footprint` measurement above.

The bug no longer reproduces on macOS 27.0, and the workaround stays. It is correct on every version, costs
nothing where the bug is gone, and is still required on macOS 26, which the app supports.

## Related, and NOT a bug of ours: the first-popover memory spike

The first time any process displays a popover on macOS 26, its footprint spikes by roughly 220 MB
and falls straight back (bare probe: peak 14 MB with no popover shown, 234 MB after one, resting at
28 MB). A helper launched in the background and never clicked peaks at 12 MB. This was recorded in
the September 2026 baseline as a "launch spike" and wrongly attributed to decoding the config. It is
a one-time system cost of bringing up the glass rendering path; nothing in app code causes or can
avoid it. Pre-showing a popover at login would only move the cost to every tile up front.

Still present on macOS 27: the bare program peaked at 253 MB just after its first popover and
settled at 22–24 MB.

## Also not a leak: IOSurface regions stop at a fixed count

`footprint` lists a helper's IOSurface *region* count, and it climbs over the first few opens. It
is bounded. Measured over several days on macOS 27 (dev tiles, `Scripts/perf/memwatch.py`), it
plateaued at exactly 28 on both a 6-app and a 102-app tile. The IOSurface bytes behind it never
changed: 2.3 MB and 5.2 MB. A ceiling that does not scale with app count is a system surface pool,
not Dock Tile's icon cache. Judge a leak by bytes and footprint across opens, never by the region
count.
