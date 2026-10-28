//
//  IconDocumentBuilderTests.swift
//  DockTileTests
//
//  Regression guards for the pure `.icon` document author. Asserts against the exact schema of
//  docs/icon-spike-fixtures/devtile-fix.icon/icon.json — the proven-working fixture that is the
//  only ground truth for this undocumented format.
//

import AppKit
import Foundation
import Testing
@testable import Dock_Tile

@Suite("IconDocumentBuilder JSON shape")
struct IconDocumentBuilderTests {
    private func makeJSON(layers: [IconDocumentBuilder.LayerSpec]) -> [String: Any] {
        IconDocumentBuilder.iconJSON(
            fillTopP3: (0.41961, 0.81176, 0.49804), fillBottomP3: (0.20392, 0.78039, 0.34902),
            darkFillTopP3: (0.10980, 0.10980, 0.11765), darkFillBottomP3: (0.05490, 0.05490, 0.06275),
            tintedFillTopP3: (0.55686, 0.55686, 0.57647), tintedFillBottomP3: (0.42353, 0.42353, 0.43922),
            layers: layers)
    }

    @Test("Top-level fill AND a no-appearance first entry in fill-specializations (defect-1 workaround)")
    func defaultFillIsDuplicatedIntoSpecializations() throws {
        let json = makeJSON(layers: [])
        let fill = try #require(json["fill"] as? [String: Any])
        let stops = try #require(fill["linear-gradient"] as? [String])
        #expect(stops == ["display-p3:0.41961,0.81176,0.49804,1.00000",
                          "display-p3:0.20392,0.78039,0.34902,1.00000"])
        let specs = try #require(json["fill-specializations"] as? [[String: Any]])
        #expect(specs.count == 3)                       // fixture parity: default, dark, tinted
        #expect(specs[0]["appearance"] == nil)          // the default IN the list, first
        #expect(specs[1]["appearance"] as? String == "dark")
        #expect(specs[2]["appearance"] as? String == "tinted")
    }

    @Test("Symbol model: light layer hidden for dark; dark layer default-hidden, shown for dark")
    func symbolLayersSwapByHiddenSpecializations() throws {
        let json = makeJSON(layers: [
            .init(name: "glyph-light", imageName: "glyph-light.png", exclusiveTo: .light),
            .init(name: "glyph-dark",  imageName: "glyph-dark.png",  exclusiveTo: .dark)])
        let groups = try #require(json["groups"] as? [[String: Any]])
        let layers = try #require(groups[0]["layers"] as? [[String: Any]])
        let lightHidden = try #require(layers[0]["hidden-specializations"] as? [[String: Any]])
        #expect(lightHidden[0]["appearance"] == nil && lightHidden[0]["value"] as? Bool == false)
        #expect(lightHidden[1]["appearance"] as? String == "dark" && lightHidden[1]["value"] as? Bool == true)
        let darkHidden = try #require(layers[1]["hidden-specializations"] as? [[String: Any]])
        #expect(darkHidden[0]["value"] as? Bool == true)
        #expect(darkHidden[1]["appearance"] as? String == "dark" && darkHidden[1]["value"] as? Bool == false)
    }

    @Test("Emoji model: single always-visible layer, NO hidden-specializations")
    func emojiSingleLayerHasNoSpecializations() throws {
        let json = makeJSON(layers: [.init(name: "glyph-emoji", imageName: "glyph-emoji.png", exclusiveTo: nil)])
        let layers = try #require((json["groups"] as? [[String: Any]])?[0]["layers"] as? [[String: Any]])
        #expect(layers[0]["hidden-specializations"] == nil)
        #expect(layers[0]["fill"] as? String == "none")
    }

    @Test("Platforms + layer position match the proven fixture")
    func fixtureInvariants() throws {
        let json = makeJSON(layers: [.init(name: "glyph-light", imageName: "glyph-light.png", exclusiveTo: .light)])
        let platforms = try #require(json["supported-platforms"] as? [String: [String]])
        #expect(platforms["squares"] == ["macOS"])
        let layer = try #require((json["groups"] as? [[String: Any]])?[0]["layers"] as? [[String: Any]])?[0]
        let position = try #require(layer?["position"] as? [String: Any])
        #expect(position["scale"] as? Double == 1.0)
    }

    private func p3(_ hex: String) throws -> String {
        let s = try #require(SRGB(hex: hex))
        let c = try #require(NSColor(srgbRed: s.r, green: s.g, blue: s.b, alpha: 1).usingColorSpace(.displayP3))
        return String(format: "display-p3:%.5f,%.5f,%.5f,1.00000", c.redComponent, c.greenComponent, c.blueComponent)
    }

    @Test("Mono icon.json: default fill is #FFFFFF→#EFEFF1, dark is #2C2C2E→#1C1C1E, tinted unchanged")
    func monoFills() throws {
        let fills = try HelperBundleManager.declarativeFillsP3(for: DockTileConfiguration(name: "Media", tintColor: .blue, background: .mono))
        let json = IconDocumentBuilder.iconJSON(
            fillTopP3: fills.lightTop, fillBottomP3: fills.lightBottom,
            darkFillTopP3: fills.darkTop, darkFillBottomP3: fills.darkBottom,
            tintedFillTopP3: fills.tintedTop, tintedFillBottomP3: fills.tintedBottom, layers: [])
        let specs = try #require(json["fill-specializations"] as? [[String: Any]])
        func stops(_ i: Int) throws -> [String] {
            let value = try #require(specs[i]["value"] as? [String: Any])
            return try #require(value["linear-gradient"] as? [String])
        }
        #expect(try stops(0) == [p3("#FFFFFF"), p3("#EFEFF1")])
        #expect(try stops(1) == [p3("#2C2C2E"), p3("#1C1C1E")])
        #expect(try stops(2) == [p3("#8E8E93"), p3("#636366")])
    }

    @Test("writeDocument lays out icon.json + Assets/")
    func writeDocumentLayout() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try IconDocumentBuilder.writeDocument(
            json: makeJSON(layers: []), layerPNGs: ["glyph-light.png": Data([1, 2, 3])],
            name: "tile", parent: dir)
        #expect(url.lastPathComponent == "tile.icon")
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("icon.json").path))
        #expect(try Data(contentsOf: url.appendingPathComponent("Assets/glyph-light.png")) == Data([1, 2, 3]))
    }

    @Test("A glyph document never gains a tinted hidden-specialization (the Apps-only change stays Apps-only)")
    func glyphDocumentHasNoTintedHiding() throws {
        let json = makeJSON(layers: [
            .init(name: "glyph-light", imageName: "glyph-light.png", exclusiveTo: .light),
            .init(name: "glyph-dark", imageName: "glyph-dark.png", exclusiveTo: .dark)
        ])
        let layers = try #require((json["groups"] as? [[String: Any]])?.first?["layers"] as? [[String: Any]])
        #expect(layers.count == 2)
        for layer in layers {
            let hidden = try #require(layer["hidden-specializations"] as? [[String: Any]])
            #expect(hidden.count == 2)
            #expect(!hidden.contains { $0["appearance"] as? String == "tinted" }, "\(layer["name"] ?? "?")")
        }
    }

    @Test("Apps face: system fills, one grid per appearance slot, and the flat look written explicitly")
    func appsFaceDocument() throws {
        let json = try IconDocumentBuilder.appsFaceIconJSON(background: .automatic, customHex: ConfigurationDefaults.appsBackgroundColor)
        #expect(json["fill"] as? String == "system-light")
        let specs = try #require(json["fill-specializations"] as? [[String: Any]])
        #expect(specs.count == 3)
        #expect(specs[0]["appearance"] == nil && specs[0]["value"] as? String == "system-light")
        #expect(specs[1]["appearance"] as? String == "dark" && specs[1]["value"] as? String == "system-dark")
        #expect(specs[2]["appearance"] as? String == "tinted" && specs[2]["value"] as? String == "system-light")

        let group = try #require((json["groups"] as? [[String: Any]])?.first)
        #expect(group["specular"] as? Bool == false)
        let translucency = try #require(group["translucency"] as? [String: Any])
        #expect(translucency["enabled"] as? Bool == false && (translucency["value"] as? NSNumber)?.doubleValue == 0)
        let shadow = try #require(group["shadow"] as? [String: Any])
        #expect(shadow["kind"] as? String == "none" && (shadow["opacity"] as? NSNumber)?.doubleValue == 0)

        // One grid per appearance slot: Default renders (light), Dark renders (dark) and Clear Dark
        // renders (tinted — which also feeds Clear Light/Dark and Tinted Light/Dark).
        let layers = try #require(group["layers"] as? [[String: Any]])
        #expect(layers.map { $0["name"] as? String } == ["grid", "grid-dark", "grid-tinted"])
        #expect(layers.map { $0["image-name"] as? String } == ["grid.png", "grid-dark.png", "grid-tinted.png"])
        for layer in layers {
            #expect(layer["glass"] as? Bool == false)
            #expect(layer["fill"] as? String == "none")
        }
        func hidden(_ layer: [String: Any]) -> [String] {
            ((layer["hidden-specializations"] as? [[String: Any]]) ?? []).map {
                "\($0["appearance"] as? String ?? "default")=\($0["value"] as? Bool ?? false)"
            }
        }
        #expect(hidden(layers[0]) == ["default=false", "dark=true", "tinted=true"])
        #expect(hidden(layers[1]) == ["default=true", "dark=false"])
        #expect(hidden(layers[2]) == ["default=true", "tinted=false"])
        #expect(IconDocumentBuilder.appsFaceImageName(for: .standard) == "grid.png")
        #expect(IconDocumentBuilder.appsFaceImageName(for: .dark) == "grid-dark.png")
        #expect(IconDocumentBuilder.appsFaceImageName(for: .clearDark) == "grid-tinted.png")
        #expect((json["supported-platforms"] as? [String: [String]])?["squares"] == ["macOS"])
        // The document serialises (no Swift tuples or enums leaked in).
        #expect(JSONSerialization.isValidJSONObject(json))
    }
}
