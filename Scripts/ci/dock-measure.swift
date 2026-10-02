// Companion to Scripts/ci/dock-check.sh, also safe to run locally. Captures the Dock's own window
// (by window ID — never a screen rect, so nothing else on screen can be photographed), finds the
// bar as the opaque region of that capture, scans the bar's centre row for runs of pixels that
// differ from the bar surface, and fails when any icon is materially wider than the median — the
// signature of a tile drawn full-bleed instead of on Apple's icon grid (1.24× its neighbours in
// the 2.0.2 macOS 15 report). Works for a bottom Dock on macOS 15 (window = the bar) and on
// macOS 26/27 (window = full screen, bar floating inside it) alike.
//
// Usage: swift dock-measure.swift <capture-out.png>
import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count == 2 else { print("usage: dock-measure <capture-out.png>"); exit(2) }
let out = args[1]

// 1. The Dock's main window: owned by "Dock", window layer 20, the widest one.
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let dockWindows = info.filter { ($0[kCGWindowOwnerName as String] as? String) == "Dock"
    && ($0[kCGWindowLayer as String] as? Int) == 20 }
func width(_ w: [String: Any]) -> CGFloat { (w[kCGWindowBounds as String] as? [String: CGFloat])?["Width"] ?? 0 }
guard let dock = dockWindows.max(by: { width($0) < width($1) }),
      let windowID = dock[kCGWindowNumber as String] as? Int else {
    print("INCONCLUSIVE: no Dock window found"); exit(0)
}
print("Dock window id \(windowID), bounds \(dock[kCGWindowBounds as String] ?? [:])")

// 2. Capture that one window.
let capture = Process()
capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
capture.arguments = ["-x", "-o", "-l\(windowID)", out]
try capture.run(); capture.waitUntilExit()
guard capture.terminationStatus == 0, let img = NSImage(contentsOfFile: out),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("INCONCLUSIVE: screencapture failed (status \(capture.terminationStatus))"); exit(0)
}
let rep = NSBitmapImageRep(cgImage: cg)
let w = rep.pixelsWide, h = rep.pixelsHigh
func alpha(_ x: Int, _ y: Int) -> CGFloat { rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 }
func rgb(_ x: Int, _ y: Int) -> [CGFloat] {
    let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    return [c?.redComponent ?? 0, c?.greenComponent ?? 0, c?.blueComponent ?? 0]
}

// 3. The bar = the opaque bounding box of the capture (sampled on a 2 px grid for speed).
var minX = w, maxX = 0, minY = h, maxY = 0
for y in stride(from: 0, to: h, by: 2) {
    for x in stride(from: 0, to: w, by: 2) where alpha(x, y) > 0.05 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX > minX, maxY > minY else { print("INCONCLUSIVE: capture is fully transparent"); exit(0) }
print("capture \(w)x\(h) px, bar x \(minX)-\(maxX) y \(minY)-\(maxY) (\(maxX - minX + 1)x\(maxY - minY + 1) px)")
let scale = CGFloat(w) / (NSScreen.main?.frame.width ?? CGFloat(w))

// 4. Scan the bar's centre row; the surface colour is the bar's own left padding.
let row = (minY + maxY) / 2
let surface = rgb(minX + 6, row)
var runs: [(start: Int, end: Int)] = []
var start: Int? = nil
for x in minX...maxX {
    let diff = zip(rgb(x, row), surface).map { abs($0 - $1) }.reduce(0, +)
    if diff > 0.12 { if start == nil { start = x } }
    else if let s = start { if x - s >= Int(12 * scale) { runs.append((s, x - 1)) }; start = nil }
}
if let s = start, maxX - s >= Int(12 * scale) { runs.append((s, maxX)) }
let widths = runs.map { $0.end - $0.start + 1 }
print("icon runs along the bar (px): \(widths)")
guard widths.count >= 4 else { print("INCONCLUSIVE: only \(widths.count) icons found"); exit(0) }

// 5. Verdict. The median is the neighbours; a full-bleed tile would be the outlier at ~1.24×.
let sorted = widths.sorted()
let median = CGFloat(sorted[sorted.count / 2])
let widest = CGFloat(sorted.last!)
let ratio = widest / median
print(String(format: "median %.0f px, widest %.0f px, ratio %.3f (a full-bleed tile reads ~1.24)", median, widest, ratio))
if ratio > 1.10 { print("FAIL: an icon is \(ratio)× the median width"); exit(1) }
print("PASS: every Dock icon is within 10 % of the median width")
