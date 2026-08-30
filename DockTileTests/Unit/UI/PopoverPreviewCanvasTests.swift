//  PopoverPreviewCanvasTests.swift — guards the hero zoom rule: fit the worst-case panel with a
//  margin, boost 10%, never exceed the flush fit or 1.04 (so the panel can't clip or zoom in).
import Testing
import Foundation
@testable import Dock_Tile

@Suite("PopoverPreviewCanvas fit scale")
struct PopoverPreviewCanvasTests {
    @Test("Roomy hero: boosted fit wins, capped at 1.04")
    func roomyCapsAtMaxZoom() {
        let s = PopoverPreviewCanvas.fitScale(available: CGSize(width: 1000, height: 1000), worst: CGSize(width: 200, height: 100))
        #expect(s == 1.04)
    }
    @Test("Tight hero: the flush fit clamps the boosted fit")
    func tightClampsToRawFit() {
        let s = PopoverPreviewCanvas.fitScale(available: CGSize(width: 300, height: 300), worst: CGSize(width: 292, height: 100))
        // rawFit = (300-8)/292 = 1.0 ; fit = (300-56)/292 = 0.8356 → ×1.10 = 0.919 → min = 0.919
        #expect(abs(s - 0.9191) < 0.001)
    }
    @Test("Height-bound hero uses the height axis")
    func heightBound() {
        let s = PopoverPreviewCanvas.fitScale(available: CGSize(width: 1000, height: 144), worst: CGSize(width: 100, height: 100))
        // fit = (144-44)/100 = 1.0 → 1.1 ; rawFit = (144-8)/100 = 1.36 ; cap 1.04 → 1.04
        #expect(s == 1.04)
    }

    // MARK: - `.natural` fit (Tile Detail editor) — must never overflow the fixed-width window

    @Test("Default grid, 6 apps: intrinsic size mirrors the real panel's own frame maths")
    func naturalGridPanelSize() {
        let size = PopoverPreviewCanvas.naturalPanelSize(
            layout: .grid, appCount: 6, settings: .default, includesUtilityRows: false)
        // 5 cols x 82pt cell + 4 x 14pt gap + 32pt padding = 498 ; 36 header + 2 x 78 + 14 + 32 = 238
        #expect(size == CGSize(width: 498, height: 238))
    }

    @Test("Default list, 6 apps in the editor: no utility rows in the height")
    func naturalListPanelSize() {
        let size = PopoverPreviewCanvas.naturalPanelSize(
            layout: .list, appCount: 6, settings: .default, includesUtilityRows: false)
        // 32 header + 6 x 36 row + 16 vertical padding = 264
        #expect(size == CGSize(width: 240, height: 264))
    }

    @Test("Empty list in the editor: sized for the edit-mode empty state, not a phantom row")
    func naturalListPanelSizeEmpty() {
        let size = PopoverPreviewCanvas.naturalPanelSize(
            layout: .list, appCount: 0, settings: .default, includesUtilityRows: false)
        // 32 header + 32 empty-state vertical padding + 30 two-line text + 16 outer padding = 110
        #expect(size == CGSize(width: 240, height: 110))
    }

    @Test("A panel wider than the detail column scales DOWN to fit flush")
    func naturalScaleShrinksOverflowingPanel() {
        let s = PopoverPreviewCanvas.naturalScale(availableWidth: 488, panelWidth: 498)
        // (488 - 2 x 22 inset) / 498
        #expect(abs(s - 0.891566) < 0.0001)
    }

    @Test("A panel that already fits renders 1:1 — never blown up")
    func naturalScaleNeverUpscales() {
        #expect(PopoverPreviewCanvas.naturalScale(availableWidth: 488, panelWidth: 210) == 1)
    }

    @Test("Before the first layout pass (no proposal yet) the fit falls back to 1:1")
    func naturalScaleWithoutProposal() {
        #expect(PopoverPreviewCanvas.naturalScale(availableWidth: 0, panelWidth: 498) == 1)
    }
}
