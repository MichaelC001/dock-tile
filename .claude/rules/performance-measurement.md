# Performance Measurement

Paid for in the September 2026 perf cycle, where three baseline numbers failed to reproduce.

- **Trust only same-session A/B.** Old code and new code, same tile, same Mac, minutes apart. A
  number from another day is context, never a baseline: 465 ms, 2250 ms and 114 ms all failed to
  reproduce, and one false "regression" was committed on the strength of "same tool".
- **Record the build kind with every number.** Debug vs optimised differs several-fold. Optimised
  recipe and harness: `Scripts/perf/README.md`.
- **Measure helper code without a Dock restart**: swap the optimised executable into a dev tile's
  bundle, `codesign --force --sign -`, relaunch the helper. Back up first, and re-back-up after any
  Update or the restore silently reverts it. Confirm which code runs with `nm | grep <new symbol>`;
  re-sealing changes the md5.
- **Leak check = `footprint` across TEN opens**, not five: opens 1–5 carry one-time costs, 6–10 must
  be flat. Find the retained objects with `leaks --outputGraph` + `heap --diffFrom` before theorising.
- **Not ours:** ~220 MB transient the first time a process shows a popover (macOS 26 glass bring-up).
  A never-clicked helper peaks at 12 MB. See `docs/macos-26-popover-glass-leak.md`.

## Temporary: dev-tile memory watcher (installed 2026-09-21, REMOVE when done)

`Scripts/perf/memwatch.py` samples every running **dev** helper's footprint, IOSurface use and
popover-open count every 10 minutes via a per-user LaunchAgent (`com.docktile.dev.memwatch`), into
`~/Library/Application Support/DockTile-Dev/memwatch.csv`. It exists to prove the 2.0.2 popover-reuse
fix holds over days of real use, which a ten-open test cannot.

    python3 Scripts/perf/memwatch.py report      # read it
    python3 Scripts/perf/memwatch.py uninstall    # stop; --purge also deletes the CSV

Deliberately OUTSIDE the app: no product code to strip from a release, and the tiles are not
perturbed by their own instrumentation. Dev-only — popover-open lines are verbose, so they do not
exist in Release logs, and production data is never read. **Remove it once a few hundred opens have
accumulated across several days**; a `MB/100 opens` near zero is the pass. Leaving it installed
forever is the failure mode this note guards against.
