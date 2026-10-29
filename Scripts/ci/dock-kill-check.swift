// CI-ONLY. Proves on a real macOS runner that a Dock killed with SIGKILL straight after a
// persistent-apps write is relaunched by launchd and KEEPS that write — the mechanism the 2.6.2
// Dock write-race fix rests on (docs/dock-modification-prior-art.md §6: write-then-SIGTERM lost
// 14/14 writes within 2.5 s of a restart; write-then-SIGKILL kept 13/13, measured on macOS 27).
//
// It REWRITES the Dock of the current user and kills the Dock repeatedly. Never run it on a
// developer Mac — it exists for the throwaway runners of the `dock-kill-check` job in ci.yml.
//
// Usage: swift Scripts/ci/dock-kill-check.swift <workdir>
//   <workdir>/trial-N.png, <workdir>/control-N.png, <workdir>/baseline.png — Dock captures
// Exit: 0 only when all six counted trials pass · 1 on any miss (a capture that can't be made
//       counts as a miss: a check that cannot measure must not pass) · 2 usage / not on CI
import AppKit

guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil else {
    print("refusing to rewrite a non-CI Dock"); exit(2)
}
guard CommandLine.arguments.count == 2 else { print("usage: dock-kill-check <workdir>"); exit(2) }
let work = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
let measure = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("dock-measure.swift").path

let domain = "com.apple.dock" as CFString
let appsKey = "persistent-apps" as CFString
let stubID = "com.docktile.ci.killcheck"

@discardableResult
func run(_ exe: String, _ args: [String], passStderr: Bool = false) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = passStderr ? FileHandle.standardError : FileHandle.nullDevice
    do { try p.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

/// This user's Dock only: another session's Dock on the runner must not read as a relaunch.
func dockPID() -> Int32? {
    Int32(run("/usr/bin/pgrep", ["-x", "-U", "\(getuid())", "Dock"]).out.split(separator: "\n").first ?? "")
}

/// Any Dock whose PID differs from `old` (nil: any Dock at all), within `timeout` seconds.
func waitForNewDock(old: Int32?, timeout: Double = 5) -> Int32? {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if let p = dockPID(), p != old { return p }
        usleep(50_000)
    }
    return nil
}

/// The same Dock PID for `quiet` seconds (gives up after 20 s and returns the last PID).
func settle(quiet: Double = 3) -> Int32? {
    var last = dockPID(), since = Date()
    let end = Date().addingTimeInterval(20)
    while Date() < end {
        usleep(100_000)
        let now = dockPID()
        if now == nil || now != last { last = now; since = Date(); continue }
        if Date().timeIntervalSince(since) >= quiet { return now }
    }
    return last
}

func readApps() -> [[String: Any]] {
    CFPreferencesAppSynchronize(domain)
    return CFPreferencesCopyAppValue(appsKey, domain) as? [[String: Any]] ?? []
}

func writeApps(_ apps: [[String: Any]]) {
    CFPreferencesSetAppValue(appsKey, apps as CFArray, domain)
    CFPreferencesAppSynchronize(domain)
}

/// Entries carrying the stub's bundle id, matched by `tile-data.bundle-identifier` — the key the
/// app's checks rely on, so this also proves the Dock keeps it when it writes its list back.
func stubCount(_ apps: [[String: Any]]) -> Int {
    apps.filter { ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String == stubID }.count
}

// The stub bundle. The Dock draws a pinned bundle without launching it.
let stub = work.appendingPathComponent("KillCheck.app", isDirectory: true)
try FileManager.default.createDirectory(at: stub.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
try "#!/bin/sh\nexec /bin/sleep 1\n".write(to: stub.appendingPathComponent("Contents/MacOS/stub"), atomically: true, encoding: .utf8)
_ = run("/bin/chmod", ["+x", stub.appendingPathComponent("Contents/MacOS/stub").path])
let plist: [String: Any] = ["CFBundleName": "KillCheck", "CFBundleIdentifier": stubID, "CFBundlePackageType": "APPL",
                            "CFBundleExecutable": "stub", "CFBundleIconFile": "AppIcon", "LSUIElement": true]
try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    .write(to: stub.appendingPathComponent("Contents/Info.plist"))

// A saturated icon. Without one the Dock draws the generic app icon, which on macOS 15 is
// near-white on the bar, and the measurer (columns that differ from the bar) cannot see it: the
// first CI run counted 18 icons with the stub plainly pinned (2026-10-29).
let resources = stub.appendingPathComponent("Contents/Resources", isDirectory: true)
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
let iconPNG = work.appendingPathComponent("KillCheck-icon.png")
let iconRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: iconRep)
NSColor(srgbRed: 0.9, green: 0.15, blue: 0.15, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 50, y: 50, width: 412, height: 412), xRadius: 92, yRadius: 92).fill()
NSGraphicsContext.restoreGraphicsState()
try iconRep.representation(using: .png, properties: [:])!.write(to: iconPNG)
guard run("/usr/bin/sips", ["-s", "format", "icns", iconPNG.path, "--out", resources.appendingPathComponent("AppIcon.icns").path]).status == 0 else {
    print("dock-kill-check: could not make the stub icon — the Dock capture could not see the stub, failing"); exit(1)
}

func stubEntry() -> [String: Any] {
    ["GUID": Int.random(in: 1...Int(Int32.max)), "tile-type": "file-tile",
     "tile-data": ["bundle-identifier": stubID, "file-label": "KillCheck", "file-type": 41,
                   "file-data": ["_CFURLString": stub.absoluteString, "_CFURLStringType": 15]] as [String: Any]]
}

func withStub(_ present: Bool) -> [[String: Any]] {
    let others = readApps().filter { ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String != stubID }
    return present ? others + [stubEntry()] : others
}

/// App-icon count of the running Dock, or nil when it can't be measured. The measurer's stderr
/// (its reason, e.g. "INCONCLUSIVE: no Dock window found") goes to the log, so an "unavailable"
/// capture says why.
func capturedCount(_ name: String) -> Int? {
    let r = run("/usr/bin/swift", [measure, work.appendingPathComponent(name).path, "--count-only"], passStderr: true)
    return r.status == 0 ? Int(r.out) : nil
}

enum DockSignal { case kill, term }

func restartDock(_ signal: DockSignal) {
    switch signal {
    case .kill: run("/usr/bin/killall", ["-KILL", "Dock"])
    case .term: run("/usr/bin/killall", ["Dock"])
    }
}

// Evidence: the Dock agent's KeepAlive policy, and the OS.
print(run("/bin/launchctl", ["print", "gui/\(getuid())/com.apple.Dock.agent"]).out
    .split(separator: "\n").filter { $0.localizedCaseInsensitiveContains("keepalive") || $0.contains("state =") || $0.contains("successful") }
    .joined(separator: "\n"))
print(run("/usr/bin/sw_vers", []).out)

// Setup: a visible, unmagnified Dock without the stub, then the baseline icon count.
run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", "false"])
run("/usr/bin/defaults", ["write", "com.apple.dock", "magnification", "-bool", "false"])
writeApps(withStub(false))
restartDock(.kill)
_ = waitForNewDock(old: nil, timeout: 10)
_ = settle()
sleep(5)
guard let baseline = capturedCount("baseline.png") else {
    print("dock-kill-check: baseline capture unavailable — cannot measure, failing"); exit(1)
}
print("app icons at baseline: \(baseline)")

/// One trial: restart the Dock with `prior` (standing in for the launch migration's restart), wait
/// `gap`, write the stub present/absent, restart the Dock with `signal`, then check plist and Dock.
struct Outcome { let plistOK: Bool; let capture: String; let pids: String }
func trial(_ label: String, gap: Double, writePresent: Bool, expectPresent: Bool, prior: DockSignal, signal: DockSignal) -> Outcome {
    let before = dockPID()
    restartDock(prior)
    guard let fresh = waitForNewDock(old: before) else { return Outcome(plistOK: false, capture: "FAIL", pids: "no Dock after the prior restart") }
    usleep(UInt32(gap * 1_000_000))
    writeApps(withStub(writePresent))
    let killed = dockPID() ?? fresh
    restartDock(signal)
    guard let next = waitForNewDock(old: killed) else { return Outcome(plistOK: false, capture: "FAIL", pids: "pid \(killed) → none within 5 s") }

    let expectedEntries = expectPresent ? 1 : 0
    _ = settle()
    let earlyOK = stubCount(readApps()) == expectedEntries
    sleep(5)  // past the new Dock's own write-back (§6), like dock-check.sh's 8 s
    let lateOK = stubCount(readApps()) == expectedEntries

    let capture: String
    if let n = capturedCount("\(label).png") {
        capture = (n == baseline + expectedEntries) ? "ok" : "FAIL (\(n) icons)"
    } else {
        capture = "unavailable"
    }
    return Outcome(plistOK: earlyOK && lateOK, capture: capture, pids: "pid \(killed) → \(next)")
}

// Six counted trials, in the order the plan names them. Trial 3 is the negative control's target.
let trials: [(gap: Double, add: Bool, expectPresent: Bool)] = [
    (0.5, true, true), (0.5, false, false),
    (2.5, true, true), (2.5, false, false),
    (10, true, true), (10, false, false),
]
var passed = 0
for (i, t) in trials.enumerated() {
    let n = i + 1
    let o = trial("trial-\(n)", gap: t.gap, writePresent: t.add, expectPresent: t.expectPresent, prior: .kill, signal: .kill)
    let ok = o.plistOK && o.capture == "ok"
    if ok { passed += 1 }
    print("trial \(n) (gap \(t.gap) s, \(t.add ? "add" : "remove")): plist: \(o.plistOK ? "ok" : "FAIL") capture: \(o.capture) \(o.pids) \(ok ? "OK" : "FAIL")")
    fflush(stdout)
}

// Control, reported but not counted: §6's arm A exactly (a SIGTERM restart, then write, then
// SIGTERM), which lost 14/14 writes within 2.5 s on macOS 27. Three runs, add / remove / add.
let controls: [(gap: Double, add: Bool)] = [(0.5, true), (0.5, false), (2.5, true)]
var lost = 0
for (i, c) in controls.enumerated() {
    let o = trial("control-\(i + 1)", gap: c.gap, writePresent: c.add, expectPresent: c.add, prior: .term, signal: .term)
    let kept = o.plistOK && o.capture == "ok"
    if !kept { lost += 1 }
    print("control \(i + 1) (SIGTERM, gap \(c.gap) s, \(c.add ? "add" : "remove")): \(kept ? "kept" : "lost") — plist: \(o.plistOK ? "ok" : "FAIL") capture: \(o.capture) \(o.pids)")
    fflush(stdout)
}
print("control (SIGTERM, §6 arm A): lost \(lost)/\(controls.count)")
if lost == 0 { print("NOTE: this runner did not reproduce the race; the SIGKILL passes prove only that the Dock relaunches with our write") }

// Cleanup: the stub out of the Dock (write, then SIGKILL).
writeApps(withStub(false))
let last = dockPID()
restartDock(.kill)
_ = waitForNewDock(old: last, timeout: 10)

print("dock-kill-check: \(passed)/\(trials.count) OK")
exit(passed == trials.count ? 0 : 1)
