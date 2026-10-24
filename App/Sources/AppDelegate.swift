import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Launched by the install script to become the default app.
    private let settingDefault = CommandLine.arguments.contains("--make-default")
    /// True while the app hosts the unit tests: no windows, no quitting.
    private let hostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "NSFullScreenMenuItemEverywhere": false,
            "NSQuitAlwaysKeepsWindows": false,
        ])
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if settingDefault {
            Task { await DefaultEditor.makeDefault(quitWhenDone: true) }
        } else if !hostingTests {
            // Ask after the first window is on screen, never in front of it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { DefaultEditor.offerOnFirstLaunch() }
        }
    }

    /// Opened from the Dock or Spotlight without a file: a blank page.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        !settingDefault && !hostingTests
    }

    /// TextDown runs only while a document is open, so it uses no memory otherwise.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !settingDefault && !hostingTests
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSMutableAttributedString(
            string: "A minimal, native text editor and Markdown reader for Apple Silicon Macs.\nFree and open source under the MIT License.\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        credits.append(NSAttributedString(string: "github.com/IvanJLM/TextDown", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .link: URL(string: "https://github.com/IvanJLM/TextDown")!,
        ]))
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }
}
