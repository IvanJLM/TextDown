import AppKit
import UniformTypeIdentifiers

/// Makes TextDown the app that opens Markdown and plain text files.
///
/// macOS asks the user to confirm every change of default app, so this runs
/// inside the normal app (never unattended), one request at a time, each
/// waiting for its answer.
@MainActor
enum DefaultEditor {
    static let types = ["net.daringfireball.markdown", "public.plain-text"]
    private static let askedKey = "AskedToBecomeDefault"

    static func isDefault(for identifier: String) -> Bool {
        guard let type = UTType(identifier),
              let app = NSWorkspace.shared.urlForApplication(toOpen: type) else { return false }
        return Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    static var missingTypes: [String] { types.filter { !isDefault(for: $0) } }

    /// On first launch, offers once to become the default app.
    static func offerOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: askedKey), !missingTypes.isEmpty else { return }
        defaults.set(true, forKey: askedKey)
        let alert = NSAlert()
        alert.messageText = "Open Markdown and text files with TextDown?"
        alert.informativeText = "TextDown can become the default app for .md and .txt files. macOS will ask you to confirm."
        alert.addButton(withTitle: "Use TextDown")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await makeDefault(quitWhenDone: false) }
        }
    }

    /// Asks macOS to make TextDown the default, waiting for each
    /// confirmation. With `quitWhenDone` (the install script), it quits after.
    static func makeDefault(quitWhenDone: Bool) async {
        UserDefaults.standard.set(true, forKey: askedKey)
        NSApp.activate()
        let app = Bundle.main.bundleURL
        for identifier in missingTypes {
            await request(app: app, identifier: identifier)
        }
        let alert = NSAlert()
        alert.messageText = missingTypes.isEmpty
            ? "TextDown now opens your Markdown and text files."
            : "TextDown opens \(types.count - missingTypes.count) of \(types.count) file types."
        alert.informativeText = missingTypes.isEmpty ? "" : "You can change it in Finder: Get Info › Open with › Change All."
        alert.runModal()
        if quitWhenDone { NSApp.terminate(nil) }
    }

    /// Sends one change request and waits (up to two minutes) for the user to
    /// answer the system confirmation.
    private static func request(app: URL, identifier: String) async {
        guard let type = UTType(identifier) else { return }
        do {
            try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
        } catch {
            return
        }
        let deadline = Date().addingTimeInterval(120)
        while !isDefault(for: identifier) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }
}
