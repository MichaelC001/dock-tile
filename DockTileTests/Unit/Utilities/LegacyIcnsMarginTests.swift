//
//  LegacyIcnsMarginTests.swift
//  DockTileTests
//
//  The pre-macOS-26 bake (`IconGenerator.generateIcon` / `generateIcns`, the only icon a
//  macOS 15 helper has) must sit on Apple's icon grid like every neighbouring Dock icon: the
//  shape occupies 206/256 of the canvas and the rest is transparent margin. It shipped
//  full-bleed instead, so a macOS 15 Dock drew the tile ~24 % larger than the icons beside it
//  (feedback 2026-09-30, measured 114 px vs 90 px). The Tahoe fallback `.icns` already bakes
//  the margin (`GlyphLayerRenderTests.fallbackIcnsIsMargined`); these pin the legacy bake to the
//  same geometry. Each would fail again for a full-bleed shape: the mid-edge turns opaque and the
//  opaque extent grows from 824 px to 1024 px.
//

import Testing
import AppKit
import SwiftUI
@testable import Dock_Tile

@MainActor
@Suite("Legacy .icns icon-grid margin")
struct LegacyIcnsMarginTests {

    /// 512@2x — the largest rendition, and the one the Dock scales from.
    private static let px = 1024
    /// Apple's icon grid: 206 of 256 → 824 of 1024.
    private static let gridExtent = Int((1 - 2 * IconDepthMetrics.contentInsetRatio) * CGFloat(px))

    private func bake(style: IconStyle, type: IconType = .sfSymbol, value: String = "square.fill",
                      scale: Int = 14) throws -> NSBitmapImageRep {
        let image = IconGenerator.generateIcon(
            tintColor: .green, iconType: type, iconValue: value, iconScale: scale,
            size: CGSize(width: Self.px, height: Self.px), iconStyle: style)
        return try #require(image.representations.compactMap { $0 as? NSBitmapImageRep }.first)
    }

    /// Alpha straight from the bitmap bytes (RGBA8, as the generator allocates it) — a 1024²
    /// scan through `colorAt` allocates a million NSColors.
    private static func alpha(_ rep: NSBitmapImageRep, x: Int, y: Int) -> UInt8 {
        guard let data = rep.bitmapData else { return 0 }
        let bytesPerPixel = rep.bitsPerPixel / 8
        return data[y * rep.bytesPerRow + x * bytesPerPixel + (bytesPerPixel - 1)]
    }

    /// Width of the opaque run along one row, and height along one column.
    private static func opaqueExtent(_ rep: NSBitmapImageRep) -> (width: Int, height: Int) {
        let mid = rep.pixelsWide / 2
        let row = (0..<rep.pixelsWide).filter { alpha(rep, x: $0, y: mid) >= 128 }
        let column = (0..<rep.pixelsHigh).filter { alpha(rep, x: mid, y: $0) >= 128 }
        return ((row.max() ?? 0) - (row.min() ?? 0) + 1, (column.max() ?? 0) - (column.min() ?? 0) + 1)
    }

    @Test("Every style variant bakes the icon-grid margin", arguments: IconStyle.allCases)
    func legacyBakeIsMargined(_ style: IconStyle) throws {
        let rep = try bake(style: style)
        // Mid-edge, not a corner: a full-bleed squircle's corners are transparent too.
        #expect(Self.alpha(rep, x: 1, y: Self.px / 2) == 0, "\(style): mid-edge is painted — no margin")
        #expect(Self.alpha(rep, x: Self.px / 2, y: Self.px / 2) == 255, "\(style): centre not drawn")

        let extent = Self.opaqueExtent(rep)
        #expect(abs(extent.width - Self.gridExtent) <= 2, "\(style): shape is \(extent.width) px wide, grid is \(Self.gridExtent)")
        #expect(abs(extent.height - Self.gridExtent) <= 2, "\(style): shape is \(extent.height) px tall, grid is \(Self.gridExtent)")
    }

    /// The claim the user actually made: the tile is bigger than the icons beside it. Measure
    /// a real neighbour the same way (Finder's Dock icon at 1024, as IconServices hands it to
    /// the Dock) and require the bake to match it — on every macOS since Big Sur that is the
    /// same 824 px grid, so this holds on the macOS 15 runner as well as 26/27.
    @Test("The bake is the same size as a real neighbouring Dock icon")
    func legacyBakeMatchesSystemIconExtent() throws {
        let finder = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
        finder.size = NSSize(width: Self.px, height: Self.px)
        let cg = try #require(finder.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let neighbour = NSBitmapImageRep(cgImage: cg)
        #expect(neighbour.pixelsWide == Self.px)

        // IconServices hands back a 16-bit-per-channel bitmap, so read it through `colorAt`
        // (format-agnostic) rather than the RGBA8 byte reader the bake's own bitmap allows.
        let mid = Self.px / 2
        let row = (0..<Self.px).filter { (neighbour.colorAt(x: $0, y: mid)?.alphaComponent ?? 0) >= 0.5 }
        let column = (0..<Self.px).filter { (neighbour.colorAt(x: mid, y: $0)?.alphaComponent ?? 0) >= 0.5 }
        let theirs = (width: (row.max() ?? 0) - (row.min() ?? 0) + 1,
                      height: (column.max() ?? 0) - (column.min() ?? 0) + 1)
        let ours = Self.opaqueExtent(try bake(style: .defaultStyle))
        #expect(abs(ours.width - theirs.width) <= 2, "tile \(ours.width) px vs Finder \(theirs.width) px")
        #expect(abs(ours.height - theirs.height) <= 2, "tile \(ours.height) px vs Finder \(theirs.height) px")
    }

    /// Through the real file path, so what lands in `Contents/Resources/AppIcon-*.icns` is what
    /// is asserted — mirrors `fallbackIcnsIsMargined` for the Tahoe fallback.
    @Test("The written .icns carries the margin in its largest rendition")
    func legacyIcnsFileIsMargined() throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("docktile-legacy-\(UUID().uuidString).icns")
        defer { try? FileManager.default.removeItem(at: out) }

        try IconGenerator.generateIcns(
            tintColor: .green, iconType: .sfSymbol, iconValue: "square.fill",
            iconScale: 14, iconWeight: .medium, outputURL: out, iconStyle: .defaultStyle)

        let image = try #require(NSImage(contentsOf: out))
        let rep = try #require(
            image.representations.compactMap { $0 as? NSBitmapImageRep }
                .max(by: { $0.pixelsWide < $1.pixelsWide }))
        #expect(rep.pixelsWide == Self.px)
        let midEdge = try #require(rep.colorAt(x: 1, y: Self.px / 2)?.alphaComponent)
        #expect(midEdge == 0)
        let centre = try #require(rep.colorAt(x: Self.px / 2, y: Self.px / 2)?.alphaComponent)
        #expect(centre == 1)
    }

    /// Glyph geometry stays measured against the full canvas (as the Tahoe fallback and the
    /// layer PNGs do), so the glyph grows relative to the now-smaller shape. The scale
    /// ceilings were derived for exactly this geometry; prove it at the real 1024 bake.
    @Test("Max-scale glyphs stay inside the inset shape", arguments: [
        (IconType.emoji, "🟥"), (IconType.emoji, "🧊"), (IconType.emoji, "🍕"),
        (IconType.sfSymbol, "square.fill"), (IconType.sfSymbol, SFSymbolCatalog.brandSymbolName)
    ])
    func maxScaleGlyphStaysInsideTheInsetShape(_ type: IconType, _ value: String) throws {
        let scale = type == .emoji ? IconDepthMetrics.emojiScaleMax : 19
        let rep = try bake(style: .defaultStyle, type: type, value: value, scale: scale)
        let mask = try #require(Self.insetShapeMask())

        var escaped = 0
        for y in 0..<Self.px {
            for x in 0..<Self.px where Self.alpha(rep, x: x, y: y) >= 64 {
                // The shape's own anti-aliased rim: a pixel the mask covers at all is inside.
                if Self.alpha(mask, x: x, y: y) <= 5 { escaped += 1 }
            }
        }
        #expect(escaped == 0, "\(value) at scale \(scale): \(escaped) painted pixels outside the inset shape")
    }

    /// The icon-grid squircle, filled white, at the same inset the generator must use.
    private static func insetShapeMask() -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let side = CGFloat(px)
        rep.size = CGSize(width: side, height: side)
        let inset = side * IconDepthMetrics.contentInsetRatio
        let shape = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: inset, dy: inset)
        let path = RoundedRectangle(cornerRadius: shape.width * 0.225, style: .continuous)
            .path(in: shape).cgPath
        ctx.cgContext.clear(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.cgContext.addPath(path)
        ctx.cgContext.setFillColor(NSColor.white.cgColor)
        ctx.cgContext.fillPath()
        return rep
    }
}
