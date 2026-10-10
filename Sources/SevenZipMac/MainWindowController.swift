import AppKit
import ArchiveCore

enum ArchivePropertyReport {
    static func make(archive: URL, properties: [String:String], entries: [ArchiveEntry], selected: [BrowserItem]) -> String {
        func fields(_ values: [String:String]) -> String { values.keys.sorted().map { "\($0): \(values[$0]!)" }.joined(separator:"\n") }
        func directoryKey(_ path: String) -> String { var key = path; while key.hasSuffix("/") { key.removeLast() }; return key }
        var sections = [archive.path + "\n" + fields(properties)]
        var included: Set<String> = []
        for item in selected {
            let key = directoryKey(item.path)
            let matches = entries.filter { directoryKey($0.path) == key || (item.directory && $0.path.hasPrefix(key + "/")) }
            if matches.isEmpty { sections.append(item.path + "\n" + L(item.directory ? "Folder" : "File")) }
            for entry in matches where included.insert(entry.path).inserted {
                var values = entry.properties
                let standard = ["Path":entry.path,"Size":String(entry.size),"Packed Size":String(entry.packedSize),"Folder":entry.isDirectory ? "+" : "-","Modified":entry.modified,"Encrypted":entry.encrypted ? "+" : "-"]
                for (name,value) in standard where values[name] == nil { values[name] = value }
                sections.append(fields(values))
            }
        }
        return sections.joined(separator:"\n\n")
    }
}
import QuickLookUI

final class MainWindowController: NSWindowController, NSToolbarDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate, NSMenuItemValidation, NSToolbarItemValidation {
    var engine: SevenZipEngine?
    let primary = BrowserPane(frame:.zero)
    let secondary = BrowserPane(frame:.zero)
    var active: BrowserPane!
    let panes = NSSplitView()
    let sidebar = NSOutlineView()
    var sidebarItems: [SidebarItem] = []
    var reloadingSidebar = false
    var favorites: [URL] = []
    var recent: [URL] = []
    var operations: [ProgressController] = []
    var archivePasswords: [URL:String] = [:]
    var archiveFormats: [URL:String] = [:]
    var archiveClipboard: ArchiveClipboardSession?
    var nestedParents: [URL:BrowserLocation] = [:]
    var previewURL: URL?
    let reservations = OperationReservations()
    var temporaryDirectories: [URL] = []
    var editSessions: [EditSessionController] = []
    var refreshTimer: Timer?
    var hasRunningOperations: Bool { operations.contains { $0.running } }
    let archiveExtensions: Set<String> = ["7z","zip","rar","tar","gz","gzip","bz2","bzip2","xz","wim","cab","iso","dmg","arj","lzh","z","001","tgz","tbz","txz","cpio","rpm","deb","vhd","vhdx","udf","jar","epub","docx","xlsx","pptx","apfs","hfs","qcow","squashfs"]
    init() {
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1100,height:710),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "7zip Mac"; window.minSize = NSSize(width:780,height:430); window.setFrameAutosaveName("main")
        super.init(window:window)
        do { engine = SevenZipEngine(binaryURL:try SevenZipEngine.locateBinary()) } catch { DispatchQueue.main.async { showError(error) } }
        active = primary; primary.connect(self); secondary.connect(self)
        favorites = (UserDefaults.standard.stringArray(forKey:"favorites") ?? []).map { URL(fileURLWithPath:$0) }
        recent = (UserDefaults.standard.stringArray(forKey:"recent") ?? []).map { URL(fileURLWithPath:$0) }
        let column = NSTableColumn(identifier:.init("sidebar")); column.width = 170; sidebar.addTableColumn(column); sidebar.headerView = nil
        sidebar.delegate = self; sidebar.dataSource = self; sidebar.rowHeight = 34; sidebar.style = .sourceList
        sidebar.intercellSpacing = NSSize(width:0,height:4); sidebar.rowSizeStyle = .large
        sidebar.outlineTableColumn = column; sidebar.floatsGroupRows = false
        sidebar.setAccessibilityLabel(L("Files"))
        let sideScroll = NSScrollView(); sideScroll.documentView = sidebar; sideScroll.hasVerticalScroller = true
        sideScroll.drawsBackground = false; sidebar.backgroundColor = .clear
        let sidebarBackground = NSVisualEffectView(); sidebarBackground.material = .sidebar
        sidebarBackground.blendingMode = .behindWindow; sidebarBackground.state = .followsWindowActiveState
        sideScroll.translatesAutoresizingMaskIntoConstraints = false; sidebarBackground.addSubview(sideScroll)
        NSLayoutConstraint.activate([sideScroll.leadingAnchor.constraint(equalTo:sidebarBackground.leadingAnchor),sideScroll.trailingAnchor.constraint(equalTo:sidebarBackground.trailingAnchor),sideScroll.topAnchor.constraint(equalTo:sidebarBackground.topAnchor),sideScroll.bottomAnchor.constraint(equalTo:sidebarBackground.bottomAnchor)])
        sidebarBackground.widthAnchor.constraint(greaterThanOrEqualToConstant:160).isActive = true
        panes.isVertical = true; panes.dividerStyle = .thin; panes.addArrangedSubview(primary); panes.addArrangedSubview(secondary); secondary.isHidden = true
        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin; split.addArrangedSubview(sidebarBackground); split.addArrangedSubview(panes)
        window.contentView = split; split.setPosition(220,ofDividerAt:0)
        let toolbar = NSToolbar(identifier:"main"); toolbar.delegate = self; toolbar.displayMode = .iconAndLabel; toolbar.allowsUserCustomization = true; toolbar.autosavesConfiguration = true
        window.toolbar = toolbar; window.toolbarStyle = .unified
        reloadSidebar(); window.center()
        primary.navigate(BrowserLocation(url:FileManager.default.homeDirectoryForCurrentUser,archive:false))
        secondary.navigate(BrowserLocation(url:FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"),archive:false))
        active = primary; configureAutoRefresh(); rebuildToolbar(); toolbar.displayMode = UserDefaults.standard.bool(forKey:"hideToolbarText") ? .iconOnly : .iconAndLabel; toolbar.sizeMode = UserDefaults.standard.bool(forKey:"largeToolbarButtons") ? .regular : .small
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { refreshTimer?.invalidate(); temporaryDirectories.forEach { try? FileManager.default.removeItem(at:$0) } }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ["open","add","extract","test","copy","move","hash","delete","info","dual","NSToolbarFlexibleSpaceItem","NSToolbarSpaceItem"].map { .init($0) } }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ["open","add","extract","test","hash","NSToolbarFlexibleSpaceItem","delete","info","dual"].map { NSToolbarItem.Identifier($0) } }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let values: [String:(String,String,Selector)] = ["open":("Open","folder",#selector(chooseOpen)),"add":("Add","plus.square",#selector(addArchive)),"extract":("Extract","archivebox",#selector(extractSelected)),"test":("Test","checkmark.shield",#selector(testSelected)),"copy":("Copy to…","doc.on.doc",#selector(copySelected)),"move":("Move to…","folder.badge.plus",#selector(moveSelected)),"hash":("Checksum","number",#selector(hashSelected)),"delete":("Delete","trash",#selector(deleteSelected)),"info":("Info","info.circle",#selector(properties)),"dual":("Dual Panes","rectangle.split.2x1",#selector(toggleDual))]
        guard let value = values[id.rawValue] else { return nil }
        let item = NSToolbarItem(itemIdentifier:id); item.label = L(value.0); item.paletteLabel = L(value.0); item.image = NSImage(systemSymbolName:value.1,accessibilityDescription:L(value.0)); item.target = self; item.action = value.2; return item
    }
    func reloadSidebar() {
        let selected = (sidebar.item(atRow:sidebar.selectedRow) as? SidebarItem)?.url
        let collapsed = Set(sidebarItems.filter { !sidebar.isItemExpanded($0) }.map(\.title))
        let home = FileManager.default.homeDirectoryForCurrentUser
        sidebarItems = [
            SidebarItem(L("FAVORITES"), children:[SidebarItem(L("Home"),url:home,symbol:"house"),SidebarItem(L("Downloads"),url:home.appendingPathComponent("Downloads"),symbol:"arrow.down.circle"),SidebarItem(L("Desktop"),url:home.appendingPathComponent("Desktop"),symbol:"desktopcomputer")] + favorites.map { SidebarItem($0.lastPathComponent,url:$0,symbol:"folder") }),
            SidebarItem(L("VOLUMES"),children:(FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys:nil,options:[.skipHiddenVolumes]) ?? []).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }.map { SidebarItem($0.lastPathComponent,url:$0,symbol:"externaldrive") }),
            SidebarItem(L("RECENT"),children:recent.prefix(20).map { SidebarItem($0.lastPathComponent,url:$0) })
        ]
        reloadingSidebar = true
        sidebar.reloadData()
        for group in sidebarItems where !collapsed.contains(group.title) { sidebar.expandItem(group) }
        if let selected {
            for row in 0..<sidebar.numberOfRows where (sidebar.item(atRow:row) as? SidebarItem)?.url == selected {
                sidebar.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false); break
            }
        }
        reloadingSidebar = false
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? SidebarItem)?.children.count ?? sidebarItems.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? SidebarItem)?.children[index] ?? sidebarItems[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? SidebarItem)?.url == nil }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { (item as? SidebarItem)?.url == nil }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as? SidebarItem)?.url != nil }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? SidebarItem else { return nil }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString:item.title); label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize:item.url == nil ? 11 : 13,weight:item.url == nil ? .semibold : .regular)
        label.textColor = item.url == nil ? .secondaryLabelColor : .labelColor
        label.lineBreakMode = .byTruncatingMiddle; cell.textField = label; cell.addSubview(label); cell.toolTip = item.url?.path
        var leading = cell.leadingAnchor
        if let url = item.url {
            let icon = NSImageView(); icon.translatesAutoresizingMaskIntoConstraints = false
            icon.image = item.symbol.flatMap { NSImage(systemSymbolName:$0,accessibilityDescription:item.title) } ?? NSWorkspace.shared.icon(forFile:url.path)
            icon.contentTintColor = .controlAccentColor; cell.imageView = icon; cell.addSubview(icon)
            NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo:cell.leadingAnchor),icon.centerYAnchor.constraint(equalTo:cell.centerYAnchor),icon.widthAnchor.constraint(equalToConstant:18),icon.heightAnchor.constraint(equalToConstant:18)])
            leading = icon.trailingAnchor
        }
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo:leading,constant:item.url == nil ? 0 : 7),label.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-4),label.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !reloadingSidebar,let item = sidebar.item(atRow:sidebar.selectedRow) as? SidebarItem,let url = item.url else { return }
        open(url)
    }
    func remember(_ url: URL) {
        guard !url.path.hasPrefix(FileManager.default.temporaryDirectory.path) else { return }
        guard !recent.contains(url) else { return }
        recent.append(url); if recent.count > 20 { recent.removeFirst(recent.count - 20) }; UserDefaults.standard.set(recent.map(\.path),forKey:"recent"); reloadSidebar()
    }
    func open(_ url: URL, pane: BrowserPane? = nil) {
        let pane = pane ?? active!
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath:url.path,isDirectory:&isDir) else { showError(UIError(message:"The item no longer exists: \(url.path)")); return }
        if isDir.boolValue { pane.navigate(BrowserLocation(url:url,archive:false)) }
        else { pane.navigate(BrowserLocation(url:url,archive:true),password:archivePasswords[url]) }
        window?.representedURL = url
    }
    @objc func chooseOpen() { let p = NSOpenPanel(); p.canChooseDirectories = true; p.allowsMultipleSelection = false; if p.runModal() == .OK, let url = p.url { open(url) } }
    @objc func goBack() { active.go(-1) }
    @objc func goForward() { active.go(1) }
    @objc func goUp() { active.up() }
    @objc func refresh() { active.refresh() }
    @objc func toggleHiddenFiles() { active.showHidden.toggle(); UserDefaults.standard.set(active.showHidden,forKey:"showHiddenFiles"); active.refresh() }
    @objc func selectAllFiles() { active.table.selectAll(nil) }
    @objc func goToFolder() { if let path = prompt("Go to Folder or Archive",value:active.location.url.path) { open(URL(fileURLWithPath:(path as NSString).expandingTildeInPath)) } }
    @objc func toggleFlat() { active.flat.toggle(); active.flatButton.state = active.flat ? .on : .off; active.location.archive ? active.loadArchive() : active.loadDirectory() }
    @objc func toggleDual() { secondary.isHidden.toggle(); if secondary.isHidden { active = primary } else { panes.setPosition(panes.bounds.width / 2,ofDividerAt:0) } }
    @objc func favorite() { guard !active.location.archive else { return }; let url = active.location.url; if !favorites.contains(url) { favorites.append(url); UserDefaults.standard.set(favorites.map(\.path),forKey:"favorites"); reloadSidebar() } }
    func selectedURLs() -> [URL] { active.selected.compactMap(\.url) }
    func selectedArchiveURLs() -> [URL] { if active.location.archive { return [active.location.url] }; return active.selected.filter { !$0.directory }.compactMap(\.url) }
    @objc func openSelected() {
        guard let item = active.selected.first else { return }
        if item.directory {
            if active.location.archive { var location = active.location; location.inner = item.path; active.navigate(location,password:archivePasswords[location.url]) }
            else if let url = item.url { open(url) }
        } else if active.location.archive { materialize(item,mode:archiveExtensions.contains(URL(fileURLWithPath:item.path).pathExtension.lowercased()) ? .archive : .open) }
        else if let url = item.url {
            if archiveExtensions.contains(url.pathExtension.lowercased()) { open(url) } else { NSWorkspace.shared.open(url) }
        }
    }
    @objc func previewSelected() { guard let item = active.selected.first,!item.directory else { return }; if active.location.archive { materialize(item,mode:.preview) } else if let url = item.url { preview(url) } }
    func preview(_ url: URL) {
        if let app = configuredApplication("viewerAppPath") { openExternal(url,application:app); return }
        previewURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self; panel.delegate = self; panel.reloadData(); panel.makeKeyAndOrderFront(nil)
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { previewURL as NSURL? }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self; panel.delegate = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        let menu = NSMenuItem(title:item.label,action:item.action,keyEquivalent:""); return validateMenuItem(menu)
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let selection = active.selected
        let writable = !active.location.archive || (active.location.openMode == .automatic && ["7z","zip","tar","wim","gzip","bzip2","xz"].contains(archiveFormats[active.location.url] ?? active.location.url.pathExtension))
        switch menuItem.action {
        case #selector(deleteSelected),#selector(renameSelected): return !selection.isEmpty && writable
        case #selector(editSelected): return selection.count == 1 && !selection[0].directory && writable
        case #selector(extractSelected),#selector(testSelected): return active.location.archive || selection.contains { !$0.directory }
        case #selector(openSelected),#selector(previewSelected),#selector(hashSelected),#selector(copySelected),#selector(moveSelected): return !selection.isEmpty
        case #selector(splitSelected): return !active.location.archive && selection.count == 1 && !selection[0].directory
        case #selector(combineSelected): return !active.location.archive && selection.count == 1 && selection[0].url?.pathExtension == "001"
        case #selector(newFolder),#selector(newFile): return !active.location.archive || (writable && ["7z","zip","tar","wim"].contains(archiveFormats[active.location.url] ?? active.location.url.pathExtension))
        case #selector(showExtendedAttributes): return !active.location.archive && selection.count == 1
        case #selector(createLink): return !active.location.archive && selection.count == 1
        case #selector(finderComment): return selection.count == 1 && (!active.location.archive || (writable && ZipMemberComments.supports(archiveType:archiveFormats[active.location.url] ?? active.location.url.pathExtension)))
        case #selector(compareSelected): return selection.count == 2
        case #selector(openInside),#selector(openInsideAll),#selector(openInsideParser): return selection.count == 1 && !selection[0].directory
        case #selector(createChecksumManifest): return selection.contains { !$0.directory }
        case #selector(selectType),#selector(deselectType): return !selection.isEmpty
        case #selector(createExtractor as () -> Void): return active.location.archive && Bundle.main.bundleURL.pathExtension == "app"
        case #selector(showLargeIcons): menuItem.state = active.viewMode == .largeIcons ? .on : .off; return true
        case #selector(showSmallIcons): menuItem.state = active.viewMode == .smallIcons ? .on : .off; return true
        case #selector(showListView): menuItem.state = active.viewMode == .list ? .on : .off; return true
        case #selector(showDetailsView): menuItem.state = active.viewMode == .details ? .on : .off; return true
        case #selector(toggleAutoRefresh): menuItem.state = UserDefaults.standard.bool(forKey:"autoRefresh") ? .on : .off; return true
        case #selector(toggleArchiveToolbar): menuItem.state = UserDefaults.standard.bool(forKey:"hideArchiveToolbar") ? .off : .on; return true
        case #selector(toggleStandardToolbar): menuItem.state = UserDefaults.standard.bool(forKey:"hideStandardToolbar") ? .off : .on; return true
        case #selector(toggleButtonText): menuItem.state = UserDefaults.standard.bool(forKey:"hideToolbarText") ? .off : .on; return true
        case #selector(toggleLargeButtons): menuItem.state = UserDefaults.standard.bool(forKey:"largeToolbarButtons") ? .on : .off; return true
        case #selector(toggleFlat): menuItem.state = active.flat ? .on : .off; return true
        case #selector(toggleHiddenFiles): menuItem.state = active.showHidden ? .on : .off; return !active.location.archive
        default: return true
        }
    }
    @objc func editSelected() { guard let item = active.selected.first,!item.directory else { return }; if active.location.archive { materialize(item,mode:.edit) } else if let url = item.url { openEditor(url) } }
    @objc func properties() {
        let items = active.selected
        let alert = NSAlert(); alert.messageText = L("Properties")
        alert.informativeText = items.isEmpty ? active.location.url.path : LF("%@ selected item(s)",String(items.count))
        let report: String
        if active.location.archive { report = ArchivePropertyReport.make(archive:active.location.url,properties:active.archiveProperties,entries:active.entries,selected:items) }
        else {
            let urls = items.isEmpty ? [active.location.url] : items.compactMap(\.url)
            report = urls.map { url in
                let fields = (try? FileManager.default.attributesOfItem(atPath:url.path)) ?? [:]
                return url.path + "\n" + fields.keys.sorted(by:{ $0.rawValue < $1.rawValue }).map { "\($0.rawValue): \(fields[$0]!)" }.joined(separator:"\n")
            }.joined(separator:"\n\n")
        }
        let scroll = NSScrollView(frame:NSRect(x:0,y:0,width:640,height:440)); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let text = NSTextView(frame:scroll.contentView.bounds); text.string = report; text.isEditable = false; text.isSelectable = true; text.isRichText = false; text.font = .monospacedSystemFont(ofSize:12,weight:.regular)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true; text.textContainerInset = NSSize(width:8,height:8)
        scroll.documentView = text; alert.accessoryView = scroll
        let canEdit = !active.location.archive && !items.isEmpty
        if canEdit { alert.addButton(withTitle:L("Edit Properties…")) }
        alert.addButton(withTitle:L("Close"))
        if alert.runModal() == .alertFirstButtonReturn,canEdit { editableProperties(items) }
    }
    @objc func settings() {
        let f = FormDialog("7zip Mac Settings",message:"Native macOS integration is opt-in. No passwords are saved.")
        let viewer = f.field("Viewer app path",UserDefaults.standard.string(forKey:"viewerAppPath") ?? ""); viewer.placeholderString = L("Empty = native Quick Look; choose /Applications/…app")
        let editor = f.field("Editor app path",UserDefaults.standard.string(forKey:"editorAppPath") ?? ""); editor.placeholderString = L("Empty = default application")
        let diff = f.field("External diff program",UserDefaults.standard.string(forKey:"diffProgramPath") ?? ""); diff.placeholderString = L("Empty = built-in comparison; executable or .app path")
        let diffArguments = f.field("Diff arguments",UserDefaults.standard.string(forKey:"diffArguments") ?? ""); diffArguments.placeholderString = L("Arguments separated by spaces; the two paths are appended")
        let language = f.popup("Language",["简体中文","繁體中文","English"],selected:["zh-Hans":"简体中文","zh-Hant":"繁體中文","en":"English"][Localization.language] ?? "简体中文")
        let temp = f.path("Temporary folder",UserDefaults.standard.string(forKey:"temporaryBasePath") ?? FileManager.default.temporaryDirectory.path,directory:true)
        let automatic = f.check("Automatically refresh visible filesystem folders",UserDefaults.standard.bool(forKey:"autoRefresh"))
        let interval = f.field("Refresh seconds",String(max(2,UserDefaults.standard.integer(forKey:"refreshSeconds"))))
        let action = f.popup("Action",["Save preferences","Show integration settings","Register this application","Make default archive opener","Remove saved favorites and history","Clean temporary extracted files"])
        f.note("Finder Services: select files, then right-click → Services. Finder extension is optional and must be enabled in macOS Settings. Temporary files used for editing remain until cleanup or exit; finish editing before cleanup.")
        guard f.run() else { return }
        for path in [viewer.stringValue,editor.stringValue] where !path.isEmpty { guard FileManager.default.fileExists(atPath:path),URL(fileURLWithPath:path).pathExtension == "app" else { showError(UIError(message:"Choose an existing .app bundle for viewer/editor.")); return } }
        if !diff.stringValue.isEmpty && !FileManager.default.fileExists(atPath:diff.stringValue) { showError(UIError(message:"Choose an existing external diff program.")); return }
        guard let seconds = Int(interval.stringValue),(2...60).contains(seconds) else { showError(UIError(message:"Refresh interval must be between 2 and 60 seconds.")); return }
        var directory: ObjCBool = false; guard FileManager.default.fileExists(atPath:temp.stringValue,isDirectory:&directory),directory.boolValue else { showError(UIError(message:"The temporary folder must exist.")); return }
        UserDefaults.standard.set(diff.stringValue,forKey:"diffProgramPath"); UserDefaults.standard.set(diffArguments.stringValue,forKey:"diffArguments")
        let changedLanguage = Localization.language != ["zh-Hans","zh-Hant","en"][language.indexOfSelectedItem]
        Localization.setLanguage(["zh-Hans","zh-Hant","en"][language.indexOfSelectedItem])
        UserDefaults.standard.set(viewer.stringValue,forKey:"viewerAppPath"); UserDefaults.standard.set(editor.stringValue,forKey:"editorAppPath"); UserDefaults.standard.set(temp.stringValue,forKey:"temporaryBasePath"); UserDefaults.standard.set(automatic.state == .on,forKey:"autoRefresh"); UserDefaults.standard.set(seconds,forKey:"refreshSeconds"); configureAutoRefresh()
        if changedLanguage { reloadSidebar(); primary.relocalize(); secondary.relocalize(); rebuildToolbar() }
        switch action.indexOfSelectedItem {
        case 0: break
        case 1: SystemIntegration.showIntegrationSettings()
        case 2: SystemIntegration.registerApplication()
        case 3: if confirm("Change default archive opener?","Supported archive document types will open in 7zip Mac.") { SystemIntegration.setDefaultArchiveHandler() }
        case 4: favorites = []; recent = []; UserDefaults.standard.removeObject(forKey:"favorites"); UserDefaults.standard.removeObject(forKey:"recent"); reloadSidebar()
        default: if confirm("Clean temporary files?","Unsaved extracted edits will be removed.",destructive:true) { temporaryDirectories.forEach { try? FileManager.default.removeItem(at:$0) }; temporaryDirectories = [] }
        }
    }
    var temporaryBaseURL: URL { URL(fileURLWithPath:UserDefaults.standard.string(forKey:"temporaryBasePath") ?? FileManager.default.temporaryDirectory.path,isDirectory:true) }
    func configuredApplication(_ key: String) -> URL? { guard let path = UserDefaults.standard.string(forKey:key),!path.isEmpty else { return nil }; return URL(fileURLWithPath:path) }
    func openExternal(_ file: URL, application: URL) {
        NSWorkspace.shared.open([file],withApplicationAt:application,configuration:NSWorkspace.OpenConfiguration()) { _,error in if let error { DispatchQueue.main.async { showError(error) } } }
    }
    func openEditor(_ file: URL) { if let app = configuredApplication("editorAppPath") { openExternal(file,application:app) } else { NSWorkspace.shared.open(file) } }
    func configureAutoRefresh() {
        refreshTimer?.invalidate(); refreshTimer = nil
        guard UserDefaults.standard.bool(forKey:"autoRefresh") else { return }
        let seconds = TimeInterval(min(60,max(2,UserDefaults.standard.integer(forKey:"refreshSeconds"))))
        refreshTimer = Timer.scheduledTimer(withTimeInterval:seconds,repeats:true) { [weak self] _ in
            guard let self,!self.hasRunningOperations,NSApp.modalWindow == nil,self.window?.isVisible == true,NSApp.isActive else { return }
            let previous = self.active
            if !self.primary.location.archive { self.primary.loadDirectory() }
            if !self.secondary.isHidden && !self.secondary.location.archive { self.secondary.loadDirectory() }
            self.active = previous
        }
    }
    @objc func about() {
        let form = FormDialog("About 7zip Mac",message:"An independently developed native macOS interface using the official 7-Zip engine.")
        form.alert.buttons[0].title = L("Close"); form.alert.buttons[1].isHidden = true
        form.note(LF("Application version: %@",Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "26.04.2"))
        form.note("This application uses 7-Zip 26.04, Copyright (C) 1999–2026 Igor Pavlov")
        form.note("7-Zip uses GNU LGPL with BSD components and unRAR restrictions. Read the complete licenses. This local build has not been notarized by Apple.")
        let source = NSTextField(labelWithString: "")
        let attributes: [NSAttributedString.Key:Any] = [.link:URL(string:"https://github.com/ip7z/7zip")!, .foregroundColor:NSColor.linkColor]
        source.attributedStringValue = NSAttributedString(string:L("Official upstream: github.com/ip7z/7zip"),attributes:attributes)
        source.allowsEditingTextAttributes = true; source.isSelectable = true; form.stack.addArrangedSubview(source)
        let site = NSTextField(labelWithString:L("")); site.attributedStringValue = NSAttributedString(string:L("Official website: www.7-zip.org"),attributes:[.link:URL(string:"https://www.7-zip.org")!, .foregroundColor:NSColor.linkColor]); site.allowsEditingTextAttributes = true; site.isSelectable = true; form.stack.addArrangedSubview(site)
        let license = NSButton(title:L("Open Complete License.txt"),target:self,action:#selector(openLicense)); license.bezelStyle = .rounded; form.stack.addArrangedSubview(license); form.rows += 3
        _ = form.run()
    }
    @objc func openLicense() {
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("License.txt"), URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("License.txt")]
        for case let url? in candidates where FileManager.default.fileExists(atPath:url.path) { NSWorkspace.shared.open(url); return }
        showError(UIError(message:"Bundled License.txt could not be found."))
    }
    @objc func manual() {
        for url in [Bundle.main.resourceURL?.appendingPathComponent("MANUAL/start.htm"),URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("MANUAL/start.htm")] {
            if let url = url, FileManager.default.fileExists(atPath:url.path) { NSWorkspace.shared.open(url); return }
        }
        NSWorkspace.shared.open(URL(string:"https://www.7-zip.org/faq.html")!)
    }
    func route(_ action: IntegrationAction, urls: [URL]) {
        showWindow(nil); NSApp.activate(ignoringOtherApps:true)
        guard !urls.isEmpty else { chooseOpen(); return }
        switch action {
        case .open: open(urls[0])
        case .add: add(inputs:urls)
        case .quick7z,.quickZip: quickArchive(urls,format:action == .quickZip ? "zip" : "7z")
        case .extract: extractURLs(urls)
        case .extractHere,.extractFolder:
            for url in urls { var options = ExtractionOptions(destination:action == .extractHere ? url.deletingLastPathComponent() : url.deletingPathExtension()); options.password = archivePasswords[url] ?? ""; extract(url,options:options) }
        case .test: testURLs(urls)
        case .hash: hashURLs(urls)
        case .email: add(inputs:urls,email:true)
        }
    }
}

final class SidebarItem {
    let title: String
    let url: URL?
    let symbol: String?
    let children: [SidebarItem]
    init(_ title: String, url: URL? = nil, symbol: String? = nil, children: [SidebarItem] = []) {
        self.title = title; self.url = url; self.symbol = symbol; self.children = children
    }
}
