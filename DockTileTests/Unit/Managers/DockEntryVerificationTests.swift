//
//  DockEntryVerificationTests.swift
//  DockTileTests
//
//  Guards the 2.6.2 Dock write-race fix (docs/dock-modification-prior-art.md §6):
//    1. `dockRestartArguments` — the Dock is restarted with SIGKILL, so a dying Dock cannot
//       save its stale persistent-apps over the write we just made.
//

import Testing
import Foundation
@testable import Dock_Tile

@Suite("Dock restart signal")
struct DockRestartSignalTests {

    @Test("The Dock is restarted with SIGKILL, so the exiting Dock cannot save its stale list over our write")
    func restartSendsSIGKILL() {
        #expect(HelperBundleManager.dockRestartArguments == ["-KILL", "Dock"])
    }
}
