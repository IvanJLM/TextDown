import AppKit
import XCTest
@testable import TextDown

/// The title bar hides into the page and comes back with the mouse, with no
/// timer left running while nothing happens.
@MainActor
final class WindowChromeTests: XCTestCase {
    func testDocumentWindowsRunTheirPageUnderTheTitleBar() throws {
        let controller = DocumentWindowController()
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView), "the page runs under the title bar")
        XCTAssertTrue(window.titlebarAppearsTransparent)
        controller.close()
    }

    func testButtonsComeAndGoWithTheMouse() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = content
        let chrome = WindowChrome(window: window, content: content)
        let titlebar = try XCTUnwrap(window.standardWindowButton(.closeButton)?.superview)

        chrome.show()
        XCTAssertTrue(chrome.isShown)
        let timer = try XCTUnwrap(chrome.hideTimer, "the mouse moved: a countdown to hide")
        XCTAssertGreaterThan(timer.tolerance, 0, "the hide timer may be grouped with other wake-ups")

        chrome.hide()
        XCTAssertFalse(chrome.isShown)
        XCTAssertNil(chrome.hideTimer, "hidden: nothing scheduled")
        let faded = expectation(description: "fade finished")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { faded.fulfill() }
        await fulfillment(of: [faded], timeout: 2)
        XCTAssertTrue(titlebar.isHidden, "no clicks on invisible buttons")

        chrome.show()
        XCTAssertFalse(titlebar.isHidden)
        chrome.stop()
        XCTAssertNil(chrome.hideTimer, "no timer outlives the window")
    }

    func testFullScreenLeavesTheTitleBarToMacOS() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = content
        let chrome = WindowChrome(window: window, content: content)
        chrome.suspend()
        XCTAssertNil(chrome.hideTimer)
        chrome.hide()
        XCTAssertTrue(chrome.isShown, "in full screen the buttons are macOS's business")
        chrome.resume()
        XCTAssertNotNil(chrome.hideTimer)
        chrome.stop()
    }
}
