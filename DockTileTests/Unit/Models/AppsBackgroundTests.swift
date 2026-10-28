import AppKit
import SwiftUI
import Testing
@testable import Dock_Tile

@MainActor
@Suite("App Grid background settings")
struct AppsBackgroundTests {
    @Test("Old configurations keep the system appearance and new settings round-trip independently per tile")
    func persistence() throws {
        let config = DockTileConfiguration(appsBackground: .custom, appsBackgroundColor: "#224466")
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(DockTileConfiguration.self, from: data) == config)
        var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "appsBackground")
        old.removeValue(forKey: "appsBackgroundColor")
        let decoded = try JSONDecoder().decode(DockTileConfiguration.self,
            from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.appsBackground == .automatic)
        #expect(decoded.appsBackgroundColor == "#404040")
        #expect(decoded.appItems == config.appItems)
        #expect(decoded.id == config.id)
        #expect(DockTileConfiguration().appsBackground == .automatic)
    }

    @Test("Unknown styles and malformed custom colours have safe defaults")
    func tolerantDefaults() throws {
        #expect(try JSONDecoder().decode(AppsGridBackground.self, from: Data("\"future-style\"".utf8)) == .automatic)
        let fill = AppsFaceGrid.fillColors(background: .custom, customHex: "bad colour", style: .defaultStyle)
        #expect(fill.top == SRGB(r: 64.0 / 255, g: 64.0 / 255, b: 64.0 / 255))
    }

    @Test("Background edits dirty both the saved form and the Dock, without affecting the glyph face")
    func signatures() {
        let base = DockTileConfiguration(iconFace: .apps)
        var custom = base; custom.appsBackground = .custom; custom.appsBackgroundColor = "#224466"
        #expect(base.iconSignature != custom.iconSignature)
        #expect(base.dockSignature != custom.dockSignature)
        #expect(DockTileDetailView.contentSignature(of: base) != DockTileDetailView.contentSignature(of: custom))
        var recoloured = custom; recoloured.appsBackgroundColor = "#663322"
        #expect(recoloured.iconSignature != custom.iconSignature)
        var dormant = base; dormant.appsBackgroundColor = "#663322"
        #expect(dormant.iconSignature == base.iconSignature)
        var glyph = base; glyph.iconFace = .glyph
        var otherGlyph = custom; otherGlyph.iconFace = .glyph
        #expect(glyph.iconSignature == otherGlyph.iconSignature)
        let restored = CustomiseTileView.applyStyle(.apps, to: CustomiseTileView.applyStyle(.symbol, to: custom))
        #expect(restored.appsBackground == .custom && restored.appsBackgroundColor == "#224466")
    }

    @Test("Explicit backgrounds stay fixed while automatic follows the system")
    func fills() {
        for style in IconStyle.allCases {
            let automatic = AppsFaceGrid.fillColors(background: .automatic, customHex: "#224466", style: style)
            let expected = AppsFaceGrid.fillGrays(style: style)
            #expect(automatic.top.r == Double(expected.top))
            #expect(automatic.bottom.r == Double(expected.bottom))
            let charcoal = AppsFaceGrid.fillColors(background: .charcoal, customHex: "#224466", style: style)
            #expect(charcoal.top.r == Double(AppsFaceGrid.darkGrays.top))
            #expect(charcoal.bottom.r == Double(AppsFaceGrid.darkGrays.bottom))
            let custom = AppsFaceGrid.fillColors(background: .custom, customHex: "#224466", style: style)
            #expect(custom.top == SRGB(r: 34.0 / 255, g: 68.0 / 255, b: 102.0 / 255))
            #expect(custom.bottom == custom.top)
            let light = AppsFaceGrid.fillColors(background: .light, customHex: "#224466", style: style)
            #expect(light.top == SRGB(r: 1, g: 1, b: 1))
            #expect(light.bottom == SRGB(r: 0.925, g: 0.925, b: 0.925))
        }
    }

    @Test("Each compiled layer's empty slots take the plate's tone; the tinted slot is always dark glass")
    func layerTones() {
        typealias S = AppIconRenderStyle
        func tones(_ background: AppsGridBackground, _ hex: String = "#224466") -> [Bool] {
            [S.standard, .dark, .clearDark].map {
                AppsFaceGrid.layerOnDarkGlass(slot: $0, background: background, customHex: hex)
            }
        }
        // Follow System must bake exactly what main baked before backgrounds existed.
        #expect(tones(.automatic) == [false, true, true])
        #expect(tones(.charcoal) == [true, true, true])
        #expect(tones(.light) == [false, false, true])
        #expect(tones(.custom, "#224466") == [true, true, true])
        #expect(tones(.custom, "#F0E0C0") == [false, false, true])
    }

    @Test("A plate counts as dark when white reads better on it than black")
    func darkPlateThreshold() {
        // Equal contrast falls at relative luminance ~0.179, between #757575 and #767676.
        #expect(AppsFaceGrid.usesDarkPlate(background: .custom, customHex: "#757575", style: .defaultStyle))
        #expect(!AppsFaceGrid.usesDarkPlate(background: .custom, customHex: "#767676", style: .defaultStyle))
    }

    @Test("Custom colour reaches every appearance slot as Generic RGB components, which macOS renders as the sRGB colour")
    func declarativeFill() throws {
        let json = try IconDocumentBuilder.appsFaceIconJSON(background: .custom, customHex: "#224466")
        let fill = try #require(json["fill"] as? [String: Any])
        let stops = try #require(fill["linear-gradient"] as? [String])
        // #224466 in Generic RGB, pinned as a literal so it does not mirror the code under test.
        let expectedStop = "srgb:0.10358,0.20177,0.32542,1.00000"
        #expect(stops == [expectedStop, expectedStop])
        for spec in try #require(json["fill-specializations"] as? [[String: Any]]) {
            let value = try #require(spec["value"] as? [String: Any])
            #expect(value["linear-gradient"] as? [String] == stops)
        }
        let charcoal = try IconDocumentBuilder.appsFaceIconJSON(background: .charcoal, customHex: "#224466")
        #expect(charcoal["fill"] as? String == "system-dark")
        for spec in try #require(charcoal["fill-specializations"] as? [[String: Any]]) {
            #expect(spec["value"] as? String == "system-dark")
        }
        let light = try IconDocumentBuilder.appsFaceIconJSON(background: .light, customHex: "#224466")
        #expect(light["fill"] as? String == "system-light")
    }

    @Test("A custom plate is rendered into the fallback icon with the requested RGB colour")
    func fallbackPixels() throws {
        let image = IconGenerator.appsIcon(minis: [], size: CGSize(width: 256, height: 256),
                                           iconStyle: .defaultStyle, background: .custom, customHex: "#224466")
        var rect = CGRect(x: 0, y: 0, width: 256, height: 256)
        let cg = try #require(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let rep = NSBitmapImageRep(cgImage: cg)
        // Centre is between the four empty slots: sample only the plate.
        let color = try #require(rep.colorAt(x: 128, y: 128)?.usingColorSpace(.sRGB))
        #expect(abs(color.redComponent - 34.0 / 255) < 0.015)
        #expect(abs(color.greenComponent - 68.0 / 255) < 0.015)
        #expect(abs(color.blueComponent - 102.0 / 255) < 0.015)
        #expect(color.alphaComponent == 1)
    }

    @Test("The hero/sidebar preview receives and renders the stored custom plate")
    func previewPixels() throws {
        let config = DockTileConfiguration(iconFace: .apps, appsBackground: .custom, appsBackgroundColor: "#224466")
        let preview = DockTileIconPreview.fromConfig(config, size: 256).forcing(.defaultStyle)
        #expect(preview.appsBackground == .custom && preview.appsBackgroundColor == "#224466")
        // Match the window's 8-bit rendering. ImageRenderer can emit a PQ surface,
        // whose values cannot be compared directly with the saved sRGB colour.
        let host = NSHostingView(rootView: preview)
        host.frame = CGRect(x: 0, y: 0, width: 256, height: 256)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: rep)
        let color = try #require(rep.colorAt(x: 128, y: 128)?.usingColorSpace(.sRGB))
        #expect(abs(color.redComponent - 34.0 / 255) < 0.015)
        #expect(abs(color.greenComponent - 68.0 / 255) < 0.015)
        #expect(abs(color.blueComponent - 102.0 / 255) < 0.015)
    }
    nonisolated private static var compilerURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vendor/actool/target/release/docktile-actool")
    }

    @Test("The compiled custom plate is the actual colour returned by macOS IconServices",
          .enabled(if: IconPipeline.isDeclarative && FileManager.default.fileExists(atPath: Self.compilerURL.path)))
    func compiledCustomPlate() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var pngs: [String: Data] = [:]
        for style in AppIconRenderStyle.allCases {
            pngs[IconDocumentBuilder.appsFaceImageName(for: style)] = try IconGenerator.generateAppsLayerPNG(minis: [])
        }
        let document = try IconDocumentBuilder.writeDocument(
            json: try IconDocumentBuilder.appsFaceIconJSON(background: .custom, customHex: "#224466"),
            layerPNGs: pngs, name: "AppIcon", parent: scratch)
        let app = scratch.appendingPathComponent("ColourProbe.app")
        let contents = app.appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources")
        let car = try IconCompiler.compile(document: document, outputDir: resources, compilerURL: Self.compilerURL)
        #expect(FileManager.default.fileExists(atPath: car.path))
        let info: [String: Any] = ["CFBundleIdentifier": "com.docktile.colour-test." + UUID().uuidString,
                                  "CFBundleName": "ColourProbe", "CFBundlePackageType": "APPL",
                                  "CFBundleIconName": "AppIcon", "CFBundleIconFile": "AppIcon.icns"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let cg = try #require(AppIconStyleRenderer.render(appAt: app, pixelSize: 256, style: .standard))
        let context = try #require(CGContext(data: nil, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let rep = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        let color = try #require(rep.colorAt(x: cg.width / 2, y: cg.height / 2)?.usingColorSpace(.sRGB))
        #expect(abs(color.redComponent - 34.0 / 255) < 0.015, "actual RGB: \(color.redComponent), \(color.greenComponent), \(color.blueComponent)")
        #expect(abs(color.greenComponent - 68.0 / 255) < 0.015)
        #expect(abs(color.blueComponent - 102.0 / 255) < 0.015)
    }

}
