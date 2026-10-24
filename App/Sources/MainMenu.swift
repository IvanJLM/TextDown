import AppKit

/// The menu bar, built in code (no nib to load at launch).
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let app = submenu(in: main, title: "TextDown")
        app.addItem(item("About TextDown", #selector(AppDelegate.showAbout(_:))))
        app.addItem(.separator())
        app.addItem(item("Hide TextDown", #selector(NSApplication.hide(_:)), "h"))
        app.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(item("Quit TextDown", #selector(NSApplication.terminate(_:)), "q"))

        let file = submenu(in: main, title: "File")
        file.addItem(item("New", #selector(NSDocumentController.newDocument(_:)), "n"))
        file.addItem(item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"))
        let recent = NSMenu(title: "Open Recent")
        recent.addItem(item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:))))
        let recentHolder = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentHolder.submenu = recent
        file.addItem(recentHolder)
        file.addItem(.separator())
        file.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        file.addItem(item("Save…", #selector(NSDocument.save(_:)), "s"))
        file.addItem(item("Duplicate", #selector(NSDocument.duplicate(_:)), "s", [.command, .shift]))
        let saveAs = item("Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift, .option])
        saveAs.isAlternate = true
        file.addItem(saveAs)
        file.addItem(item("Rename…", #selector(NSDocument.rename(_:))))
        file.addItem(item("Move To…", #selector(NSDocument.move(_:))))
        file.addItem(item("Revert to Saved", #selector(NSDocument.revertToSaved(_:))))
        file.addItem(.separator())
        file.addItem(item("Show in Finder", #selector(DocumentWindowController.showInFinder(_:)), "r", [.command, .shift]))
        file.addItem(.separator())
        file.addItem(item("Print…", #selector(NSDocument.printDocument(_:)), "p"))

        let edit = submenu(in: main, title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        edit.addItem(.separator())
        let find = NSMenu(title: "Find")
        find.addItem(findItem("Find…", .showFindInterface, "f"))
        find.addItem(findItem("Find and Replace…", .showReplaceInterface, "f", [.command, .option]))
        find.addItem(findItem("Find Next", .nextMatch, "g"))
        find.addItem(findItem("Find Previous", .previousMatch, "g", [.command, .shift]))
        let findHolder = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        findHolder.submenu = find
        edit.addItem(findHolder)

        let view = submenu(in: main, title: "View")
        view.addItem(item("Edit Markdown", #selector(DocumentWindowController.toggleEditing(_:)), "e"))
        view.addItem(.separator())
        view.addItem(item("Actual Size", #selector(DocumentWindowController.actualSize(_:)), "0"))
        view.addItem(item("Zoom In", #selector(DocumentWindowController.zoomIn(_:)), "+"))
        view.addItem(item("Zoom Out", #selector(DocumentWindowController.zoomOut(_:)), "-"))
        view.addItem(.separator())
        view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))

        let window = submenu(in: main, title: "Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = window

        return main
    }

    private static func submenu(in main: NSMenu, title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        main.addItem(holder)
        return menu
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func findItem(_ title: String, _ action: NSTextFinder.Action, _ key: String,
                                 _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = item(title, #selector(NSTextView.performFindPanelAction(_:)), key, modifiers)
        item.tag = action.rawValue
        return item
    }
}
