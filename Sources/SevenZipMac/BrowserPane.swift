import AppKit
import ArchiveCore

struct BrowserItem {
    var name: String
    var path: String
    var url: URL?
    var size: UInt64
    var packed: UInt64
    var directory: Bool
    var modified: String
    var encrypted: Bool
    var modifiedDate: Date? = nil
}
struct BrowserLocation {
    var url: URL
    var archive: Bool
    var inner: String = ""
    var openMode: ArchiveOpenMode = .automatic
}
/// Display roots are cosmetic: operations always receive the original archive path.
enum ArchiveBrowserTree {
    static func parent(of member: String) -> String {
        let path = member.trimmingCharacters(in:CharacterSet(charactersIn:"/"))
        guard let slash = path.lastIndex(of:"/") else { return "" }
        let parent = String(path[..<slash])
        return String(member.prefix(while:{ $0 == "/" })) + parent
    }
    static func items(entries: [ArchiveEntry], inner: String, flat: Bool) -> [BrowserItem] {
        var result: [String:BrowserItem] = [:]
        var directory = inner; while directory.hasSuffix("/") { directory.removeLast() }
        let prefix = directory.isEmpty ? "" : directory + "/"
        for entry in entries where entry.path.hasPrefix(prefix) {
            let rawRemaining = String(entry.path.dropFirst(prefix.count))
            let root = prefix.isEmpty ? String(rawRemaining.prefix(while:{ $0 == "/" })) : ""
            var display = String(rawRemaining.dropFirst(root.count))
            if entry.isDirectory { while display.hasSuffix("/") { display.removeLast() } }
            guard !display.isEmpty else { continue }
            if !flat,let slash = display.firstIndex(of:"/") {
                let name = String(display[..<slash]), path = prefix + root + name
                if result[path] == nil { result[path] = BrowserItem(name:name,path:path,url:nil,size:0,packed:0,directory:true,modified:"",encrypted:false) }
            } else {
                var key = entry.path; if entry.isDirectory { while key.hasSuffix("/") { key.removeLast() } }
                result[key] = BrowserItem(name:display,path:entry.path,url:nil,size:entry.size,packed:entry.packedSize,directory:entry.isDirectory,modified:BrowserTimeDisplay.display(entry.modified),encrypted:entry.encrypted,modifiedDate:BrowserTimeDisplay.parse(entry.modified))
            }
        }
        return Array(result.values)
    }
}
final class BrowserPane: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {
    weak var owner: MainWindowController?
    let pathField = NSTextField()
    let search = NSSearchField()
    let table = FileTableView()
    let collection = FileCollectionView()
    let scroll = NSScrollView()
    var viewMode = BrowserViewMode(rawValue: UserDefaults.standard.string(forKey:"browserViewMode") ?? "details") ?? .details
    var unsorted = false
    var synchronizingSelection = false
    let status = NSTextField(labelWithString: "")
    let flatButton = NSButton(checkboxWithTitle: "Flat", target: nil, action: nil)
    var location = BrowserLocation(url: FileManager.default.homeDirectoryForCurrentUser, archive: false)
    var entries: [ArchiveEntry] = []
    var archiveProperties: [String:String] = [:]
    var items: [BrowserItem] = []
    var visible: [BrowserItem] = []
    var history: [BrowserLocation] = []
    var historyIndex = -1
    var loadingControl: OperationControl?
    var generation = 0
    var flat = false
    var showHidden = UserDefaults.standard.bool(forKey:"showHiddenFiles")
    var selectionToRestore: Set<String> = []
    var suppressSelectionActivation = false
    var selected: [BrowserItem] { table.selectedRowIndexes.compactMap { visible.indices.contains($0) ? visible[$0] : nil } }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let up = NSButton(image: NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Up")!, target: self, action: #selector(upAction))
        up.bezelStyle = .texturedRounded; up.widthAnchor.constraint(equalToConstant: 32).isActive = true
        pathField.placeholderString = L("Folder or archive path"); pathField.target = self; pathField.action = #selector(pathEntered)
        pathField.font = .systemFont(ofSize: 12)
        search.placeholderString = L("Search files"); search.delegate = self; search.widthAnchor.constraint(equalToConstant: 155).isActive = true
        flatButton.target = self; flatButton.action = #selector(flatChanged)
        let top = NSStackView(views: [up,pathField,search,flatButton]); top.orientation = .horizontal; top.spacing = 6
        let columns: [(String,String,CGFloat)] = [("name","Name",260),("size","Size",90),("packed","Packed",90),("modified","Modified",145),("kind","Kind",90)]
        for (id,title,width) in columns {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); c.title = L(title); c.width = width
            c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true); table.addTableColumn(c)
        }
        table.delegate = self; table.dataSource = self; table.allowsMultipleSelection = true; table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 25; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.target = self; table.doubleAction = #selector(openSelection); table.registerForDraggedTypes([.fileURL])
        table.setAccessibilityLabel("Files")
        let menu = NSMenu()
        for (title,selector) in [("Open",#selector(MainWindowController.openSelected)),("Preview",#selector(MainWindowController.previewSelected)),("Add to Archive…",#selector(MainWindowController.addArchive)),("Extract…",#selector(MainWindowController.extractSelected)),("Test",#selector(MainWindowController.testSelected)),("Checksums…",#selector(MainWindowController.hashSelected)),("Rename…",#selector(MainWindowController.renameSelected)),("Copy to…",#selector(MainWindowController.copySelected)),("Move to…",#selector(MainWindowController.moveSelected)),("Delete…",#selector(MainWindowController.deleteSelected)),("Properties",#selector(MainWindowController.properties))] {
            let m = NSMenuItem(title: L(title),action: selector,keyEquivalent: ""); menu.addItem(m)
        }
        table.menu = menu
        collection.dataSource = self; collection.delegate = self; collection.isSelectable = true; collection.allowsMultipleSelection = true
        collection.register(FileIconItem.self, forItemWithIdentifier: .init("file")); collection.backgroundColors = [.textBackgroundColor]
        collection.registerForDraggedTypes([.fileURL]); collection.menu = menu.copy() as? NSMenu
        applyViewMode()
        scroll.documentView = viewMode == .details || viewMode == .list ? table : collection; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        for v in [top,scroll,status] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([top.leadingAnchor.constraint(equalTo: leadingAnchor,constant: 8),top.trailingAnchor.constraint(equalTo: trailingAnchor,constant: -8),top.topAnchor.constraint(equalTo: topAnchor,constant: 8),scroll.leadingAnchor.constraint(equalTo: leadingAnchor,constant: 8),scroll.trailingAnchor.constraint(equalTo: trailingAnchor,constant: -8),scroll.topAnchor.constraint(equalTo: top.bottomAnchor,constant: 8),scroll.bottomAnchor.constraint(equalTo: status.topAnchor,constant: -6),status.leadingAnchor.constraint(equalTo: leadingAnchor,constant: 12),status.bottomAnchor.constraint(equalTo: bottomAnchor,constant: -8)])
    }
    required init?(coder: NSCoder) { fatalError() }
    func connect(_ owner: MainWindowController) {
        self.owner = owner; table.pane = self; collection.pane = self; relocalize()
        table.menu?.items.forEach { $0.target = owner }; collection.menu?.items.forEach { $0.target = owner }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = visible[row]; let id = tableColumn?.identifier.rawValue ?? "name"
        let cell = NSTableCellView(); let label = NSTextField(labelWithString: ""); label.lineBreakMode = .byTruncatingMiddle; label.font = .systemFont(ofSize: CGFloat(max(12,UserDefaults.standard.integer(forKey:"fileFontSize")))); label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        if id == "name" {
            label.stringValue = item.name
            let icon = NSImageView(); icon.translatesAutoresizingMaskIntoConstraints = false
            icon.image = item.url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: item.directory ? "folder.fill" : (item.encrypted ? "lock.doc" : "doc"), accessibilityDescription: nil)
            cell.addSubview(icon)
            NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor,constant: 4),icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),icon.widthAnchor.constraint(equalToConstant: 18),icon.heightAnchor.constraint(equalToConstant: 18),label.leadingAnchor.constraint(equalTo: icon.trailingAnchor,constant: 6)])
        } else {
            switch id {
            case "size": label.stringValue = item.directory ? "—" : ByteCountFormatter.string(fromByteCount: Int64(clamping: item.size),countStyle: .file); label.alignment = .right
            case "packed": label.stringValue = location.archive && !item.directory ? ByteCountFormatter.string(fromByteCount: Int64(clamping: item.packed),countStyle: .file) : "—"; label.alignment = .right
            case "modified": label.stringValue = item.modified
            default: label.stringValue = item.directory ? L("Folder") : (URL(fileURLWithPath: item.path).pathExtension.uppercased().isEmpty ? L("File") : URL(fileURLWithPath: item.path).pathExtension.uppercased())
            }
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor,constant: 5).isActive = true
        }
        NSLayoutConstraint.activate([label.trailingAnchor.constraint(equalTo: cell.trailingAnchor,constant: -6),label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if !suppressSelectionActivation { owner?.active = self }
        if !synchronizingSelection { synchronizingSelection = true; collection.selectionIndexPaths = Set(table.selectedRowIndexes.map { IndexPath(item:$0,section:0) }); synchronizingSelection = false }
        updateStatus()
    }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { filter() }
    func controlTextDidChange(_ obj: Notification) { owner?.active = self; filter() }
    func filter() {
        let selectedPaths = Set(selected.map(\.path)).union(selectionToRestore)
        selectionToRestore = []
        let query = search.stringValue
        visible = items.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        let sort = table.sortDescriptors.first; let key = sort?.key ?? "name"; let ascending = sort?.ascending ?? true
        if !unsorted { visible.sort {
            if $0.directory != $1.directory { return $0.directory }
            let order: ComparisonResult
            switch key {
            case "size": order = $0.size == $1.size ? $0.name.localizedStandardCompare($1.name) : ($0.size < $1.size ? .orderedAscending : .orderedDescending)
            case "packed": order = $0.packed == $1.packed ? $0.name.localizedStandardCompare($1.name) : ($0.packed < $1.packed ? .orderedAscending : .orderedDescending)
            case "modified": let a = $0.modifiedDate ?? .distantPast, b = $1.modifiedDate ?? .distantPast; order = a == b ? $0.name.localizedStandardCompare($1.name) : (a < b ? .orderedAscending : .orderedDescending)
            case "kind": order = URL(fileURLWithPath:$0.path).pathExtension.compare(URL(fileURLWithPath:$1.path).pathExtension)
            default: order = $0.name.localizedStandardCompare($1.name)
            }
            return order == (ascending ? .orderedAscending : .orderedDescending)
        }
        }
        suppressSelectionActivation = true; table.reloadData(); collection.reloadData(); table.selectRowIndexes(IndexSet(visible.indices.filter { selectedPaths.contains(visible[$0].path) }),byExtendingSelection:false); suppressSelectionActivation = false; updateStatus()
    }
    func updateStatus() {
        let selectedSize = selected.reduce(UInt64(0)) { $0 &+ $1.size }
        status.stringValue = LF("%@ items",String(visible.count)) + (selected.isEmpty ? "" : LF(" · %@ selected · %@",String(selected.count),ByteCountFormatter.string(fromByteCount:Int64(clamping:selectedSize),countStyle:.file))) + (location.archive ? L(" · Archive") : "")
    }
    func navigate(_ location: BrowserLocation, record: Bool = true, password: String? = nil) {
        owner?.active = self; loadingControl?.cancel(); generation += 1; let current = generation
        if record {
            if historyIndex + 1 < history.count { history.removeSubrange((historyIndex + 1)..<history.count) }
            history.append(location); historyIndex = history.count - 1
        }
        selectionToRestore = !record && self.location.url == location.url && self.location.inner == location.inner ? Set(selected.map(\.path)) : []
        self.location = location; entries = []; archiveProperties = [:]; items = []; visible = []; suppressSelectionActivation = true; table.deselectAll(nil); table.reloadData(); collection.reloadData(); suppressSelectionActivation = false; pathField.stringValue = location.url.path + (location.archive ? " / " + location.inner : "")
        if !location.archive { loadDirectory(); owner?.remember(location.url); return }
        status.stringValue = L("Reading archive…")
        let control = OperationControl(); loadingControl = control
        Task { @MainActor in
            do {
                guard let engine = owner?.engine else { throw UIError(message: "7zz could not be found. See Settings.") }
                let listing = try await engine.list(archive: location.url,password: password,openMode:location.openMode,control: control)
                guard generation == current else { return }
                entries = listing.entries; archiveProperties = listing.properties; owner?.archiveFormats[location.url] = listing.properties["Type"]; loadArchive(); owner?.remember(location.url)
            } catch {
                guard generation == current else { return }
                status.stringValue = L("Could not read archive"); items = []; filter()
                if password == nil && confirm("Cannot read archive", error.localizedDescription + "\nTry a password?") {
                    let a = NSAlert(); a.messageText = L("Archive Password"); let f = NSSecureTextField(frame: NSRect(x:0,y:0,width:320,height:24)); a.accessoryView = f; a.addButton(withTitle: "Open"); a.addButton(withTitle: "Cancel")
                    if a.runModal() == .alertFirstButtonReturn { owner?.archivePasswords[location.url] = f.stringValue; navigate(location,record:false,password:f.stringValue) }
                } else { showError(error) }
            }
        }
    }
    func loadDirectory() {
        do {
            let keys: [URLResourceKey] = [.isDirectoryKey,.fileSizeKey,.contentModificationDateKey,.isSymbolicLinkKey]
            let urls: [URL]
            if flat { urls = (FileManager.default.enumerator(at: location.url,includingPropertiesForKeys: keys,options:showHidden ? [.skipsPackageDescendants] : [.skipsHiddenFiles,.skipsPackageDescendants])?.allObjects as? [URL]) ?? [] }
            else { urls = try FileManager.default.contentsOfDirectory(at: location.url,includingPropertiesForKeys: keys,options:showHidden ? [] : [.skipsHiddenFiles]) }
            let formatter = BrowserTimeDisplay.formatter()
            items = urls.compactMap { url in
                guard let r = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                let relative = flat ? String(url.path.dropFirst(location.url.path.count + 1)) : url.lastPathComponent
                return BrowserItem(name:relative,path:url.path,url:url,size:UInt64(max(0,r.fileSize ?? 0)),packed:0,directory:r.isDirectory == true,modified:r.contentModificationDate.map(formatter.string) ?? "",encrypted:false,modifiedDate:r.contentModificationDate)
            }
            filter()
        } catch { showError(error) }
    }
    func loadArchive() {
        items = ArchiveBrowserTree.items(entries:entries,inner:location.inner,flat:flat); filter()
    }
    func refresh() { navigate(location,record:false,password:owner?.archivePasswords[location.url]) }
    func go(_ delta: Int) { let next = historyIndex + delta; guard history.indices.contains(next) else { return }; historyIndex = next; navigate(history[next],record:false,password:owner?.archivePasswords[history[next].url]) }
    func up() {
        if location.archive && !location.inner.isEmpty {
            var l = location; l.inner = ArchiveBrowserTree.parent(of:l.inner); navigate(l,password:owner?.archivePasswords[l.url])
        } else if location.archive, let parent = owner?.nestedParents[location.url] { navigate(parent,password:owner?.archivePasswords[parent.url]) }
        else { navigate(BrowserLocation(url:location.url.deletingLastPathComponent(),archive:false)) }
    }
    func relocalize() {
        pathField.placeholderString = L("Folder or archive path"); search.placeholderString = L("Search files"); flatButton.title = L("Flat")
        let titles = ["name":"Name","size":"Size","packed":"Packed","modified":"Modified","kind":"Kind"]
        table.tableColumns.forEach { $0.title = L(titles[$0.identifier.rawValue] ?? "Name") }; filter()
    }
    func setViewMode(_ mode: BrowserViewMode) { viewMode = mode; UserDefaults.standard.set(mode.rawValue,forKey:"browserViewMode"); applyViewMode(); filter() }
    func applyViewMode() {
        let paths = Set(selected.map(\.path))
        if viewMode == .largeIcons || viewMode == .smallIcons {
            let layout = NSCollectionViewFlowLayout(); layout.itemSize = viewMode == .largeIcons ? NSSize(width:112,height:108) : NSSize(width:220,height:36)
            layout.minimumInteritemSpacing = 8; layout.minimumLineSpacing = 6; layout.sectionInset = NSEdgeInsets(top:8,left:8,bottom:8,right:8)
            collection.collectionViewLayout = layout
            // Installing the first layout switches AppKit from its legacy core;
            // item registration must happen after that switch.
            collection.register(FileIconItem.self,forItemWithIdentifier:.init("file")); scroll.documentView = collection
        } else {
            table.tableColumns.forEach { $0.isHidden = viewMode == .list && $0.identifier.rawValue != "name" }
            if viewMode == .details { let hidden = Set(UserDefaults.standard.stringArray(forKey:"hiddenColumns") ?? []); table.tableColumns.forEach { $0.isHidden = hidden.contains($0.identifier.rawValue) && $0.identifier.rawValue != "name" } }
            scroll.documentView = table
        }
        let size = CGFloat(max(10,UserDefaults.standard.integer(forKey:"fileFontSize")))
        table.rowHeight = max(25,size + 10); table.font = .systemFont(ofSize:size)
        selectionToRestore = paths
    }
    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { visible.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier:.init("file"),for:indexPath) as! FileIconItem
        cell.configure(visible[indexPath.item],large:viewMode == .largeIcons); return cell
    }
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { syncCollectionSelection() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { syncCollectionSelection() }
    func syncCollectionSelection() {
        guard !synchronizingSelection else { return }; synchronizingSelection = true
        table.selectRowIndexes(IndexSet(collection.selectionIndexPaths.map(\.item)),byExtendingSelection:false); synchronizingSelection = false
        owner?.active = self; updateStatus()
    }
    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? { visible[indexPath.item].url as NSURL? }
    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo, proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation { .copy }
    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool { tableView(table,acceptDrop:draggingInfo,row:0,dropOperation:.above) }
    @objc func upAction() { up() }
    @objc func pathEntered() { owner?.open(URL(fileURLWithPath: (pathField.stringValue as NSString).expandingTildeInPath),pane:self) }
    @objc func flatChanged() { owner?.active = self; flat = flatButton.state == .on; location.archive ? loadArchive() : loadDirectory() }
    @objc func openSelection() { owner?.active = self; owner?.openSelected() }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? { visible[row].url as NSURL? }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation { .copy }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL], !urls.isEmpty else { return false }
        owner?.active = self
        if location.archive { owner?.add(inputs:urls,proposed:location.url,memberPrefix:location.inner) }
        else if urls.count == 1 { owner?.open(urls[0],pane:self) }
        else { owner?.add(inputs:urls) }
        return true
    }
}

final class FileTableView: NSTableView {
    weak var pane: BrowserPane?
    override func mouseDown(with event: NSEvent) { pane?.owner?.active = pane; super.mouseDown(with:event) }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); if result { pane?.owner?.active = pane }; return result }
    @objc func copy(_ sender: Any?) { pane?.owner?.active = pane; pane?.owner?.copyFilesToClipboard() }
    @objc func cut(_ sender: Any?) { pane?.owner?.active = pane; pane?.owner?.cutFilesToClipboard() }
    @objc func paste(_ sender: Any?) { pane?.owner?.active = pane; pane?.owner?.pasteFilesFromClipboard() }
    @objc func pasteMoving(_ sender: Any?) { pane?.owner?.active = pane; pane?.owner?.pasteFilesFromClipboard(forceMove:true) }
    override func menu(for event: NSEvent) -> NSMenu? {
        pane?.owner?.active = pane
        let index = row(at:convert(event.locationInWindow,from:nil))
        if index >= 0 && !selectedRowIndexes.contains(index) { selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false) }
        else if index < 0 { deselectAll(nil) }
        return super.menu(for:event)
    }
}

final class FileIconItem: NSCollectionViewItem {
    override func loadView() {
        view = NSView(); view.wantsLayer = true; view.layer?.cornerRadius = 7
        let icon = NSImageView(), label = NSTextField(labelWithString:L("")); label.lineBreakMode = .byTruncatingMiddle
        view.addSubview(icon); view.addSubview(label); imageView = icon; textField = label
    }
    func configure(_ item: BrowserItem, large: Bool) {
        imageView!.image = item.url.map { NSWorkspace.shared.icon(forFile:$0.path) } ?? NSImage(systemSymbolName:item.directory ? "folder.fill" : (item.encrypted ? "lock.doc" : "doc"),accessibilityDescription:nil)
        textField!.stringValue = item.name; textField!.font = .systemFont(ofSize:CGFloat(max(11,UserDefaults.standard.integer(forKey:"fileFontSize"))))
        textField!.alignment = large ? .center : .left
        if large { imageView!.frame = NSRect(x:30,y:38,width:52,height:52); textField!.frame = NSRect(x:4,y:5,width:104,height:30); textField!.maximumNumberOfLines = 2 }
        else { imageView!.frame = NSRect(x:7,y:6,width:24,height:24); textField!.frame = NSRect(x:39,y:8,width:175,height:22); textField!.maximumNumberOfLines = 1 }
        view.setAccessibilityLabel(item.name); highlight()
    }
    override var isSelected: Bool { didSet { highlight() } }
    private func highlight() { view.layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor.cgColor : NSColor.clear.cgColor; textField?.textColor = isSelected ? .alternateSelectedControlTextColor : .labelColor }
}
final class FileCollectionView: NSCollectionView {
    weak var pane: BrowserPane?
    override func mouseDown(with event: NSEvent) { pane?.owner?.active = pane; super.mouseDown(with:event); if event.clickCount == 2 { pane?.openSelection() } }
    override func becomeFirstResponder() -> Bool { let ok = super.becomeFirstResponder(); if ok { pane?.owner?.active = pane }; return ok }
    override func keyDown(with event: NSEvent) { if event.keyCode == 36 { pane?.openSelection() } else { super.keyDown(with:event) } }
    override func menu(for event: NSEvent) -> NSMenu? {
        if let pane { pane.owner?.active = pane; if let index = indexPathForItem(at:convert(event.locationInWindow,from:nil)) { if !selectionIndexPaths.contains(index) { selectionIndexPaths = [index]; pane.syncCollectionSelection() } } }
        return super.menu(for:event)
    }
    @objc func copy(_ sender: Any?) { pane?.owner?.copyFilesToClipboard() }
    @objc func cut(_ sender: Any?) { pane?.owner?.cutFilesToClipboard() }
    @objc func paste(_ sender: Any?) { pane?.owner?.pasteFilesFromClipboard() }
}
