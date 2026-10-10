import AppKit
import ArchiveCore

@main
struct SevenZipMacApp {
    static func main() {
        if CommandLine.arguments.contains("--ui-self-test") {
            do { try UIWorkflowChecks.run() } catch { fputs(error.localizedDescription + "\n",stderr); exit(1) }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var main: MainWindowController!
    var integration: SystemIntegration!
    var pendingURLs: [URL] = []
    var terminationTimer: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        main = MainWindowController()
        integration = SystemIntegration { [weak self] action, urls in self?.main.route(action, urls: urls) }
        buildMenus()
        NotificationCenter.default.addObserver(forName: Localization.didChange, object: nil, queue: .main) { [weak self] _ in self?.buildMenus() }
        main.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        integration.install()
        if !pendingURLs.isEmpty { integration.handle(urls:pendingURLs); pendingURLs = [] }
        if let payload = Bundle.main.url(forResource: "Payload", withExtension: "7z") {
            main.open(payload)
            main.extractURLs([payload])
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        if let integration { integration.handle(urls:urls) } else { pendingURLs.append(contentsOf:urls) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if main?.hasRunningOperations == true {
            guard confirm("Quit 7zip Mac?", "Operations are still running. Quitting cancels them.") else { return .terminateCancel }
            main.operations.filter { $0.running }.forEach { $0.requestCancel() }
            if terminationTimer == nil {
                terminationTimer = Timer.scheduledTimer(withTimeInterval:0.1,repeats:true) { [weak self] timer in
                    guard let self else { timer.invalidate(); return }
                    if !self.main.hasRunningOperations { timer.invalidate(); self.terminationTimer = nil; NSApp.reply(toApplicationShouldTerminate:true) }
                }
            }
            return .terminateLater
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        main?.primary.loadingControl?.cancel(); main?.secondary.loadingControl?.cancel()
        main?.temporaryDirectories.forEach { try? FileManager.default.removeItem(at:$0) }
    }
    func buildMenus() {
        let bar = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: L(title), action: nil, keyEquivalent: "")
            let m = NSMenu(title: L(title)); item.submenu = m; bar.addItem(item); return m
        }
        func add(_ m: NSMenu, _ title: String, _ action: Selector, _ key: String = "", _ flags: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: L(title), action: action, keyEquivalent: key); item.target = main; item.keyEquivalentModifierMask = flags; m.addItem(item)
        }
        let app = menu("7zip Mac")
        add(app, "About 7zip Mac", #selector(MainWindowController.about))
        add(app, "Settings…", #selector(MainWindowController.settings), ",")
        let services = NSMenuItem(title: L("Services"), action: nil, keyEquivalent: ""); services.submenu = NSMenu(); app.addItem(services); NSApp.servicesMenu = services.submenu
        app.addItem(.separator()); app.addItem(withTitle: L("Hide 7zip Mac"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: L("Quit 7zip Mac"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = menu("File")
        add(file, "Open…", #selector(MainWindowController.chooseOpen), "o")
        add(file, "Add to Archive…", #selector(MainWindowController.addArchive), "n")
        add(file, "Extract…", #selector(MainWindowController.extractSelected), "e")
        add(file, "Test Archive", #selector(MainWindowController.testSelected), "t")
        file.addItem(.separator()); add(file, "Open Selected", #selector(MainWindowController.openSelected), "\r")
        add(file, "Quick Look / Viewer", #selector(MainWindowController.previewSelected), " ", [])
        add(file, "Open Inside", #selector(MainWindowController.openInside))
        add(file, "Open Inside *", #selector(MainWindowController.openInsideAll))
        add(file, "Open Inside #", #selector(MainWindowController.openInsideParser))
        add(file, "Open Outside", #selector(MainWindowController.openOutside))
        add(file, "Edit and Reimport…", #selector(MainWindowController.editSelected))
        add(file, "Create macOS Extractor App…", #selector(MainWindowController.createExtractor as (MainWindowController) -> () -> Void))
        file.addItem(.separator()); add(file, "New Empty File…", #selector(MainWindowController.newFile))
        add(file, "Create Link…", #selector(MainWindowController.createLink))
        add(file, "Extended Attributes…", #selector(MainWindowController.showExtendedAttributes))
        add(file, "Comment…", #selector(MainWindowController.finderComment))
        add(file, "New Folder…", #selector(MainWindowController.newFolder), "n", [.command,.shift])
        add(file, "Rename…", #selector(MainWindowController.renameSelected))
        add(file, "Move to Trash / Delete from Archive…", #selector(MainWindowController.deleteSelected), "\u{8}")
        add(file, "Properties", #selector(MainWindowController.properties), "i")
        let edit = menu("Edit")
        edit.addItem(withTitle: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle:L("Select All"),action:#selector(NSResponder.selectAll(_:)),keyEquivalent:"a")
        let movePaste = NSMenuItem(title:L("Move Files Here"),action:#selector(FileTableView.pasteMoving(_:)),keyEquivalent:"v"); movePaste.keyEquivalentModifierMask = [.command,.option]; edit.addItem(movePaste)
        add(edit, "Deselect All Files", #selector(MainWindowController.deselectAllFiles))
        add(edit, "Deselect by Pattern…", #selector(MainWindowController.deselectPattern))
        add(edit, "Deselect Same Type", #selector(MainWindowController.deselectType))
        add(edit, "Invert Selection", #selector(MainWindowController.invertSelection))
        add(edit, "Select by Pattern…", #selector(MainWindowController.selectPattern))
        add(edit, "Select Same Type", #selector(MainWindowController.selectType))
        add(edit, "Copy Files to…", #selector(MainWindowController.copySelected))
        add(edit, "Move Files to…", #selector(MainWindowController.moveSelected))
        let view = menu("View")
        add(view, "Large Icons", #selector(MainWindowController.showLargeIcons))
        add(view, "Small Icons", #selector(MainWindowController.showSmallIcons))
        add(view, "List", #selector(MainWindowController.showListView))
        add(view, "Details", #selector(MainWindowController.showDetailsView))
        view.addItem(.separator())
        add(view, "Sort by Name", #selector(MainWindowController.sortName))
        add(view, "Sort by Type", #selector(MainWindowController.sortType))
        add(view, "Sort by Date", #selector(MainWindowController.sortDate))
        add(view, "Sort by Size", #selector(MainWindowController.sortSize))
        add(view, "Unsorted", #selector(MainWindowController.sortUnsorted))
        add(view, "Root", #selector(MainWindowController.goRoot))
        add(view, "Folder History", #selector(MainWindowController.showFolderHistory))
        add(view, "Archive Toolbar", #selector(MainWindowController.toggleArchiveToolbar))
        add(view, "Standard Toolbar", #selector(MainWindowController.toggleStandardToolbar))
        add(view, "Large Buttons", #selector(MainWindowController.toggleLargeButtons))
        add(view, "Button Text", #selector(MainWindowController.toggleButtonText))
        add(view, "Time Settings…", #selector(MainWindowController.showTimeSettings))
        add(view, "Configure Columns…", #selector(MainWindowController.configureColumns))
        add(view, "Back", #selector(MainWindowController.goBack), "[")
        add(view, "Forward", #selector(MainWindowController.goForward), "]")
        add(view, "Up One Level", #selector(MainWindowController.goUp), "\u{f700}")
        add(view, "Refresh", #selector(MainWindowController.refresh), "r")
        add(view, "Go to Folder…", #selector(MainWindowController.goToFolder), "g", [.command,.shift])
        add(view, "Show Hidden Files", #selector(MainWindowController.toggleHiddenFiles))
        add(view, "Flat View", #selector(MainWindowController.toggleFlat), "f", [.command,.shift])
        add(view, "Dual Panes", #selector(MainWindowController.toggleDual), "2")
        add(view, "Manage Favorites…", #selector(MainWindowController.manageFavorites))
        add(view, "Auto Refresh", #selector(MainWindowController.toggleAutoRefresh))
        add(view, "Add Current Folder to Favorites", #selector(MainWindowController.favorite))
        let tools = menu("Tools")
        add(tools, "Calculate Checksums…", #selector(MainWindowController.hashSelected))
        add(tools, "Save SHA-256 Manifest…", #selector(MainWindowController.createChecksumManifest))
        add(tools, "Verify SHA-256 Manifest…", #selector(MainWindowController.verifyChecksumManifest))
        add(tools, "Compare Two Selected Items", #selector(MainWindowController.compareSelected))
        add(tools, "Benchmark…", #selector(MainWindowController.benchmark))
        add(tools, "Split File…", #selector(MainWindowController.splitSelected))
        add(tools, "Combine Volumes…", #selector(MainWindowController.combineSelected))
        let help = menu("Help"); add(help, "7-Zip Manual", #selector(MainWindowController.manual))
        NSApp.mainMenu = bar
    }
}

func confirm(_ title: String, _ message: String, destructive: Bool = false) -> Bool {
    let alert = NSAlert(); alert.messageText = L(title); alert.informativeText = L(message)
    alert.alertStyle = destructive ? .warning : .informational
    alert.addButton(withTitle: L("Continue")); alert.addButton(withTitle: L("Cancel"))
    return alert.runModal() == .alertFirstButtonReturn
}
func showError(_ error: Error) { let a = NSAlert(); a.alertStyle = .warning; a.messageText = L("Operation failed"); a.informativeText = Localization.translate(error: error); a.addButton(withTitle: L("OK")); a.runModal() }
struct UIError: LocalizedError { let message: String; var errorDescription: String? { L(message) } }
func prompt(_ title: String, message: String = "", value: String = "") -> String? {
    let a = NSAlert(); a.messageText = L(title); a.informativeText = L(message)
    let f = NSTextField(string: value); f.frame = NSRect(x: 0,y: 0,width: 380,height: 24); a.accessoryView = f
    a.addButton(withTitle: L("OK")); a.addButton(withTitle: L("Cancel")); a.window.initialFirstResponder = f
    return a.runModal() == .alertFirstButtonReturn ? f.stringValue : nil
}
func chooseDirectory(_ title: String, initial: URL? = nil) -> URL? {
    let p = NSOpenPanel(); p.title = L(title); p.canChooseDirectories = true; p.canChooseFiles = false; p.directoryURL = initial
    return p.runModal() == .OK ? p.url : nil
}
func saveURL(_ title: String, name: String, initial: URL? = nil) -> URL? {
    let p = NSSavePanel(); p.title = L(title); p.nameFieldStringValue = name; p.directoryURL = initial
    return p.runModal() == .OK ? p.url : nil
}
