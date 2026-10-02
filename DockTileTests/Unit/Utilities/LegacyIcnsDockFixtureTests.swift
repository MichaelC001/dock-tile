//
//  LegacyIcnsDockFixtureTests.swift
//  DockTileTests
//
//  Not a test of behaviour: a fixture writer for the on-demand CI Dock check
//  (`dock-check-macos-15` in ci.yml, `Scripts/ci/dock-check.sh`). It bakes one legacy `.icns`
//  per icon type with the real generator ON THE HOST THAT RUNS IT (a macOS 15 runner), so the
//  Dock there can be shown rendering exactly what a macOS 15 helper ships. Disabled unless
//  `DOCKTILE_ICNS_FIXTURE_DIR` is set (xcodebuild forwards `TEST_RUNNER_DOCKTILE_ICNS_FIXTURE_DIR`),
//  so the normal suite never writes outside its temp dir.
//

import Testing
import Foundation
@testable import Dock_Tile

@MainActor
@Suite("Legacy .icns Dock fixtures (CI dock check only)",
       .enabled(if: ProcessInfo.processInfo.environment["DOCKTILE_ICNS_FIXTURE_DIR"] != nil))
struct LegacyIcnsDockFixtureTests {

    @Test("Writes <dir>/<Name>/AppIcon.icns for a symbol, an emoji and the brand glyph")
    func writeFixtures() throws {
        let dir = URL(fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["DOCKTILE_ICNS_FIXTURE_DIR"]), isDirectory: true)
        let cases: [(String, IconType, String, TintColor)] = [
            ("Symbol", .sfSymbol, "star.fill", .blue),
            ("Emoji", .emoji, "🍕", .green),
            ("Brand", .sfSymbol, SFSymbolCatalog.brandSymbolName, .orange)
        ]
        for (name, type, value, tint) in cases {
            let folder = dir.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let icns = folder.appendingPathComponent("AppIcon.icns")
            try IconGenerator.generateIcns(
                tintColor: tint, iconType: type, iconValue: value,
                iconScale: 14, iconWeight: .medium, outputURL: icns, iconStyle: .defaultStyle)
            let size = try FileManager.default.attributesOfItem(atPath: icns.path)[.size] as? Int ?? 0
            #expect(size > 10_000, "\(name): .icns not written (\(size) bytes)")
        }
    }
}
