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
- **Not ours:** ~220 MB transient the first time a process shows a popover (glass bring-up, still
  present on macOS 27). A never-clicked helper peaks at 12 MB. See `docs/macos-26-popover-glass-leak.md`.
- **Not a leak either: the IOSurface *region* count.** It climbs over the first opens, then plateaus
  (exactly 28 on a 6-app and a 102-app tile, macOS 27) with constant bytes. Judge by bytes and
  footprint across opens, never by region count.
- **Re-test system bugs class-agnostically on a new macOS.** Class names change between releases: a
  `grep NSGlassView` returns zero on macOS 27 whatever the truth, because the class is gone. Compare
  the counts of EVERY `Glass|Popover|IOSurface|CABackingStore|NSVisualEffect` heap class at 1 vs 8
  opens; a leak is any class that grows.

## Temporary: dev-tile memory watcher (installed 2026-09-21, KEEP until ~2026-11-29)

`Scripts/perf/memwatch.py` samples every running **dev** helper's footprint, IOSurface use and
popover-open count every 10 minutes via a per-user LaunchAgent (`com.docktile.dev.memwatch`), into
`~/Library/Application Support/DockTile-Dev/memwatch.csv`. It exists to prove the 2.0.2 popover-reuse
fix holds over days of real use, which a ten-open test cannot.

**Karthik decided on 2026-09-29 to keep it collecting on his dev Mac for about two more months.**
Do not uninstall it or `git rm` it before then, including as macOS 27 housekeeping. Review it around
2026-11-29, then remove it (issue #16).

**It cannot ship, and must stay that way.** It is a repo script plus a per-user LaunchAgent on one
Mac; nothing in the app target references it, so it is never compiled or bundled (verified against
the shipped 2.0.2 app). `DevToolingExclusionTests` fails if `project.pbxproj` ever references it.
It reads only `DockTile-Dev/` paths and dev helper processes, never production data.

    python3 Scripts/perf/memwatch.py report      # read it
    python3 Scripts/perf/memwatch.py uninstall    # stop; --purge also deletes the CSV

Read its `MB/100 opens` column with care: it counts one-time warm-up as growth, so with few opens it
overstates. The 2026-09-29 review showed "+33.3" for a tile that went 37 → 38 MB across ten opens
after warm-up. Reviewed that day: no defect, fix holds; data is all on macOS 27 (installed 09-22).

Deliberately OUTSIDE the app: no product code to strip from a release, and the tiles are not
perturbed by their own instrumentation. Dev-only — popover-open lines are verbose, so they do not
exist in Release logs. Pass at review: `MB/100 opens` near zero after warm-up. Leaving it installed
indefinitely past the review date is the failure mode this note guards against.

Reading two months of data: dev tiles are rebuilt whenever the dev app changes, so rows span
different code. Match row start times against `git log` before comparing one row with another.
The report groups rows by tile and process ID, and helpers get low IDs at login, so over many
reboots a reused ID can merge two processes into one row: an `uptime` that drops mid-row is the
tell. The open count parses the helpers' "✔ Show popover" log line, so renaming it reads as zero
opens, not as an error.
