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
}
