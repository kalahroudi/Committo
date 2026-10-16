import XCTest
import AppKit
@testable import CommittoApp

/// Deinit canaries: the window and menu-bar controllers must be released once the owner lets go,
/// otherwise every open/close cycle leaks a hosting controller and its SwiftUI tree.
@MainActor
final class LifecycleTests: XCTestCase {
    override func setUp() async throws { _ = NSApplication.shared }

    func testMainWindowControllerIsReleased() async throws {
        weak var weakController: MainWindowController?
        weak var weakWindow: NSWindow?
        autoreleasepool {
            let c = MainWindowController(model: AppModel.shared)
            c.show()
            weakController = c
            weakWindow = NSApp.windows.first { $0.title == "Committo" }
            XCTAssertNotNil(weakWindow)
            weakWindow?.close()
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(weakController, "MainWindowController leaked")
        XCTAssertNil(weakWindow, "main NSWindow leaked")
    }

    func testStatusItemControllerIsReleasedAfterTearDown() async throws {
        weak var weakController: StatusItemController?
        autoreleasepool {
            let c = StatusItemController(model: AppModel.shared) {}
            weakController = c
            c.tearDown()
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(weakController, "StatusItemController leaked (timer or popover still retaining it?)")
    }
}
