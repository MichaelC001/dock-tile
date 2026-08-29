import Testing
import Foundation
@testable import Dock_Tile

// MARK: - AppInstallChecker Tests

/// Exercises the pure `classifyInstallStatus(...)` decision seam — the regression-prone rule that
/// decides whether a tile's app is installed, missing, or unknown. Kept I/O-free so the rule is
/// testable without touching Launch Services / FileManager (mirrors `classifyForMigration`).
@Suite("AppInstallChecker classification")
struct AppInstallCheckerTests {

    // MARK: - Installed (either positive signal wins)

    @Test("Bundle ID resolving means installed")
    func bundleResolvesIsInstalled() {
        #expect(
            AppInstallChecker.classifyInstallStatus(
                bundleResolves: true,
                onDiskPathExists: false
            ) == .installed
        )
    }

    @Test("An app present on disk is installed even when Launch Services doesn't resolve the bundle")
    func onDiskPathIsInstalled() {
        // The "app moved / LS not yet re-registered after update" case.
        #expect(
            AppInstallChecker.classifyInstallStatus(
                bundleResolves: false,
                onDiskPathExists: true
            ) == .installed
        )
    }

    // MARK: - Missing

    @Test("No live bundle and nothing on disk is missing")
    func noSignalsIsMissing() {
        #expect(
            AppInstallChecker.classifyInstallStatus(
                bundleResolves: false,
                onDiskPathExists: false
            ) == .missing
        )
    }

    // MARK: - Regression: pre-v8 legacy entries must still be flagged

    @Test("A legacy entry (no path, has cached icon) that no longer resolves is missing, not exempt")
    func legacyUninstalledAppIsMissing() {
        // Regression guard for the production miss: an app uninstalled BEFORE the lastKnownPath
        // field existed carries a cached icon and no path. It must be flagged missing — a cached
        // icon is DockTile's own snapshot, not proof the app is installed. The classifier no
        // longer takes hasCachedIcon, so "doesn't resolve + not on disk" is unambiguously missing.
        #expect(
            AppInstallChecker.classifyInstallStatus(
                bundleResolves: false,
                onDiskPathExists: false
            ) == .missing
        )
    }

    // MARK: - Search paths centralisation

    @Test("Common search paths cover the four standard app install locations for a name")
    func commonSearchPathsCoverStandardLocations() {
        let paths = AppInstallChecker.commonSearchPaths(forName: "Safari")
        #expect(paths.contains("/Applications/Safari.app"))
        #expect(paths.contains("/System/Applications/Safari.app"))
        #expect(paths.contains("/Applications/Utilities/Safari.app"))
        #expect(paths.count == 4)
    }
}

// MARK: - Signal honesty: what counts as evidence that an app is installed

/// The classifier above is only as good as the two signals fed to it. These guard the rules that
/// decide whether a probed path is *evidence at all* — the gap behind the production report
/// "uninstalled app still shows in the tile and the Dock, and Scan finds nothing".
@Suite("AppInstallChecker install evidence")
struct AppInstallEvidenceTests {

    // MARK: - Trashed bundles

    @Test("A bundle sitting in the Trash is not an install location")
    func trashedPathsAreNotInstalled() {
        // Dragging an app to the Trash is how most people uninstall. The bundle — and its Launch
        // Services registration — survive there, so a bare fileExists() check calls it installed.
        #expect(AppInstallChecker.isTrashed("/Users/someone/.Trash/Foo.app"))
        #expect(AppInstallChecker.isTrashed("/Volumes/External/.Trashes/501/Foo.app"))
    }

    @Test("A normal install path is not treated as trashed")
    func normalPathsAreNotTrashed() {
        #expect(AppInstallChecker.isTrashed("/Applications/Foo.app") == false)
        #expect(AppInstallChecker.isTrashed("/Users/someone/Applications/Foo.app") == false)
        // Must key on the directory, not the word: an app may legitimately be named for the Trash.
        #expect(AppInstallChecker.isTrashed("/Applications/Trash Cleaner.app") == false)
    }

    // MARK: - Identity of a probed path

    @Test("A probed path counts only when the bundle there IS the app we're looking for")
    func probedPathMustHostTheExpectedBundle() {
        #expect(AppInstallChecker.acceptsProbedPath(
            exists: true, isTrashed: false,
            foundBundleId: "com.example.app", expected: "com.example.app"
        ))
    }

    @Test("A different app with the same display name is not evidence")
    func sameNameDifferentBundleIsRejected() {
        // The shipped bug, in miniature: a Chrome web-app shim called "Claude" was reported
        // installed forever because /Applications/Claude.app (com.anthropic.claudefordesktop)
        // satisfied the name probe. Display names are not identities.
        #expect(AppInstallChecker.acceptsProbedPath(
            exists: true, isTrashed: false,
            foundBundleId: "com.anthropic.claudefordesktop",
            expected: "com.google.Chrome.app.fmpnliohjhemenmnlpbfagaolkdacoja"
        ) == false)
    }

    @Test("An unreadable or absent bundle at the probed path is not evidence")
    func unreadableBundleIsRejected() {
        #expect(AppInstallChecker.acceptsProbedPath(
            exists: true, isTrashed: false, foundBundleId: nil, expected: "com.example.app"
        ) == false)
        #expect(AppInstallChecker.acceptsProbedPath(
            exists: false, isTrashed: false, foundBundleId: "com.example.app", expected: "com.example.app"
        ) == false)
    }

    @Test("The right app in the Trash is still not installed")
    func matchingBundleInTrashIsRejected() {
        #expect(AppInstallChecker.acceptsProbedPath(
            exists: true, isTrashed: true,
            foundBundleId: "com.example.app", expected: "com.example.app"
        ) == false)
    }
}

// MARK: - End-to-end resolution against the live filesystem

/// Drives the real `resolve(_:)` against apps that genuinely ship with macOS, so the name-collision
/// regression is caught in the actual I/O path and not only in the pure seams.
@MainActor
@Suite("AppInstallChecker.resolve against real apps")
struct AppInstallCheckerResolveTests {

    /// A real app in a location `commonSearchPaths` probes, with its true bundle identifier.
    private func installedSystemApp() -> (name: String, bundleId: String)? {
        let dir = "/System/Applications"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        for entry in entries.sorted() where entry.hasSuffix(".app") {
            let plist = NSDictionary(contentsOfFile: "\(dir)/\(entry)/Contents/Info.plist")
            if let id = plist?["CFBundleIdentifier"] as? String {
                return (String(entry.dropLast(4)), id)
            }
        }
        return nil
    }

    @Test("An app that is really installed resolves as installed")
    func installedAppResolves() throws {
        let real = try #require(installedSystemApp())
        let item = AppItem(bundleIdentifier: real.bundleId, name: real.name)
        #expect(AppInstallChecker.resolve(item).status == .installed)
    }

    @Test("An uninstalled app is missing even when another installed app shares its name")
    func uninstalledAppWithCollidingNameIsMissing() throws {
        // Regression guard for the production report: the name probe used to accept ANY bundle at
        // /Applications/<name>.app, so uninstalling one of two same-named apps left the tile showing
        // the survivor's icon and the Settings scan reporting all-clear.
        let real = try #require(installedSystemApp())
        let ghost = AppItem(
            bundleIdentifier: "com.docktile.tests.definitely-not-installed",
            name: real.name,
            lastKnownPath: "/Applications/Deleted \(real.name).app"
        )
        #expect(AppInstallChecker.resolve(ghost).status == .missing)
    }

    @Test("Resolution never reports a path belonging to a different app")
    func resolvedPathNeverPointsAtAnotherApp() throws {
        let real = try #require(installedSystemApp())
        let ghost = AppItem(bundleIdentifier: "com.docktile.tests.definitely-not-installed",
                            name: real.name)
        // A poisoned resolvedPath is worse than a wrong badge: scanForMissingApps writes it back
        // into lastKnownPath, so the item would confirm itself "installed" on every later scan.
        #expect(AppInstallChecker.resolve(ghost).resolvedPath == nil)
    }
}

// MARK: - AppItem lastKnownPath schema evolution

@Suite("AppItem lastKnownPath (v8) backward compatibility")
struct AppItemLastKnownPathTests {

    @Test("A pre-v8 config without lastKnownPath decodes with a nil path")
    func decodesLegacyConfigWithoutPath() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "bundleIdentifier": "com.apple.Safari",
          "name": "Safari",
          "isFolder": false
        }
        """.data(using: .utf8)!

        let item = try JSONDecoder().decode(AppItem.self, from: json)
        #expect(item.lastKnownPath == nil)
        #expect(item.bundleIdentifier == "com.apple.Safari")
    }

    @Test("lastKnownPath survives an encode/decode round trip")
    func roundTripsLastKnownPath() throws {
        let original = AppItem(
            bundleIdentifier: "com.apple.Safari",
            name: "Safari",
            lastKnownPath: "/Applications/Safari.app"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppItem.self, from: data)
        #expect(decoded.lastKnownPath == "/Applications/Safari.app")
    }
}
