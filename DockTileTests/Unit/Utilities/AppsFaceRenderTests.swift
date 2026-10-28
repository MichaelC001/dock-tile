//  AppsFaceRenderTests.swift — pixel guards for the Apps face through the REAL renderers
//  (generateAppsLayerPNG → drawAppsGrid → AppsFaceGrid), in the style of GlyphLayerRenderTests.
import AppKit
import SwiftUI
import Testing
@testable import Dock_Tile

@MainActor
@Suite("Apps face rendering")
struct AppsFaceRenderTests {
    static let canvas = 1024
    /// The tile shape in a FLAT bake (fallback .icns, macOS 15 variants): the canvas inset by the
    /// icon-grid margin, because a flat icon must carry its own margin.
    static let shape = CGRect(x: 100, y: 100, width: 824, height: 824)   // 1024 inset by 25/256
    /// The tile shape in the compiled .icon LAYER: the whole canvas. In an Icon Composer document
    /// the 1024 canvas IS the tile — the system adds the icon-grid margin when it renders — so
    /// insetting the layer as well shrank every mini by 0.805 (measured in the Dock, 2026-10-19).
    static let layerShape = CGRect(x: 0, y: 0, width: 1024, height: 1024)

    /// A stand-in app icon: an opaque squircle on Apple's icon grid (transparent margin) — or
    /// full-bleed, which is what a Finder folder glyph's bounds look like to the renderer.
    static func mini(_ colour: NSColor, fullBleed: Bool = false, side: Int = 256) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = CGSize(width: side, height: side)
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        let full = CGRect(x: 0, y: 0, width: side, height: side)
        let inset = fullBleed ? 0 : CGFloat(side) * IconDepthMetrics.contentInsetRatio
        let r = full.insetBy(dx: inset, dy: inset)
        ctx.cgContext.clear(full)
        ctx.cgContext.addPath(RoundedRectangle(cornerRadius: r.width * 0.225, style: .continuous).path(in: r).cgPath)
        ctx.cgContext.setFillColor(colour.cgColor)
        ctx.cgContext.fillPath()
        let image = NSImage(size: rep.size); image.addRepresentation(rep); return image
    }

    static func bitmap(_ png: Data) throws -> NSBitmapImageRep { try #require(NSBitmapImageRep(data: png)) }

    /// Centre of cell `i` for `count` items, in y-down pixel coordinates of the 1024 canvas, on
    /// the flat-bake shape by default or the given one (`layerShape` for the .icon layer).
    static func centre(_ i: Int, count: Int, in shape: CGRect = shape) -> (x: Int, y: Int) {
        let r = AppsFaceGrid.rect(AppsFaceGrid.cells(count: count)[i], in: shape, yUp: false)
        return (Int(r.midX), Int(r.midY))
    }

    static func alpha(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
        rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
    }

    /// Width of the opaque run along row `y` starting from the first opaque pixel at or after `fromX`.
    static func opaqueRun(_ rep: NSBitmapImageRep, y: Int, fromX: Int) -> Int {
        var x = fromX
        while x < rep.pixelsWide, alpha(rep, x, y) < 0.5 { x += 1 }
        let start = x
        while x < rep.pixelsWide, alpha(rep, x, y) >= 0.5 { x += 1 }
        return x - start
    }

    @Test("oneAppSitsTopLeftInATwoByTwo: one app paints the 2×2's top-left cell of the WHOLE layer canvas; the other three cells stay glass")
    func oneAppSitsTopLeftInATwoByTwo() throws {
        let rep = try Self.bitmap(try IconGenerator.generateAppsLayerPNG(
            minis: [.init(image: Self.mini(.systemBlue), isFolder: false)]))
        #expect(rep.pixelsWide == Self.canvas && rep.pixelsHigh == Self.canvas)
        for (x, y) in [(2, 2), (1021, 2), (2, 1021), (1021, 1021), (512, 512)] {
            #expect(Self.alpha(rep, x, y) == 0, "(\(x),\(y)) painted")
        }
        // Independent pins: the top-left 2×2 cell spans 102…494 on 1024 (0.10 + 0.3825), centre 298.
        let c0 = Self.centre(0, count: 1, in: Self.layerShape)
        #expect(abs(c0.x - 298) <= 1 && abs(c0.y - 298) <= 1, "one app is not in the top-left cell: \(c0)")
        #expect(Self.alpha(rep, c0.x, c0.y) == 1)
        for i in 1...3 {
            let c = Self.centre(i, count: 4, in: Self.layerShape)
            #expect(Self.alpha(rep, c.x, c.y) == 0, "cell \(i) is not empty glass")
        }
        let run = Self.opaqueRun(rep, y: c0.y, fromX: 0)
        #expect(abs(run - 392) <= 4, "visible squircle is \(run) px, a 2×2 cell of 1024 is 392")
    }

    @Test("Two apps paint the top row of a 2×2 and leave the bottom row glass")
    func twoAppsPaintTheTopRow() throws {
        let rep = try Self.bitmap(try IconGenerator.generateAppsLayerPNG(
            minis: (0..<2).map { _ in .init(image: Self.mini(.systemBlue), isFolder: false) }))
        for i in 0...1 { let c = Self.centre(i, count: 2, in: Self.layerShape); #expect(Self.alpha(rep, c.x, c.y) == 1, "cell \(i) empty") }
        for i in 2...3 { let c = Self.centre(i, count: 4, in: Self.layerShape); #expect(Self.alpha(rep, c.x, c.y) == 0, "cell \(i) is not empty glass") }
        let c0 = Self.centre(0, count: 2, in: Self.layerShape)
        #expect(c0.x == 298 && c0.y == 298)                     // independent pin of the 2×2 origin: (0.10 + 0.3825/2) × 1024
    }

    @Test("The visible squircle lands on the cell: an app's margin is absorbed by the ÷0.805 box")
    func appSquircleFillsItsCell() throws {
        let rep = try Self.bitmap(try IconGenerator.generateAppsLayerPNG(
            minis: (0..<2).map { _ in .init(image: Self.mini(.systemRed), isFolder: false) }))
        let c0 = Self.centre(0, count: 2, in: Self.layerShape)
        let expected = Int(AppsFaceGrid.cellRatio(columns: 2) * Self.layerShape.width)   // 391
        #expect(expected == 391)
        let run = Self.opaqueRun(rep, y: c0.y, fromX: 0)
        #expect(abs(run - expected) <= 4, "visible squircle is \(run) px, cell is \(expected)")
    }

    @Test("folderMiniFitsItsCell: a full-bleed folder glyph is fitted to the cell, not enlarged")
    func folderMiniFitsItsCell() throws {
        let rep = try Self.bitmap(try IconGenerator.generateAppsLayerPNG(
            minis: [.init(image: Self.mini(.systemOrange, fullBleed: true), isFolder: true)]))
        // One item sits in the 2×2's top-left cell: 392 px (0.3825 × 1024), centre row y ≈ 298.
        let run = Self.opaqueRun(rep, y: 298, fromX: 0)
        #expect(abs(run - 392) <= 4, "folder drew \(run) px; fitted to the 392 px cell, not the 487 px app box")
    }

    @Test("Nine apps fill a 3×3; a tenth is dropped; adjacent minis do not touch")
    func nineAppsFillTheGrid() throws {
        let minis = (0..<10).map { _ in IconGenerator.AppsFaceMini(image: Self.mini(.systemGreen), isFolder: false) }
        let rep = try Self.bitmap(try IconGenerator.generateAppsLayerPNG(minis: minis))
        for i in 0..<9 {
            let c = Self.centre(i, count: 9, in: Self.layerShape)
            #expect(Self.alpha(rep, c.x, c.y) == 1, "cell \(i) empty")
        }
        // The gap between cell 0 and cell 1 (midpoint of the gap, on the cells' centre row) is glass:
        // a mini body is alpha 1; only the two 0.35-alpha shadows can feather into the 36 px gap.
        let a = AppsFaceGrid.rect(AppsFaceGrid.cells(count: 9)[0], in: Self.layerShape, yUp: false)
        let b = AppsFaceGrid.rect(AppsFaceGrid.cells(count: 9)[1], in: Self.layerShape, yUp: false)
        #expect(Self.alpha(rep, Int((a.maxX + b.minX) / 2), Int(a.midY)) < 0.3)
    }

    @Test("Five apps on a 3×3 leave the bottom row's last two cells and the whole third row empty")
    func fiveAppsAreAnL() throws {
        let minis = (0..<5).map { _ in IconGenerator.AppsFaceMini(image: Self.mini(.systemIndigo), isFolder: false) }
        let rep = try Self.bitmap(try IconGenerator.generateAppsLayerPNG(minis: minis))
        for i in 0..<5 { let c = Self.centre(i, count: 9, in: Self.layerShape); #expect(Self.alpha(rep, c.x, c.y) == 1) }
        for i in 5..<9 { let c = Self.centre(i, count: 9, in: Self.layerShape); #expect(Self.alpha(rep, c.x, c.y) == 0) }
    }

    @Test("miniCastsAContactShadow: soft shadow below a mini, none above it")
    func miniCastsAContactShadow() throws {
        let rep = try Self.bitmap(try IconGenerator.generateAppsLayerPNG(
            minis: [.init(image: Self.mini(.white, fullBleed: true), isFolder: true)]))   // full-bleed: the body reaches the cell edge
        let cell = AppsFaceGrid.rect(AppsFaceGrid.cells(count: 1)[0], in: Self.layerShape, yUp: false)
        let below = Self.alpha(rep, Int(cell.midX), Int(cell.maxY) + 5)
        let above = Self.alpha(rep, Int(cell.midX), Int(cell.minY) - 5)
        #expect(below > 0.05 && below < 0.4, "shadow below: \(below)")
        // The shadow is OFFSET downward (6 px at 1024), so the row 5 px above the mini carries far
        // less of it than the row 5 px below — a relative check that a blur-radius detail can't trip.
        #expect(above < below / 2, "shadow above \(above) vs below \(below)")
        let shadowColour = try #require(rep.colorAt(x: Int(cell.midX), y: Int(cell.maxY) + 5)?.usingColorSpace(.sRGB))
        #expect(shadowColour.brightnessComponent < 0.2)       // black, not a smeared mini
    }

    // MARK: - Fallback .icns and the legacy bake (same renderer, four styles)

    static func gray(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) throws -> CGFloat {
        // One colour-managed read for every rep: draw it into an sRGB RGBA context and read the
        // byte, which is what the Dock sees. `colorAt` is not used: it goes through the rep's
        // `colorSpaceName`, which mislabels a file-decoded rep and shifts the gray.
        let cg = try #require(rep.cgImage)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var px = [UInt8](repeating: 0, count: 4)
        try px.withUnsafeMutableBytes { buf in
            let ctx = try #require(CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                             bytesPerRow: 4, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: CGRect(x: -x, y: -(cg.height - 1 - y), width: cg.width, height: cg.height))
        }
        #expect(abs(Int(px[0]) - Int(px[1])) <= 1 && abs(Int(px[1]) - Int(px[2])) <= 1,
                "not gray at (\(x),\(y)): \(px)")
        return CGFloat(px[0]) / 255
    }

    static func bake(_ style: IconStyle, minis: [IconGenerator.AppsFaceMini]) throws -> NSBitmapImageRep {
        let image = IconGenerator.appsIcon(minis: minis, size: CGSize(width: canvas, height: canvas), iconStyle: style,
                                            background: .automatic, customHex: ConfigurationDefaults.appsBackgroundColor)
        return try #require(image.representations.compactMap { $0 as? NSBitmapImageRep }.first)
    }

    @Test("Every style bakes the icon-grid margin and the system gray pair, top stop at the top",
          arguments: IconStyle.allCases)
    func bakeIsMarginedOnSystemGrays(_ style: IconStyle) throws {
        let rep = try Self.bake(style, minis: [.init(image: Self.mini(.systemBlue), isFolder: false)])
        #expect(Self.alpha(rep, 1, 512) == 0, "\(style): mid-edge painted — no margin")
        #expect(Self.alpha(rep, 512, 512) == 1)
        let run = Self.opaqueRun(rep, y: 512, fromX: 0)
        #expect(abs(run - 824) <= 2, "\(style): shape is \(run) px wide")
        let expected = AppsFaceGrid.fillGrays(style: style)
        #expect(abs(try Self.gray(rep, 512, 106) - expected.top) < 0.02, "\(style) top")
        #expect(abs(try Self.gray(rep, 512, 917) - expected.bottom) < 0.02, "\(style) bottom")
    }

    @Test("Dark is the dark pair, Default the light pair — independent pins")
    func grayPairsPinned() throws {
        let dark = try Self.bake(.dark, minis: [])
        #expect(abs(try Self.gray(dark, 512, 106) - 0.192) < 0.02)
        #expect(abs(try Self.gray(dark, 512, 917) - 0.078) < 0.02)
        let light = try Self.bake(.defaultStyle, minis: [])
        #expect(try Self.gray(light, 512, 106) > 0.98)
        #expect(abs(try Self.gray(light, 512, 917) - 0.925) < 0.02)
    }

    @Test("clearAndTintedVariantsDesaturateMinis: Default/Dark keep the mini's colour, Clear/Tinted are grayscale")
    func clearAndTintedVariantsDesaturateMinis() throws {
        let red = IconGenerator.AppsFaceMini(image: Self.mini(.systemRed, fullBleed: true), isFolder: true)
        let c0 = Self.centre(0, count: 1)
        for style in IconStyle.allCases {
            let c = try #require(try Self.bake(style, minis: [red]).colorAt(x: c0.x, y: c0.y)?.usingColorSpace(.sRGB))
            #expect(c.alphaComponent == 1)
            if AppsFaceGrid.desaturatesMinis(style: style) {
                #expect(c.saturationComponent < 0.05, "\(style) mini still coloured: \(c)")
            } else {
                #expect(c.saturationComponent > 0.6, "\(style) mini lost its colour: \(c)")
            }
        }
    }

    @Test("The written fallback .icns carries the margin and the light pair in its largest rendition")
    func fallbackIcnsFile() throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("docktile-apps-\(UUID().uuidString).icns")
        defer { try? FileManager.default.removeItem(at: out) }
        try IconGenerator.generateAppsFallbackIcns(
            minis: [.init(image: Self.mini(.systemBlue), isFolder: false)], outputURL: out,
            background: .automatic, customHex: ConfigurationDefaults.appsBackgroundColor)
        let image = try #require(NSImage(contentsOf: out))
        let rep = try #require(image.representations.compactMap { $0 as? NSBitmapImageRep }.max(by: { $0.pixelsWide < $1.pixelsWide }))
        #expect(rep.pixelsWide == 1024)
        #expect(Self.alpha(rep, 1, 512) == 0)
        #expect(try Self.gray(rep, 512, 106) > 0.98)
    }

    @Test("The legacy variant file is written for a non-default style")
    func legacyVariantFile() throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("docktile-apps-dark-\(UUID().uuidString).icns")
        defer { try? FileManager.default.removeItem(at: out) }
        try IconGenerator.generateAppsIcns(minis: [.init(image: Self.mini(.systemBlue), isFolder: false)],
                                           outputURL: out, iconStyle: .dark,
                                           background: .automatic, customHex: ConfigurationDefaults.appsBackgroundColor)
        let image = try #require(NSImage(contentsOf: out))
        let rep = try #require(image.representations.compactMap { $0 as? NSBitmapImageRep }.max(by: { $0.pixelsWide < $1.pixelsWide }))
        #expect(abs(try Self.gray(rep, 512, 106) - 0.192) < 0.02)
    }

    /// Like a real `NSWorkspace.icon(forFile:)` result: small point size, large detailed rep.
    static func stripedMini(rep pixels: Int = 512, stripe: Int = 4) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = CGSize(width: pixels, height: pixels)
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        ctx.cgContext.setFillColor(NSColor.white.cgColor)
        ctx.cgContext.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        ctx.cgContext.setFillColor(NSColor.systemRed.cgColor)
        var x = 0
        while x < pixels { ctx.cgContext.fill(CGRect(x: x, y: 0, width: stripe, height: pixels)); x += stripe * 2 }
        let image = NSImage(size: CGSize(width: 32, height: 32))   // points, as IconServices returns
        // Low-res reps (plain white) like the 1x/2x ones IconServices attaches: a rasterise at the
        // image's point size picks one of these; only the destination-sized draw reaches `rep`.
        for px in [32, 64] {
            let small = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            small.size = CGSize(width: 32, height: 32)
            let sctx = NSGraphicsContext(bitmapImageRep: small)!
            sctx.cgContext.setFillColor(NSColor.white.cgColor)
            sctx.cgContext.fill(CGRect(x: 0, y: 0, width: px, height: px))
            image.addRepresentation(small)
        }
        rep.size = CGSize(width: 32, height: 32)
        image.addRepresentation(rep)
        return image
    }

    @Test("desaturated minis keep the detail of a small-point-size, large-bitmap icon")
    func desaturatedMiniIsNotBlurry() throws {
        let rep = try Self.bake(.clear, minis: [.init(image: Self.stripedMini(), isFolder: true)])
        let c = Self.centre(0, count: 1)
        // Walk 300 px across the box centre; every 4-px stripe (8 px at 1024) must still alternate.
        var flips = 0
        var previousDark: Bool?
        for x in (c.x - 150)..<(c.x + 150) {
            let v = try #require(rep.colorAt(x: x, y: c.y)?.usingColorSpace(.sRGB)).redComponent
            let dark = v < 0.65   // red stripes in gray ~0.3-0.4, white 1.0, blur ~0.7
            if let p = previousDark, p != dark { flips += 1 }
            previousDark = dark
        }
        #expect(flips >= 30, "stripes smeared: only \(flips) edges across 300 px")
    }

    @Test("emptyGridLayerDrawsFourSlots: no minis bake the empty 2×2 — faint slots in the cells, nothing elsewhere")
    func emptyGridLayerDrawsFourSlots() throws {
        for dark in [false, true] {
            let rep = try Self.bitmap(try IconGenerator.generateAppsLayerPNG(minis: [], onDarkGlass: dark))
            #expect(Self.alpha(rep, 512, 512) == 0, "the gap between the cells is painted")
            #expect(Self.alpha(rep, 2, 2) == 0)
            for i in 0..<4 {
                let c = Self.centre(i, count: 4, in: Self.layerShape)
                let a = Self.alpha(rep, c.x, c.y)
                #expect(abs(a - (dark ? 0.10 : 0.07)) < 0.02, "slot \(i) alpha \(a) (dark: \(dark))")
            }
        }
    }
}
