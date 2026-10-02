// Companion to Scripts/ci/dock-check.sh, also safe to run locally. Captures the Dock's own window
// (by window ID — never a screen rect, so nothing else on screen can be photographed), finds the
// bar as the opaque region of that capture, finds each app icon as a run of columns that differ
// from the bar surface, and fails when any app icon is materially wider than the median — the
// signature of a tile drawn full-bleed instead of on Apple's icon grid (1.24× its neighbours in
// the 2.0.2 macOS 15 report). Works for a bottom Dock on macOS 15 and on macOS 26/27 alike (the
// Dock window is screen-sized on both; the bar is the only opaque region in it).
//
// Usage: swift dock-measure.swift <capture.png>                 capture the Dock, then measure
//        swift dock-measure.swift <capture.png> --measure-only  measure an existing capture
// Exit: 0 pass · 1 an icon is too wide · 3 inconclusive (a check that cannot measure must not pass)
import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: dock-measure <capture.png> [--measure-only]"); exit(2) }
let out = args[1]
func inconclusive(_ why: String) -> Never { print("INCONCLUSIVE: \(why)"); exit(3) }

if !args.contains("--measure-only") {
    // The Dock's main window: owned by "Dock", window layer 20, the widest one.
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let dockWindows = info.filter { ($0[kCGWindowOwnerName as String] as? String) == "Dock"
        && ($0[kCGWindowLayer as String] as? Int) == 20 }
    func width(_ w: [String: Any]) -> CGFloat { (w[kCGWindowBounds as String] as? [String: CGFloat])?["Width"] ?? 0 }
    guard let dock = dockWindows.max(by: { width($0) < width($1) }),
          let windowID = dock[kCGWindowNumber as String] as? Int else { inconclusive("no Dock window found") }
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-o", "-l\(windowID)", out]
    try capture.run(); capture.waitUntilExit()
    guard capture.terminationStatus == 0 else { inconclusive("screencapture exited \(capture.terminationStatus)") }
    print("captured Dock window \(windowID)")
}

guard let img = NSImage(contentsOfFile: out),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { inconclusive("cannot read \(out)") }
let rep = NSBitmapImageRep(cgImage: cg)
let w = rep.pixelsWide, h = rep.pixelsHigh
func alpha(_ x: Int, _ y: Int) -> CGFloat { rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 }
func rgb(_ x: Int, _ y: Int) -> [CGFloat] {
    let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    return [c?.redComponent ?? 0, c?.greenComponent ?? 0, c?.blueComponent ?? 0]
}

// 1. The bar = the solidly opaque bounding box (alpha > 0.5 skips the bar's soft drop shadow).
var minX = w, maxX = 0, minY = h, maxY = 0
for y in stride(from: 0, to: h, by: 2) {
    for x in stride(from: 0, to: w, by: 2) where alpha(x, y) > 0.5 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX > minX, maxY > minY else { inconclusive("capture has no opaque bar") }
let barHeight = maxY - minY + 1
print("capture \(w)x\(h) px, bar x \(minX)-\(maxX) y \(minY)-\(maxY)")

// 2. A column belongs to an icon when it differs from the bar SURFACE on any row of a band
//    through the icons' middle. The surface is each row's most common colour: the gaps between
//    icons repeat it exactly, no single icon colour does. (Sampling a fixed pixel near the bar's
//    edge read the edge highlight instead and merged the whole row into one run.) The band sits
//    in the icons' LOWER half: a notification badge overhangs an icon's top-right corner and
//    would otherwise read as extra width (Reminders + badge measured 1.105× on a real Dock).
let rows = stride(from: minY + barHeight * 50 / 100, through: minY + barHeight * 72 / 100, by: max(1, barHeight / 24))
var isIcon = [Bool](repeating: false, count: w)
for row in rows {
    var counts: [Int: (count: Int, colour: [CGFloat])] = [:]
    for x in minX...maxX {
        let p = rgb(x, row)
        let key = Int(p[0] * 31) << 10 | Int(p[1] * 31) << 5 | Int(p[2] * 31)
        counts[key] = ((counts[key]?.count ?? 0) + 1, p)
    }
    guard let surface = counts.values.max(by: { $0.count < $1.count })?.colour else { continue }
    for x in minX...maxX where zip(rgb(x, row), surface).map({ abs($0 - $1) }).reduce(0, +) > 0.10 {
        isIcon[x] = true
    }
}
var runs: [(start: Int, end: Int)] = []
var start: Int? = nil
let minRun = max(8, barHeight / 6)   // ignores the separator line and stray pixels
for x in minX...(maxX + 1) {
    if x <= maxX, isIcon[x] { if start == nil { start = x } }
    else if let s = start { if x - s >= minRun { runs.append((s, x - 1)) }; start = nil }
}
guard runs.count >= 4 else { inconclusive("only \(runs.count) icons found") }

// 3. Apps only: the Dock's separator leaves the one gap much larger than the rest; what follows
//    it (stacks, Trash) is not an app icon and a folder stack is legitimately wider.
let gaps = zip(runs, runs.dropFirst()).map { $1.start - $0.end - 1 }
let medianGap = gaps.sorted()[gaps.count / 2]
var apps = runs
if let widestGap = gaps.max(), widestGap > 2 * medianGap, let split = gaps.firstIndex(of: widestGap) {
    apps = Array(runs[...split])
}
let widths = apps.map { $0.end - $0.start + 1 }
print("app icon widths (px), left to right: \(widths)")
if apps.count < runs.count { print("ignored right of the separator: \(runs[apps.count...].map { $0.end - $0.start + 1 })") }

// 4. Verdict. The median is the neighbours; a full-bleed tile would be the outlier at ~1.24×.
let sorted = widths.sorted()
let median = CGFloat(sorted[sorted.count / 2])
let widest = CGFloat(sorted.last!)
let ratio = widest / median
print(String(format: "median %.0f px, widest %.0f px, ratio %.3f (a full-bleed tile reads ~1.24)", median, widest, ratio))
if let widestRun = apps.max(by: { $0.end - $0.start < $1.end - $1.start }) {
    print("widest icon spans x \(widestRun.start)-\(widestRun.end) (icon #\((apps.firstIndex { $0.start == widestRun.start } ?? 0) + 1) from the left)")
}
if ratio > 1.10 { print("FAIL: an app icon is \(ratio)× the median width"); exit(1) }
print("PASS: every app icon in the Dock is within 10 % of the median width")
