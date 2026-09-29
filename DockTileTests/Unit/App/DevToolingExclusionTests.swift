import Foundation
import Testing

/// The dev-tile memory watcher (`Scripts/perf/memwatch.py` plus a per-user LaunchAgent,
/// `com.docktile.dev.memwatch`) is dev-machine tooling and must never ship to users.
///
/// It stays out of production by construction: nothing in the app target references
/// `Scripts/perf`, so nothing there is compiled into the binary or copied into the bundle. That was
/// verified against the shipped 2.0.2 app on 2026-09-29. This guard keeps it true: it fails the
/// moment the Xcode project references the watcher, its LaunchAgent label, or the perf harness —
/// for instance the script added to Copy Bundle Resources, or a build phase that copies it.
///
/// Failing value: any of the needles below appearing in `project.pbxproj`.
@Suite("Dev tooling stays out of the app bundle")
struct DevToolingExclusionTests {

    private let projectFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // App
        .deletingLastPathComponent()   // Unit
        .deletingLastPathComponent()   // DockTileTests
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("DockTile.xcodeproj/project.pbxproj")

    @Test("The Xcode project never references the memory watcher or the perf harness")
    func projectHasNoPerfHarnessReferences() throws {
        let project = try String(contentsOf: projectFile, encoding: .utf8)
        // Proves the path resolved to the real project, so an empty or wrong file can't pass.
        #expect(project.contains("PBXNativeTarget"))
        for needle in ["memwatch", "com.docktile.dev.memwatch", "Scripts/perf"] {
            #expect(!project.contains(needle),
                    "\(needle) is referenced by the Xcode project, so dev tooling would ship in the app")
        }
    }
}
