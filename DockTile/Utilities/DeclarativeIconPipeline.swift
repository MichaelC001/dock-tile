//
//  DeclarativeIconPipeline.swift
//  DockTile
//
//  The declarative icon pipeline's availability seam plus the pure author of an Icon Composer
//  `.icon` document (icon.json + layer PNGs) from a tile's resolved identity. See
//  docs/icon-spike-fixtures/devtile-fix.icon/icon.json — the proven fixture this JSON schema
//  mirrors exactly (undocumented format; do not invent or "improve" keys).
//

import Foundation
import AppKit  // only NSColorSpace.genericRGB: CoreGraphics' kCGColorSpaceGenericRGB is unavailable in Swift

/// THE one availability branch for the declarative icon pipeline. Consulted at exactly three
/// activation points: helper bundle generation, `IconStyleManager` activation, and
/// migration/self-heal probes.
enum IconPipeline {
    static var isDeclarative: Bool {
        if #available(macOS 26.0, *) { return true } else { return false }
    }
}

/// The three appearances an Icon Composer `.icon` document can author. `clear` is NOT
/// authorable — macOS derives it from `tinted`.
enum IconAppearance: String {
    case light, dark, tinted
}

/// Pure author of an Icon Composer `.icon` document from a tile's resolved fill colours and
/// glyph layers. No filesystem/network access beyond `writeDocument`'s final write.
enum IconDocumentBuilder {

    /// One glyph layer in the document's single group.
    struct LayerSpec {
        /// The appearances a layer can be exclusive to. Deliberately NOT `IconAppearance`:
        /// `.tinted` reuses the light layer, and the polarity formula in `layerDict` would emit
        /// a layer hidden in EVERY appearance for it — an invalid document that still compiles.
        enum Exclusive { case light, dark }

        let name: String
        let imageName: String
        /// `nil` = visible in every appearance (the emoji single-layer model); otherwise the
        /// ONE appearance this layer is exclusive to (a `.light` layer hides for dark; a
        /// `.dark` layer starts hidden and shows for dark).
        let exclusiveTo: Exclusive?
    }

    /// Builds the `icon.json` dictionary. The default fill value is duplicated as the first,
    /// no-appearance entry in `fill-specializations` (fixture parity — also works around a
    /// defect in the vendored compiler; harmless for Apple's).
    nonisolated static func iconJSON(
        fillTopP3: (r: Double, g: Double, b: Double),
        fillBottomP3: (r: Double, g: Double, b: Double),
        darkFillTopP3: (r: Double, g: Double, b: Double),
        darkFillBottomP3: (r: Double, g: Double, b: Double),
        tintedFillTopP3: (r: Double, g: Double, b: Double),
        tintedFillBottomP3: (r: Double, g: Double, b: Double),
        layers: [LayerSpec]
    ) -> [String: Any] {
        let defaultFill = gradientValue(top: fillTopP3, bottom: fillBottomP3)
        let fillSpecializations: [[String: Any]] = [
            ["value": defaultFill],
            [
                "appearance": IconAppearance.dark.rawValue,
                "value": gradientValue(top: darkFillTopP3, bottom: darkFillBottomP3)
            ],
            [
                "appearance": IconAppearance.tinted.rawValue,
                "value": gradientValue(top: tintedFillTopP3, bottom: tintedFillBottomP3)
            ]
        ]
        return [
            "fill": defaultFill,
            "fill-specializations": fillSpecializations,
            "groups": [["layers": layers.map { layerDict($0) }]],
            "supported-platforms": ["circles": [], "squares": ["macOS"]]
        ]
    }

    /// Apple's own adaptive icon fills (what the system Apps icon and iOS folders use).
    nonisolated static let systemLightFill = "system-light"
    nonisolated static let systemDarkFill = "system-dark"
    nonisolated static let appsFaceLayerName = "grid"
    nonisolated static let appsFaceImageName = "grid.png"

    /// The grid image for each appearance slot. Clear Light / Clear Dark / Tinted Light / Tinted
    /// Dark all draw from the TINTED slot (measured with Apple's `ictool`), which holds the Clear
    /// Dark renders.
    nonisolated static func appsFaceImageName(for style: AppIconRenderStyle) -> String {
        switch style {
        case .standard: return appsFaceImageName
        case .dark: return "grid-dark.png"
        case .clearDark: return "grid-tinted.png"
        }
    }

    /// The `icon.json` for an Apps-face tile: the selected plate (system, dark, light or a custom
    /// colour) behind ONE grid layer per appearance slot — Default renders for light, Dark
    /// renders for dark, Clear Dark renders for tinted — so each mini looks like that app's own
    /// icon in each style, not the system's clear filter run over a colour mini.
    ///
    /// The flat look is written explicitly (`specular` off, `translucency` off, `shadow` none,
    /// layer `glass` false): Apple's `actool` defaults are specular on, translucency 0.3 and shadow
    /// 0.5, which wash out real app icons. The vendored compiler parses these keys but does not need
    /// them (it has no such defaults); spelling them out makes the document mean the same under both
    /// compilers. Proven shape (single-grid version):
    /// `docs/icon-spike-fixtures/appgrid-systemfill.icon`.
    ///
    /// The three-way hiding is built here, not through `LayerSpec.Exclusive`: that two-case model
    /// shows a glyph's light layer in the tinted slot ON PURPOSE, and glyph documents must not change.
    nonisolated static func appsFaceIconJSON(background: AppsGridBackground, customHex: String) throws -> [String: Any] {
        func fill(_ style: IconStyle) throws -> Any {
            switch background {
            case .automatic: return style == .dark ? systemDarkFill : systemLightFill
            case .charcoal: return systemDarkFill
            case .light: return systemLightFill
            case .custom:
                let stop = try renderCompensatedStop(
                    AppsFaceGrid.fillColors(background: background, customHex: customHex, style: style).top)
                return ["linear-gradient": [stop, stop],
                        "orientation": ["start": ["x": 0.5, "y": 0], "stop": ["x": 0.5, "y": 1]]]
            }
        }
        func gridLayer(_ style: AppIconRenderStyle, name: String, hidden: [[String: Any]]) -> [String: Any] {
            var layer = layerDict(
                LayerSpec(name: name, imageName: appsFaceImageName(for: style), exclusiveTo: nil), glass: false)
            layer["hidden-specializations"] = hidden
            return layer
        }
        let dark = IconAppearance.dark.rawValue, tinted = IconAppearance.tinted.rawValue
        let layers = [
            gridLayer(.standard, name: appsFaceLayerName,
                      hidden: [["value": false], ["appearance": dark, "value": true], ["appearance": tinted, "value": true]]),
            gridLayer(.dark, name: "grid-dark",
                      hidden: [["value": true], ["appearance": dark, "value": false]]),
            gridLayer(.clearDark, name: "grid-tinted",
                      hidden: [["value": true], ["appearance": tinted, "value": false]])
        ]
        let group: [String: Any] = [
            "specular": false,
            "translucency": ["enabled": false, "value": 0],
            "shadow": ["kind": "none", "opacity": 0],
            "layers": layers
        ]
        return [
            "fill": try fill(.defaultStyle),
            "fill-specializations": [
                ["value": try fill(.defaultStyle)],
                ["appearance": IconAppearance.dark.rawValue, "value": try fill(.dark)],
                ["appearance": IconAppearance.tinted.rawValue, "value": try fill(.tinted)]
            ],
            "groups": [group],
            "supported-platforms": ["circles": [], "squares": ["macOS"]]
        ]
    }

    /// An sRGB stop that macOS renders as `colour`. IconServices draws an `.icon` fill's stop
    /// components as if they were Generic RGB (gamma 1.8), so `srgb:` #224466 comes back #2B5678.
    /// Measured 2026-10-28 with the SAME result from Apple's `actool` and the vendored compiler:
    /// system behaviour, not a compiler bug. Writing the Generic RGB components makes the Dock show
    /// the colour picked; `AppsBackgroundTests.compiledCustomPlate` pins it end to end. Throws
    /// rather than writing an unconverted stop (a silently wrong colour), like `p3Components`.
    private static func renderCompensatedStop(_ colour: SRGB) throws -> String {
        guard let c = NSColor(srgbRed: colour.r, green: colour.g, blue: colour.b, alpha: 1)
            .usingColorSpace(.genericRGB) else { throw IconGeneratorError.colorConversionFailed }
        return String(format: "srgb:%.5f,%.5f,%.5f,1.00000", c.redComponent, c.greenComponent, c.blueComponent)
    }

    /// Writes `icon.json` + `Assets/<imageName>.png` into a new `<name>.icon` directory under
    /// `parent`. Returns the created `.icon` directory's URL.
    nonisolated static func writeDocument(
        json: [String: Any], layerPNGs: [String: Data], name: String, parent: URL
    ) throws -> URL {
        let iconDir = parent.appendingPathComponent("\(name).icon")
        let assetsDir = iconDir.appendingPathComponent("Assets")
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)

        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: iconDir.appendingPathComponent("icon.json"))

        for (fileName, pngData) in layerPNGs {
            try pngData.write(to: assetsDir.appendingPathComponent(fileName))
        }
        return iconDir
    }

    // MARK: - Private

    /// `glass` nil = key omitted, which keeps the glyph document byte-identical.
    private static func layerDict(_ layer: LayerSpec, glass: Bool? = nil) -> [String: Any] {
        var dict: [String: Any] = [
            "name": layer.name,
            "image-name": layer.imageName,
            "fill": "none",
            "position": [
                "scale": 1.0,
                "translation-in-points": [0, 0]
            ]
        ]
        if let exclusiveTo = layer.exclusiveTo {
            // Polarity: hidden by default unless this IS the light layer; hidden for dark unless
            // this IS the dark layer. Two cases only — see `LayerSpec.Exclusive`.
            dict["hidden-specializations"] = [
                ["value": exclusiveTo != .light],
                ["appearance": IconAppearance.dark.rawValue, "value": exclusiveTo != .dark]
            ]
        }
        if let glass { dict["glass"] = glass }
        return dict
    }

    private static func gradientValue(
        top: (r: Double, g: Double, b: Double), bottom: (r: Double, g: Double, b: Double)
    ) -> [String: Any] {
        [
            "linear-gradient": [p3String(top), p3String(bottom)],
            "orientation": [
                "start": ["x": 0.5, "y": 0],
                "stop": ["x": 0.5, "y": 1]
            ]
        ]
    }

    private static func p3String(_ c: (r: Double, g: Double, b: Double)) -> String {
        String(format: "display-p3:%.5f,%.5f,%.5f,1.00000", c.r, c.g, c.b)
    }
}

/// Errors from `IconCompiler.compile`. Every case carries enough to debug from — a broken or
/// unvalidated `Assets.car` is never returned silently. `LocalizedError` conformance matters here
/// (not just documentation): `DiagnosticsLog.measure`'s catch logs `error.localizedDescription`,
/// and a plain `Error` with no `LocalizedError` bridges to a generic NSError string that drops the
/// associated detail entirely — the one surface Copy Diagnostics relies on to debug a field
/// failure would otherwise never carry the compiler's actual stderr.
enum IconCompilerError: Error, LocalizedError, Equatable {
    /// `compilerURL` does not point to an executable file.
    case compilerMissing
    /// The compiler subprocess exited non-zero; the associated value is its captured stderr.
    case compileFailed(String)
    /// The compiler exited zero but the result failed structural validation — no `Assets.car`,
    /// `assetutil --info` itself failed, or the car does not carry exactly the three appearance
    /// `IconImageStack` renditions (the Apple `actool` silent-flattening class).
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .compilerMissing:
            return "docktile-actool compiler is missing or not executable"
        case .compileFailed(let stderr):
            return "docktile-actool failed: \(stderr)"
        case .invalidOutput(let reason):
            return reason
        }
    }
}

/// Invokes the vendored `docktile-actool` to compile an Icon Composer `.icon` document into an
/// `Assets.car`, then verifies the result actually contains layered icon renditions before
/// handing it back. Apple's own `actool` has shipped builds that silently flatten a layered icon
/// into a single non-layered image with no error anywhere — so a compile here is never trusted by
/// eyeball, only by checking `assetutil --info`.
enum IconCompiler {
    /// The bundled compiler inside the running app (main app only — Task 13 wires the build
    /// phase that copies it in; `nil` in helpers, which must never compile, and in any build
    /// from before that phase exists).
    static var bundledCompilerURL: URL? {
        Bundle.main.url(forResource: "docktile-actool", withExtension: nil)
    }

    /// Compiles `document` (an Icon Composer `.icon` directory) into `outputDir/Assets.car` using
    /// the compiler at `compilerURL`. Throws loudly on every failure mode — a missing compiler, a
    /// non-zero compile, or a structurally-invalid result — and never returns an unvalidated car.
    @available(*, noasync, message: "blocks ~0.9 s on subprocess waits — call compileOffMain from async code")
    static func compile(document: URL, outputDir: URL, compilerURL: URL) throws -> URL {
        try DiagnosticsLog.shared.measure("compile tile car") {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: compilerURL.path, isDirectory: &isDirectory)
            guard exists, !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: compilerURL.path) else {
                throw IconCompilerError.compilerMissing
            }
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

            let appIconName = document.deletingPathExtension().lastPathComponent
            let process = Process()
            process.executableURL = compilerURL
            process.arguments = [
                document.path,
                "--compile", outputDir.path,
                "--app-icon", appIconName,
                "--output-partial-info-plist", outputDir.appendingPathComponent("partial.plist").path,
                "--platform", "macosx",
                "--target-device", "mac",
                "--minimum-deployment-target", "15.0"
            ]
            // stdout just echoes a partial-info-plist we don't need, so discard it — only stderr
            // needs draining. Read stderr to EOF BEFORE waitUntilExit: a child that fills a pipe
            // buffer while this thread blocks in waitUntilExit deadlocks it (this runs on the
            // main actor during tile creation).
            let stderrPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderrPipe
            try process.run()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                throw IconCompilerError.compileFailed(String(data: stderrData, encoding: .utf8) ?? "unknown compiler error")
            }

            let carURL = outputDir.appendingPathComponent("Assets.car")
            guard FileManager.default.fileExists(atPath: carURL.path) else {
                throw IconCompilerError.invalidOutput("compiler exited successfully but produced no Assets.car")
            }

            // Unlike the compiler call above, we need BOTH streams here: stdout carries the JSON
            // `validate` classifies, stderr carries the detail if assetutil itself fails (a
            // truncated/corrupt car, an environment problem) — that failure must not be
            // misdiagnosed as "the compiler flattened the icon" when it's really "assetutil
            // couldn't even read the file". stderr goes to a FILE and stdout is read to EOF on THIS
            // thread: one pipe, drained by its only reader, so a full stderr can never block the
            // child and nothing waits on another thread. (It used to drain both pipes on
            // `DispatchQueue.global` blocks and wait for them; with every pool thread blocked in
            // a compile, those blocks never ran and every compile waited forever — the 2026-10-19
            // CI hang, reproduced by `concurrentCompilesFinish`.)
            let info = Process()
            info.executableURL = URL(fileURLWithPath: "/usr/bin/assetutil")
            info.arguments = ["--info", carURL.path]
            let infoOutPipe = Pipe()
            let infoErrURL = outputDir.appendingPathComponent("assetutil-stderr.txt")
            FileManager.default.createFile(atPath: infoErrURL.path, contents: nil)
            let infoErrHandle = try FileHandle(forWritingTo: infoErrURL)
            defer {
                try? infoErrHandle.close()
                try? FileManager.default.removeItem(at: infoErrURL)
            }
            info.standardOutput = infoOutPipe
            info.standardError = infoErrHandle
            try info.run()
            let infoData = infoOutPipe.fileHandleForReading.readDataToEndOfFile()
            info.waitUntilExit()
            let infoErrData = (try? Data(contentsOf: infoErrURL)) ?? Data()

            guard info.terminationStatus == 0 else {
                let message = String(data: infoErrData, encoding: .utf8) ?? "unknown assetutil error"
                throw IconCompilerError.invalidOutput("assetutil --info failed (exit \(info.terminationStatus)): \(message)")
            }

            if let reason = validationFailure(assetutilJSON: infoData) {
                throw IconCompilerError.invalidOutput(reason)
            }

            return carURL
        }
    }

    /// `compile`, with its two synchronous subprocess waits moved OFF the main actor. `compile`
    /// blocks its calling thread for ~0.9 s; called on the main actor that was a proper hang per
    /// tile (957–1021 ms, docs/performance-baseline-2026-09.md). The synchronous function is kept
    /// untouched — its pipe-draining order is load-bearing — and simply runs on a background thread.
    static func compileOffMain(document: URL, outputDir: URL, compilerURL: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try compile(document: document, outputDir: outputDir, compilerURL: compilerURL) })
            }
        }
    }

    /// The three appearance stacks a correctly-compiled layered icon must carry — one per
    /// appearance macOS renders. `clear` is derived from tintable, so there is no fourth.
    nonisolated static let requiredStackAppearances: Set<String> = [
        "NSAppearanceNameAqua", "NSAppearanceNameDarkAqua", "ISAppearanceTintable"
    ]

    /// Pure classification of `assetutil --info <car>` JSON. Returns `nil` when the car is
    /// structurally sound, or the reason it is not.
    ///
    /// **"At least one stack" is not enough (critical)**: the defect this whole vendoring effort
    /// exists to fix was a car whose three appearances were byte-identical — a collapse that a
    /// presence check happily passes. So the gate demands exactly the three appearance stacks
    /// (`requiredStackAppearances`), which is the strongest structural claim `assetutil --info`
    /// supports: a compiler that flattens the layers, or a crate update that emits a single
    /// stack, fails here instead of installing. `assetutil` can preface its output with a stray
    /// non-JSON line, so parsing starts at the first `[`.
    nonisolated static func validationFailure(assetutilJSON data: Data) -> String? {
        guard let jsonStart = data.firstIndex(of: UInt8(ascii: "[")),
              let array = try? JSONSerialization.jsonObject(with: data[jsonStart...]) as? [[String: Any]]
        else { return "assetutil --info output could not be parsed as a rendition array" }

        let stacks = array.filter { ($0["AssetType"] as? String) == "IconImageStack" }
        let appearances = Set(stacks.compactMap { $0["Appearance"] as? String })
        guard appearances == requiredStackAppearances, stacks.count == requiredStackAppearances.count else {
            let found = appearances.sorted().joined(separator: ", ")
            return """
                assetutil --info reports \(stacks.count) IconImageStack rendition(s) \
                (appearances: \(found.isEmpty ? "none" : found)) — a layered icon must carry \
                exactly \(requiredStackAppearances.count), one per appearance \
                (\(requiredStackAppearances.sorted().joined(separator: ", "))). The compiler \
                flattened the icon or collapsed its appearances.
                """
        }
        return nil
    }
}
