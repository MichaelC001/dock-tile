# Dock modification — prior art (writing `com.apple.dock` → `persistent-apps`)

Research date: 2026-10-29. Local machine: macOS 27.0.1 (26A434). Source snapshots examined:
dockutil `main` @ `7238012` (2025-03-16, tags 2.0.5 @ `60ef6a2` for the Python version, 3.1.3 for
Swift), docklib `main` @ `a65483a` (2026-10-05), Chromium `chrome/browser/mac/dock.mm` @ `8cffaa1`
(GitHub mirror, 2026-07-23), syrtis `DockPinRepair.swift` @ `d970868`, hola `macos_dock.zig` @
`8b1cea3`. File:line references are to those snapshots. Every claim is labelled **stated** (the
source says it) or **inference** (my reading, not stated anywhere). Read-only research: nothing on
this Mac was written, killed or restarted.

Why this exists: on 2026-10-29 (macOS 27.0.1) a renamed tile (`DevX.app` → `Dev.app`, old folder
deleted) was left with a `persistent-apps` entry that had the right `bundle-identifier` but a
`_CFURLString` pointing at the deleted `DevX.app`, after two Dock rewrites + `killall Dock` about
3 s apart. Our post-write check matched by bundle id only, so it passed. Code in question:
`HelperBundleManager.addToDock` returns early when `findInDock(bundleId:)` finds *any* entry with
that bundle id (`DockTile/Managers/HelperBundleManager.swift:1771-1773`); `restartDock` is
`/usr/bin/killall Dock` (`:1884-1899`); `quitDockAndWaitForExit` polls
`NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").isEmpty` for 3 s
(`:1912-1924`).

## Summary

- **There is no supported public API to add or remove another app's Dock items.** Stated by Apple
  only indirectly: Quinn (DTS) says Apple preference domains, keys and values are "implementation
  details, not API" ([forum 747595](https://developer.apple.com/forums/thread/747595));
  `NSDockTile` only customises your own app's tile
  ([NSDockTile](https://developer.apple.com/documentation/appkit/nsdocktile)); System Events'
  `dock preferences` exposes no items (local `SystemEvents.sdef`); the only documented item schema
  is the MDM `com.apple.dock` payload, whose `file-data` is "For Apple use only"
  ([Dock payload](https://developer.apple.com/documentation/devicemanagement/dock),
  [tile-data](https://developer.apple.com/documentation/devicemanagement/dock/staticitem/tile-data-data.dictionary)).
  The live alternative, `CoreDockAddFileToDock`, is private (Chromium `dock.mm:374-384`).
- **Apple does document the hazard we hit, in general terms.** `man defaults`: "you shouldn't
  modify the defaults of a running application. If you change a default in a domain that belongs to
  a running application, the application won't see the change and might even overwrite the
  default." Nothing Apple publishes says *when* the Dock writes its own domain (on quit, on launch,
  on change) — **not found**.
- **The admin tools that hold the Dock down while writing say why.** Greg Neagle's original gist,
  carried into docklib, unloads the Dock's launchd job before writing: "unload Dock launchd job so
  we can make our changes unmolested" (`docklib.py:84-111`). hola kills the Dock with SIGKILL before
  synchronizing: "If we set preferences while Dock is running, it will overwrite them when it exits"
  (`macos_dock.zig:382-405`). dockutil and Chromium write while the Dock runs and just restart it.
  None of these cite a measurement; Dock Tile's own 2026-08-29 measurement
  (`.claude/rules/architecture.md`) is the only quantitative evidence found.
- **Fix 1 (verify the entry at the expected path, retry with the Dock quit) — supported, with one
  caveat.** Matching on path is what Chromium (`dock.mm:224-243`, `:357-371`) and Elliot Jordan
  ([resilient docklib](https://www.elliotjordan.com/posts/resilient-docklib/)) do; syrtis reads the
  array back after synchronize (`DockPinRepair.swift:202-207`). No tool verifies *after* the
  restart. Caveat (inference from the launchd plist): "wait until the Dock process is gone" is a
  short window — the Dock agent is `KeepAlive {SuccessfulExit = false}` with `ThrottleInterval 1`
  and 12 MachServices, so launchd brings it back within about a second, or sooner on demand. Only
  docklib's `launchctl unload` actually keeps it down, and whether that still works on macOS 27 is
  unverified (macOS 14.4 already refused `launchctl kickstart -k` for it, dockutil #162).
- **Fix 2 (same bundle id, different path = stale, replace it) — supported.** syrtis does exactly
  this repair for its own rename (`DockPinRepair.swift:3-9`, `:44-107`), with guards: same bundle id,
  old path `ENOENT`, same parent folder, exactly one candidate. Chromium replaces a reference to the
  app on the disk image with the installed path (`dock.mm:232-249`). The Dock does not resolve such
  entries itself: Apple's help says a deleted app's icon "remains in the Dock but is covered by a
  question mark" ([Apple Support](https://support.apple.com/guide/mac-help/if-the-dock-contains-a-question-mark-mchlp1412/mac)).
- **Fix 3 (serialize mutations, one restart) — the batching half is supported; "wait for the Dock
  to come back before the next" has no direct evidence either way.** dockutil's author: "I'd only
  restart/kill the dock once after all changes" ([dockutil #147](https://github.com/kcrawford/dockutil/issues/147#issuecomment-1464343167));
  dockutil applies all edits in one read-modify-write and saves once (`DockUtil.swift:500-502`).
  syrtis refuses to write if `mod-count` changed between its read and its write
  (`DockPinRepair.swift:182-201`). dockutil's 3.0 betas waited for the plist file to change before
  restarting and then dropped it ("remove save delay", `ac9cb6f`), with no reason given.
- **On SIGTERM vs SIGKILL (a candidate the brief did not list).** hola uses `kill -9` "to force kill
  Dock without allowing it to save state" (`macos_dock.zig:809`). Chromium found SIGTERM "more
  reliable ... than ... launchctl stop" (`dock.mm:156-161`). Nobody published a comparison of the
  two for the revert problem — **not found**.

## 1. What Apple documents

### No supported API for Dock items

- **Preferences of Apple apps are not API (stated).** Quinn, DTS, March 2024, answering a developer
  reading `com.apple.dock.plist`: "Unless otherwise documented, system preferences files are not
  considered API. Relying on them incurs a significant binary compatibility risk." Follow-up:
  "`UserDefaults` is better than reading the property list directly, but it still has the same
  fundamental problem: Unless otherwise documented, the domain, keys, and values for Apple
  preferences are implementation details, not API."
  ([forum 747595](https://developer.apple.com/forums/thread/747595)). His suggested route, System
  Events' Dock AppleScript, triggers a TCC alert.
- **System Events cannot add items (stated by the dictionary).** The `dock preferences object` class
  in `/System/Library/CoreServices/System Events.app/Contents/Resources/SystemEvents.sdef` (read on
  this Mac) has exactly these properties: animate, autohide, dock size, autohide menu bar, double
  click behavior, magnification, magnification size, minimize effect, minimize into application,
  screen edge, show indicators, show recents. No item list.
- **`NSDockTile` is your own tile only (stated).** "The visual representation of your app's
  miniaturized windows and app icon as they appear in the Dock" — badge, custom content view, no
  pinning ([NSDockTile](https://developer.apple.com/documentation/appkit/nsdocktile)).
- **MDM is the only documented item schema (stated).** The Device Management `Dock` payload
  (payload type `com.apple.dock`, device and user channel) documents `persistent-apps` ("items ...
  that users can remove from the Dock"), `static-apps` ("users can't remove"), `static-only`,
  `contents-immutable`
  ([Dock payload](https://developer.apple.com/documentation/devicemanagement/dock)). Its tile-data
  dictionary documents `file-data` as "The data in a file. For Apple use only.", `file-type`
  0 URL / 1 File / 3 Directory, `label`, `url`
  ([tile-data](https://developer.apple.com/documentation/devicemanagement/dock/staticitem/tile-data-data.dictionary)).
  Note the documented `file-type` values differ from the `41` that real `persistent-apps` app
  entries carry (dockutil `DockTile.swift:20-34` comment shows a Dock-written entry with 41). A
  profile is not available to an app as an API.
- **A private live API exists (stated by Chromium, not Apple).** Chromium's `dock.mm:374-384`:
  "HIServices.framework contains an undocumented function, CoreDockAddFileToDock, that is able to
  add items to the Dock 'live' without requiring a Dock restart ... it communicates with the Dock
  via Mach IPC ... seems to always to add the new Dock icon last". Chromium does not use it.

Verdict: **no supported public API to add or remove Dock items.** Every shipping tool examined
edits the preference domain and restarts the Dock.

### CFPreferences and cfprefsd semantics

- **`CFPreferencesAppSynchronize` (stated).** "Writes to permanent storage all pending changes to
  the preference data for the application, and reads the latest preference data from permanent
  storage." Discussion: "preference data is cached after it is first read. Changes made externally
  are not automatically incorporated. The CFPreferencesAppSynchronize function reads the latest
  preferences from permanent storage."
  ([CFPreferencesAppSynchronize](https://developer.apple.com/documentation/corefoundation/cfpreferencesappsynchronize(_:))).
  Nothing about other processes holding their own copy.
- **Foundation Release Notes, OS X 10.10 / iOS 8 (stated).** "In earlier releases, the various
  'set' methods on NSUserDefaults would wait several seconds before publishing the changes to other
  applications unless synchronized ... This delay has been removed. Additionally, iOS now matches
  Mac OS X's behavior of automatically picking up external changes without needing to
  synchronize." And: "the NSUserDefaults daemon process (cfprefsd) will cache information from
  these files and asynchronously write to them. This means that directly modifying plist files is
  unlikely to have the expected results (new settings will not necessarily be read, and may even be
  overwritten). You should use the NSUserDefaults or CFPreferences APIs, or (on Mac OS X) the
  defaults(1) command"
  ([Foundation Release Notes, older](https://developer.apple.com/library/archive/releasenotes/Foundation/RN-FoundationOlderNotes/index.html),
  section "Notes specific to OS X 10.10 and iOS 8"). `UserDefaults.synchronize()` is now documented
  as "unnecessary and shouldn't be used"
  ([synchronize()](https://developer.apple.com/documentation/foundation/userdefaults/synchronize())).
- **cfprefsd rewrites from its cache (stated, about an app's own file).** Quinn, December 2022:
  "This file is managed by a system process, `cfprefsd`, and it caches a bunch of stuff. If you
  delete the file, the next time `cfprefsd` commits a change it'll overwrite it with the cached
  contents." ([forum 721805](https://developer.apple.com/forums/thread/721805)); June 2018: "Trying
  to work with preferences files directly is unreliable because the files are managed by a system
  process (cfprefsd) that holds a lot of internal state."
  ([forum 105148](https://developer.apple.com/forums/thread/105148)). Dock Tile already goes through
  CFPreferences, so these confirm the API choice; they do not address a second process (the Dock)
  writing the same key.
- **A running app can overwrite external changes to its own domain (stated).** `man defaults`
  (macOS 27.0.1, also at [ss64](https://ss64.com/mac/defaults.html)): "Note: Since applications do
  access the defaults system while they're running, you shouldn't modify the defaults of a running
  application. If you change a default in a domain that belongs to a running application, the
  application won't see the change and might even overwrite the default." This is the only Apple
  text found that matches the "dying Dock" theory, and it does not say *when* the overwrite happens.
- `man cfprefsd` (dated 2011) says only "cfprefsd provides preferences services for the
  CFPreferences and NSUserDefaults APIs ... Users should not run cfprefsd manually."
- **When does the Dock write `persistent-apps`? Not found.** No Apple document, DTS post or release
  note found says whether the Dock writes its domain on SIGTERM, on launch, or only on change.
  Looked: the CFPreferences and UserDefaults reference pages, Foundation release notes (older
  notes page), DTS forum threads 747595 / 721805 / 105148 / 659448, `man defaults`, `man cfprefsd`,
  `man launchd.plist`.

## 2. How established tools do it (source code)

### dockutil — Python 2.0.5 (`scripts/dockutil` @ `60ef6a2`)

<https://github.com/kcrawford/dockutil/blob/2.0.5/scripts/dockutil>

- **Writes with `defaults import`, never CFPreferences directly** (lines 377-401). Comment
  (377-382): "We use defaults because it knows how to handle cfpreferences caching even when given a
  path rather than a domain". Runs as the plist owner via `sudo -u` when root.
- **Restart = `/usr/bin/killall Dock`**, skipped with `--no-restart` (`commitPlist`, lines 657-660).
  No wait after, no verification.
- **Waits for Apple's first-login setup** (lines 269-282): if the plist belongs to the console user,
  poll up to 5 s for `mod-count` ≥ 2 — "wait for mod-count to be > 1 because dock is still being
  setup by Apple". Added in `09f132e` (2016-06-05, "Wait for dock to be setup by Apple before
  modifying"). This is stated evidence that the Dock itself writes its domain during startup.
- **Matching**: remove matches `file-label` **or** `bundle-identifier` (lines 639-643); add refuses
  a duplicate *label* and offers `--replacing <label>` (lines 542-560). No path matching, no `book`.

### dockutil — Swift 3.x (`Sources/DockUtil/Dock.swift` @ `7238012`)

<https://github.com/kcrawford/dockutil/blob/7238012dc414eed1604f0ce8791937c493e1f914/Sources/DockUtil/Dock.swift>

- **Logged-in user's own Dock: CFPreferences** — read with `CFPreferencesCopyAppValue` (lines
  53-62), write each section with `CFPreferencesSetAppValue`, then
  `CFPreferencesSynchronize(dockDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)`
  (lines 94-106). **Other users / root: `defaults export` / `defaults import`** (lines 63-90,
  117-169), with the comment "IF WE WRITE DIRECTLY TO PLIST, CFPREFS IGNORES THE FILE ON DISK UNLESS
  WE KILL CFPREFS" (lines 130-132).
- **Restart = `NSRunningApplication.terminate()`** on the running Dock, falling back to
  `killall Dock` only if no Dock is found (lines 221-237). No wait for exit, no wait for relaunch,
  no read-back. History: 3.0 used `launchctl kickstart -k gui/<uid>/com.apple.Dock.agent`; commit
  `bdbb8b7` (2024-02-08, "Change dock restart method for 14.4 compatibility", in 3.1.3) switched to
  `terminate()` because macOS 14.4 refused kickstart (issue
  [#162](https://github.com/kcrawford/dockutil/issues/162); Apple's 14.4 beta note quoted by
  [Kevin M. Cox](https://www.kevinmcox.com/2024/03/changes-to-launchctl-kickstart-in-macos-14-4/):
  "using launchctl kickstart -k is no longer permitted for critical system processes ... it is
  recommended to use kill instead").
- **A save delay existed and was removed.** The 3.0 betas, for the logged-in user, armed a
  file-system watcher on `~/Library/Preferences/com.apple.dock.plist` and kickstarted the Dock 250 ms
  after the file changed, with a 15 s timeout fallback (`monitorDockForRestart`, removed in
  `ac9cb6f`, 2022-02-28, "Use defaults when not running as user, remove save delay", first released
  in 3.0.0b3). The commit gives no reason. **Inference:** the author once believed the restart had
  to wait for cfprefsd to flush to disk, and later concluded it did not.
- **Still waits for Apple's first-login setup**: `waitForAppleModifications` (lines 200-206), called
  when the target is the current user's plist (`DockUtil.swift:356-360`).
- **One read-modify-write per invocation**: every `--add/--remove/--move` edits the in-memory model,
  and `save(restart:)` runs once at the end, only if something changed (`DockUtil.swift:363-502`).
- **Matching** (`index(within:item:)`, lines 332-343): an item matches if its **label, bundle
  identifier, path, or URL string** equals the query. But `add` checks for duplicates by **label
  only** (lines 255-261) and replaces only with `--replacing` (lines 263-270). **Inference:** adding
  `/…/Dev.app` while a stale `DevX` entry with the same bundle id exists yields two entries unless
  the caller passes `--replacing <bundle id>`.
- **Entry shape** (lines 277-288): `_CFURLString` = the plain path, `_CFURLStringType` **0**,
  `file-label`, `file-type` 41, random GUID; **no `bundle-identifier`, no `book`**. The comment at
  `DockTile.swift:20-34` shows what the Dock itself writes: `book`, `bundle-identifier`,
  `dock-extra`, `_CFURLStringType` 15, `file-mod-date`, `parent-mod-date`.
- **Known issues about changes not sticking:** [#147](https://github.com/kcrawford/dockutil/issues/147)
  (Ventura, items added "50% of the time"; the script restarted the Dock in the middle and again at
  the end — author: "I'd only restart/kill the dock once after all changes. You are restarting it in
  the remove."); [#28](https://github.com/kcrawford/dockutil/issues/28) (2014–2016, removes at login
  not sticking; `sleep 2` and extra `killall Dock` did not help one reporter, who ended up doing
  remove-all then re-add without `--no-restart`); [#116](https://github.com/kcrawford/dockutil/issues/116)
  (`--allhomes` as root needed `killall cfprefsd`; author fixed two bugs and asked whether
  `killall -9 Dock` worked around it — no answer recorded). None of these was root-caused to a
  dying-Dock flush.

### docklib (`homebysix/docklib`, from Greg Neagle's gist)

<https://github.com/homebysix/docklib/blob/a65483a92fabae67c5558a604a7b200d21497f11/docklib/docklib.py>,
original <https://gist.github.com/gregneagle/5c422d709c93615341a21009f800222e>

- **Writes with the Dock's launchd job unloaded** (`save`, lines 84-111):
  `launchctl unload /System/Library/LaunchAgents/com.apple.Dock.plist` with the comment "unload Dock
  launchd job so we can make our changes unmolested", then `CFPreferencesSetAppValue` per section,
  `CFPreferencesAppSynchronize` (raises `DockError` if false), then `launchctl load` +
  `launchctl start com.apple.Dock.agent`. Identical in the gist. The rationale is only that comment.
  No verification. **Unverified:** whether `launchctl unload` of this system agent still works on
  macOS 15–27 (not tested here; doing so would change system state).
- **Matching** (`findExistingEntry`, lines 113-159): `match_on="any"` tries `file-label`, then path
  (from `_CFURLString`), then basename with and without extension. No bundle id, no `book`.
  docklib 1.3.0 moved away from labels because they are localised
  ([#32](https://github.com/homebysix/docklib/issues/32), CHANGELOG line 21). Elliot Jordan, the
  maintainer: "Compare the path, not the label, due to localization" and missing apps leave question
  marks that "will fix themselves if the referenced app is subsequently installed"
  ([Writing resilient docklib scripts](https://www.elliotjordan.com/posts/resilient-docklib/),
  2021-09-04). That post's other timing advice is to wait for the Dock *process* to be running
  before scripting it (1 s poll, 60 s cap).
- **Entry shape** (`makeDockAppEntry`, lines 247-259): `NSURL.fileURLWithPath(...).absoluteString`,
  `_CFURLStringType` 15, `file-label`, `file-type` 41; no `bundle-identifier`, no `book`, no GUID.

### Chromium (`chrome/browser/mac/dock.mm`)

<https://github.com/chromium/chromium/blob/8cffaa143096523841ace0036a2879cadaebc486/chrome/browser/mac/dock.mm>

- **Writes the whole domain with `NSUserDefaults setPersistentDomain:forName:@"com.apple.dock"`**
  (lines 386-396), then restarts.
- **Restart = SIGTERM to the PID launchd reports for `com.apple.Dock.agent`** (lines 146-162):
  "Unlike 'killall Dock', looking this up via launchd guarantees that only the right process will be
  targeted. Sending a SIGTERM to the Dock seems to be a more reliable way to get the replacement Dock
  process to read the newly written plist than using the equivalent of 'launchctl stop' (even if
  followed by 'launchctl start.') Note that this is a potential race in that pid may no longer be
  valid or may even have been reused." No wait, no verification.
- **Matching is by path only** (`PathsFromAppList`, lines 84-129, decodes `file-data` with the
  private `_CFURLCreateFromPropertyListRepresentation`; `ChromeIsInTheDock`, lines 357-371, compares
  against the running bundle path). **Stale-path replacement:** if the Dock references the copy on
  the disk image (`dmg_app_path`), that entry is removed and the new tile inserted at its index; if
  both exist, only the DMG one is removed (lines 224-249). No-op when nothing changed: "there's no
  point in rewriting the Dock's plist or restarting the Dock" (lines 341-345).
- **Entry shape** (lines 322-334): `tile-type` + `tile-data.file-data` only, built by the private
  `_CFURLCopyPropertyListRepresentation`; the comment (lines 23-33) explains `_CFURLStringType` 15
  is CFURL's `FULL_URL_REPRESENTATION` used since 10.7.2.

### syrtis — `DockPinRepair.swift` (a menu-bar app repairing its own renamed tile)

<https://github.com/Nanako0129/syrtis/blob/d970868967f7581cf4ffb8c3efff33ec0e8e5342/Sources/Syrtis/DockPinRepair.swift>
(MIT, ~500 stars, file added 2026-09-26). The closest published analogue to our bug.

- **The problem statement is ours (stated, lines 3-9):** the rename "changes the installed bundle's
  file name ... (same bundle id ...), so a tile pinned to `…/TokenBar.app` points at a missing file.
  On a launch after the rename this rewrites that single tile to the running bundle's URL and
  restarts the Dock once."
- **Decision (lines 44-107):** candidate = a `file-tile` whose `bundle-identifier` equals the running
  bundle's, whose leaf is the old name, in the same parent folder; give up if anything already
  points at the running bundle, if there is not exactly one candidate, if the old path is not
  `ENOENT`, or if `persistent-apps` is forced / `contents-immutable` / `static-only`. Rewrites
  `_CFURLString`, `_CFURLStringType` 15, `file-label` **and `book`** (fresh `bookmarkData()`), keeps
  every other key.
- **Concurrency guard (lines 148-153, 182-201):** read `mod-count` before the array; after
  computing, `CFPreferencesAppSynchronize` and re-read `mod-count`; if it changed, "Dock preferences
  changed while repairing" → abandon without writing. "The Dock may have saved since the read; never
  write over that."
- **Read-back (lines 202-207):** after writing and synchronizing, re-read and require the array to
  equal what was written and to differ from the original only in the four keys.
- **Restart = `kill(pid, SIGTERM)`** on the Dock's PID (lines 276-284), once per path, remembered in
  its own defaults. Lines 191-196: "A match after this path already had its one restart means the
  Dock did not keep the repair. Writing again without a restart changes nothing the Dock shows, so
  leave it alone." **Inference:** the author also expects the Dock may fail to keep a write, and
  chose to give up rather than retry.

### hola — `macos_dock.zig` (a dotfiles/setup tool)

<https://github.com/ratazzi/hola/blob/8b1cea3bc9a4fe79459da2a749d259cf19591c8c/src/resources/macos_dock.zig>
(25 stars).

- **Kill before synchronize (stated, lines 382-405):** after `CFPreferencesSetAppValue`:
  "CRITICAL: Kill Dock BEFORE setting preferences! If we set preferences while Dock is running, it
  will overwrite them when it exits", then SIGKILL, sleep 0.5 s, `CFPreferencesSynchronize`, sleep
  1 s. `killDockWithSignal9` (line 809): "Use kill -9 to force kill Dock without allowing it to save
  state". Its "verify" block (lines 393-401) reads the value back but never compares it. No
  measurement is cited. Other Dock settings use plain `killall Dock` "to allow Dock to terminate
  gracefully" (lines 788-793).
- **Writes `book`** via `CFURLCreateBookmarkData(..., kCFURLBookmarkCreationSuitableForBookmarkFile)`
  and refuses to add a path that does not exist on disk (lines 576-628).

### Others looked at

- **Tencent lemon-cleaner** uninstaller (`LMLocalApp.m:485-543`): `CFPreferencesAppSynchronize`
  → copy → filter by path prefix → set → synchronize → `system("killall Dock")`. No verification.
  <https://github.com/Tencent/lemon-cleaner/blob/7ff8676f1dbe624b039f6b5d50ca81b50963629e/localPod/LemonUninstaller/LemonUninstaller/Classes/Manager/LMLocalApp.m>
- **"Docktor"**: no macOS Dock tool by that name found on GitHub (`gh search repos docktor` returns
  only Docker-related projects). **Not found.**
- **Jamf / MDM**: the `com.apple.dock` payload above (managed, not an app API). Jamf community
  threads mostly recommend running dockutil in the user context once, waiting for the Dock process
  before running, and restarting once at the end; several add `killall cfprefsd` after editing the
  plist file directly (e.g. [jamf: dock not resetting](https://community.jamf.com/general-discussions-2/dock-not-resetting-to-default-state-2352)).
  These concern direct file edits and root context, not CFPreferences writes by the user.

## 3. Is the "dying Dock flushes stale `persistent-apps`" behaviour documented or reported?

- **Apple, general form (stated):** `man defaults` — a running application "might even overwrite
  the default" (§1). Not Dock-specific, no timing.
- **Tool authors, Dock-specific (stated, unmeasured):** Neagle/docklib unload the job "so we can make
  our changes unmolested"; hola: the Dock "will overwrite them when it exits". dockutil's
  `mod-count` wait shows the Dock writes its domain at least during first-login setup.
- **Dock Tile's own measurement (stated in `.claude/rules/architecture.md`, 2026-08-29):** plain
  write-then-`killall` stranded 7 entries under concurrent restarts; one quit-then-write pass
  cleared them; 12/12 plain writes succeeded on a settled Dock. This remains the only number found.
- **Admin blogs:** **not found.** Looked: scriptingosx.com search for "dockutil" (only news
  summaries), derflounder.wordpress.com search for "cfprefsd" (one 2013 Safari post that restarts
  cfprefsd), web searches for Armin Briegel / Rich Trouton / Tim Sutton plus Dock/cfprefsd terms,
  Eclectic Light Co. preference articles (cfprefsd caching of direct file edits, not the Dock).
  macadmins Slack is not searchable from here.
- **What the community recommends (stated, varied):** restart once after all changes (dockutil
  #147); wait for the Dock process before scripting (Elliot Jordan); unload the job while writing
  (docklib); SIGKILL before synchronize (hola); `killall cfprefsd` only when the plist *file* was
  edited directly (Jamf threads, dockutil #116). Sleeps appear in hola (0.5 s / 1 s) and in user
  scripts; no source justifies a particular duration.

**Inference about our 2026-10-29 case** (not stated anywhere): the Dock agent plist on this Mac
(`/System/Library/LaunchAgents/com.apple.Dock.plist`, read with `plutil -p`) is
`KeepAlive = {AfterInitialDemand = true; SuccessfulExit = false}`, `ThrottleInterval = 1`,
`RunAtLoad = false`, plus 12 `MachServices`. Per `man launchd.plist`, `SuccessfulExit = false`
restarts the job when it exits *unsuccessfully* (a signal death would qualify — my reading), and
`ThrottleInterval` overrides the default 10 s spawn throttle, here to 1 s. Two rewrites + `killall`
3 s apart therefore give a Dock that was relaunched ~1 s after the first kill, has loaded the list,
and is signalled again — two chances for a Dock holding the pre-second-write list to write it
back. The same plist also means `quitDockAndWaitForExit` may never see an empty process list inside
its 3 s window, or may see it for well under a second; the MachServices can also demand-launch the
Dock early.

## 4. How existing items are matched; what the Dock does with `book` and missing paths

| Tool | Matches on | Writes `bundle-identifier` | Writes `book` |
|---|---|---|---|
| dockutil 2.0.5 (Python) | label or bundle id (remove); label (add duplicate check) | no | no |
| dockutil 3.x (Swift) | label, bundle id, path or URL (`index`); label only for add's duplicate check | no | no |
| docklib | label → path → basename (`any`) | no | no |
| Chromium | path only | no | no |
| syrtis | bundle id + old leaf + same parent + old path missing | keeps existing | yes |
| hola | (path) | — | yes |
| Dock Tile today | bundle id first, then Info.plist at the path (`findInDock`) | yes | no |

- **Does the Dock resolve a moved app through `book`? Not found.** No source documents what the
  Dock does with `book`. Apple's help says the Dock holds "An alias for the item"
  ([Dock, 10.14 help](https://support.apple.com/guide/mac-help/dock-mh35859/10.14/mac)), and
  Csaba Fitzl notes entries work without `bundle-identifier` or `book`
  ([Beyond the good ol' LaunchAgents 27](https://theevilbit.github.io/beyond/beyond_0027/), 2022).
  syrtis and hola write a fresh `book`, neither says why.
- **Entry whose file no longer exists (stated):** the icon "remains in the Dock but is covered by a
  question mark" ([Apple Support](https://support.apple.com/guide/mac-help/if-the-dock-contains-a-question-mark-mchlp1412/mac));
  it heals if an app is later installed at that path (Elliot Jordan, above); a dockutil user with
  wrong paths got question marks and had to unpin and re-pin
  ([#171](https://github.com/kcrawford/dockutil/issues/171)). **Inference:** for entries like ours
  (no `book`), the Dock resolves by `_CFURLString` and does not fall back to `bundle-identifier`.
  So a bundle-id-only check cannot tell a live entry from a dead one. That is exactly the hole that
  let the 2026-10-29 check pass.
- `file-mod-date = 0` in our stale entry: what the Dock writes there, and whether 0 means "never
  resolved", is **not documented** anywhere found.

## 5. Concurrency, rapid restarts, batching

- **Batch, restart once (stated):** dockutil's author (#147, above); dockutil, Chromium and docklib
  all do one read-modify-write and one restart per operation, and Chromium skips both when nothing
  changed.
- **Detect a concurrent Dock write (stated):** syrtis's `mod-count` before/after guard (lines
  182-201). dockutil only uses `mod-count` to wait out first-login setup.
- **Hold the Dock down while writing (stated):** docklib/Neagle `launchctl unload` … `load` +
  `start`. hola's SIGKILL-then-sync is the lighter version.
- **Rapid successive `killall Dock`:** no source reports measurements. Chromium flags the PID-reuse
  race in its own SIGTERM (lines 159-160). Dock Tile's 2026-08-29 measurement is the only evidence
  that concurrent restarts strand entries.
- **Multiple writers to `com.apple.dock`:** nothing beyond the above. Apple's only advice is
  general: don't modify a running app's defaults (`man defaults`), and use IPC rather than
  preferences to signal another process (10.10 release notes).

## Verdicts on Dock Tile's proposed fixes

1. **Verify the entry at the expected path after every Dock write; on failure quit the Dock, wait
   for exit, rewrite.**
   - *Verify at path:* **supported.** Path is what the Dock resolves (§4), and Chromium and docklib
     match on it. Nobody else verifies after the restart. syrtis verifies before it, and its
     "the Dock did not keep the repair" comment admits the case.
   - *Retry with the Dock gone:* **supported in principle** (`man defaults`, docklib, hola), **but
     the current "wait for exit" mechanism is weakly supported.** Inference from the agent plist:
     launchd relaunches within ~1 s, so a 10 ms poll for an empty process list can miss the gap.
     Prior art holds the Dock down with `launchctl unload` (unverified on macOS 27), or uses SIGKILL
     so the dying Dock cannot save. Both are untested here; measure same-session before adopting
     either.
2. **Treat a same-bundle-id entry with a different path as stale and replace it in `addToDock`:**
   **supported.** syrtis ships exactly this repair; Chromium replaces the DMG-path entry in place.
   syrtis's guards are worth copying: old path `ENOENT`, exactly one candidate, nothing already at
   the new path, not forced/immutable. A path-only check, like Chromium's, would also have caught
   the bug.
3. **Serialize all Dock mutations through one queue; wait for the Dock to come back before the
   next:**
   - *Serialize/batch into one restart:* **supported** (dockutil author; every tool's single
     read-modify-write; syrtis's `mod-count` guard as a cheap detector).
   - *Wait for the Dock to come back:* **no evidence either way.** The closest: Elliot Jordan waits
     for the Dock process before scripting at login, and dockutil's waits for first-login
     `mod-count` ≥ 2. dockutil tried waiting for the plist flush before restarting, then removed it
     without a stated reason.

## 6. On-Mac experiment (2026-10-29, macOS 27.0.1, the owner's Mac)

A scratch entry (bundle id `local.experiment.dockwrite`, two stub bundles `ExpA.app` / `ExpB.app`
in a temp folder) was flipped between the two paths with the same CFPreferences calls Dock Tile
uses. Each trial first restarted the Dock with `killall Dock` (standing in for the launch
migration's restart), waited a gap, then rewrote the entry with one of three methods. The result
counts as OK only if, after the Dock settled (same PID for 3 s), both the plist AND the running
Dock (its AX item names) showed the new path, exactly once. Every other entry was compared with
a baseline after every trial; all 14 stayed identical. Dock preferences were backed up with
`defaults export` first.

| Method | 0.5 s after a restart | 2.5 s after | 10 s after |
|---|---|---|---|
| A: write, then `killall Dock` (SIGTERM) — what Dock Tile ships | 0/7 | 0/7 | 3/3 |
| B: SIGKILL, wait 0.5 s, then write (hola order) | 4/4 | 0/4 | — |
| C: write, then SIGKILL | 7/7 | 3/3 (+4 uninformative) | 3/3 |

(Run 1 had A and B at 4 trials per cell; its C trials at 2.5 s started from a state the failed B
trial before them had left, so they tested nothing and are excluded. Run 2 fixed that by starting
each trial from what the running Dock showed.)

- **A loses the write every time while the Dock is young.** On a settled Dock it worked, which
  agrees with the 2026-08-29 "settled Dock 12/12". Tonight's rename hit exactly this window: the
  Update started ~2.7 s after the migration's restart.
- **B depends on launchd's throttle.** When the last launch was under ~1 s earlier, launchd waited
  before relaunching, and the write landed with no Dock running (OK). When it was 2.5 s earlier,
  launchd relaunched the Dock within the 0.5 s wait. The new Dock loaded the OLD list, so the plist
  held the new path while the Dock showed the old one (4/4 split). "Kill, then write" is not safe
  without holding the Dock down.
- **C never failed (13/13 informative trials, plus the final cleanup).** A SIGKILLed Dock has no
  chance to save on its way out, and the Dock that launchd starts next reads what we wrote.
- **A plist read shortly after a restart can report a success that does not last.** Run 1's cleanup
  used A. Three seconds after the restart the plist read said the entry was gone. The new Dock had
  loaded the old list anyway, and it later wrote that list back: the entry reappeared, now carrying
  a `book` bookmark and `file-mod-date = 0` it had not had before. So the Dock writes
  `persistent-apps` itself some seconds after launch, not only on exit. A check that reads only the
  plist soon after a SIGTERM restart can pass and still be wrong later.
- `file-mod-date = 0` appeared on an entry whose bundle EXISTS (a stub with no executable), so 0
  does not by itself mean "path missing".

Not tested: whether SIGKILL loses other Dock-owned state (Spaces arrangement, a drag in progress).
Nothing visible changed over ~60 SIGKILLs, but that is not a check. Also not tested: `launchctl
unload` / `bootout`.

## Could not verify

- When the Dock writes `persistent-apps`. §6 shows it writes some seconds after launch as well as
  (by inference from method A) on SIGTERM exit. No Apple or third-party source found.
- Whether SIGKILL is safe for the Dock's other state. §6 shows it prevents the revert. No
  measurements of its side effects.
- Whether `launchctl unload /System/Library/LaunchAgents/com.apple.Dock.plist` (docklib) still works
  on macOS 15–27. Not tested: it would change system state.
- What the Dock does with `book` for a moved or renamed app, and what `file-mod-date = 0` means.
- Any macadmins Slack discussion (not searchable from here), and Dock posts by Armin Briegel, Rich
  Trouton or Tim Sutton on this topic. None found by the searches listed in §3.
