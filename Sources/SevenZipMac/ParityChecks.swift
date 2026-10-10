import AppKit
import ArchiveCore

/// Objective checks for native presentation and conflict-aware file workflows.
/// AppKit controls are constructed on the main thread without showing a window.
enum ParityChecks {
    static func run(in temporaryRoot: URL) throws {
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else { throw UIError(message:"FAIL: " + label) }; print("PASS: " + label)
        }
        try reservationAliases(in:temporaryRoot,expect: { value,label in try expect(value,label) })
        let entries = [ArchiveEntry(path:"/Volumes/源目录/folder/file.txt",size:7),ArchiveEntry(path:"/Volumes/源目录/empty/",isDirectory:true),ArchiveEntry(path:"relative.txt",size:3)]
        let top = ArchiveBrowserTree.items(entries:entries,inner:"",flat:false)
        try expect(top.contains(where:{ $0.name == "Volumes" && $0.path == "/Volumes" && $0.directory }) && !top.contains(where:{ $0.name.isEmpty }),"absolute archive tree hides display root and preserves raw directory path")
        let nested = ArchiveBrowserTree.items(entries:entries,inner:"/Volumes/源目录/folder",flat:false)
        try expect(nested.count == 1 && nested[0].name == "file.txt" && nested[0].path == entries[0].path,"absolute archive navigation retains exact leaf member path")
        let empty = ArchiveBrowserTree.items(entries:entries,inner:"/Volumes/源目录",flat:false)
        try expect(empty.contains(where:{ $0.name == "empty" && $0.path == "/Volumes/源目录/empty/" }),"explicit empty archive directories preserve raw trailing slash")
        let flat = ArchiveBrowserTree.items(entries:entries,inner:"",flat:true)
        try expect(flat.contains(where:{ $0.name == "Volumes/源目录/folder/file.txt" && $0.path == entries[0].path }),"flat absolute archive labels preserve operation paths")
        try expect(ArchiveBrowserTree.parent(of:"/Volumes/源目录/folder/") == "/Volumes/源目录" && ArchiveBrowserTree.parent(of:"/Volumes") == "" && ArchiveBrowserTree.parent(of:"folder/sub") == "folder","absolute archive Up reaches root without a double-slash prefix")

        let members = (0..<12).map { ArchiveEntry(path:"folder/item\($0).txt",size:UInt64($0),properties:["CRC":"checksum-\($0)","Method":"method-\($0)","Custom Field":"custom-\($0)"]) }
        let selected = members.map { BrowserItem(name:$0.path,path:$0.path,url:nil,size:$0.size,packed:0,directory:false,modified:"",encrypted:false) }
        let report = ArchivePropertyReport.make(archive:temporaryRoot.appendingPathComponent("properties.7z"),properties:["Type":"7z","Headers Size":"123","Physical Size":"456","Custom Archive Field":"retain-me"],entries:members,selected:selected)
        try expect(report.contains("Custom Archive Field: retain-me") && report.contains("Headers Size: 123") && report.contains("Physical Size: 456"),"properties retain every archive technical field")
        try expect(members.allSatisfy({ report.contains("Path: " + $0.path + "\n") && report.contains("Custom Field: " + $0.properties["Custom Field"]!) }),"properties retain all twelve selected members and custom fields")
        let folder = BrowserItem(name:"folder",path:"folder",url:nil,size:0,packed:0,directory:true,modified:"",encrypted:false)
        let subtreeReport = ArchivePropertyReport.make(archive:temporaryRoot.appendingPathComponent("properties.7z"),properties:[:],entries:members,selected:[folder,selected[0]])
        try expect(subtreeReport.components(separatedBy:"Path: folder/item0.txt\n").count == 2 && subtreeReport.contains("Custom Field: custom-11"),"properties expand selected virtual folders and deduplicate overlapping selections")

        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let preferenceKeys = ["uiLanguage","browserViewMode","hiddenColumns","fileFontSize"]
        let previous = Dictionary(uniqueKeysWithValues:preferenceKeys.compactMap { key in defaults.object(forKey:key).map { (key,$0) } })
        defer { for key in preferenceKeys { if let value = previous[key] { defaults.set(value,forKey:key) } else { defaults.removeObject(forKey:key) } } }
        for language in Localization.supportedLanguages {
            defaults.set(language,forKey:"uiLanguage")
            let popup = FormDialog("Properties").popup("Overwrite",["Skip","Overwrite","Rename incoming item","Rename existing item"],selected:"Rename incoming item")
            try expect(popup.selectedValue == "Rename incoming item" && popup.titleOfSelectedItem == L("Rename incoming item"),"\(language) popup separates translated label from canonical action")
            for (index,value) in ["Skip","Overwrite","Rename incoming item","Rename existing item"].enumerated() { popup.selectItem(at:index); try expect(popup.selectedValue == value,"\(language) popup canonical action \(index)") }
        }
        defaults.set([],forKey:"hiddenColumns")
        defaults.set("details",forKey:"browserViewMode")
        let pane = BrowserPane(frame:NSRect(x:0,y:0,width:700,height:500))
        pane.layoutSubtreeIfNeeded(); pane.scroll.frame = NSRect(x:8,y:30,width:684,height:420); pane.collection.frame = pane.scroll.contentView.bounds
        pane.items = selected; pane.filter(); pane.table.selectRowIndexes(IndexSet([1,5]),byExtendingSelection:false)
        let selectedPaths = Set(pane.selected.map(\.path))
        for mode in BrowserViewMode.allCases {
            pane.setViewMode(mode)
            if mode == .largeIcons || mode == .smallIcons {
                let layout = pane.collection.collectionViewLayout as? NSCollectionViewFlowLayout
                try expect(pane.scroll.documentView === pane.collection && layout?.itemSize == (mode == .largeIcons ? NSSize(width:112,height:108) : NSSize(width:220,height:36)),"\(mode.rawValue) uses its native collection layout")
                // Exercise AppKit's registered item factory, which can fail even
                // when the collection's layout and data source look correct.
                let cell = pane.collectionView(pane.collection,itemForRepresentedObjectAt:IndexPath(item:1,section:0)) as? FileIconItem
                try expect(cell?.textField?.stringValue == pane.visible[1].name && cell?.imageView?.image != nil && cell?.imageView?.superview === cell?.view && cell?.textField?.superview === cell?.view,"\(mode.rawValue) constructs a native item with retained icon and filename views")
                try expect(cell?.imageView?.frame.size == (mode == .largeIcons ? NSSize(width:52,height:52) : NSSize(width:24,height:24)) && cell?.textField?.maximumNumberOfLines == (mode == .largeIcons ? 2 : 1),"\(mode.rawValue) renders the matching icon and label geometry")
            } else {
                let visibleColumns = pane.table.tableColumns.filter { !$0.isHidden }.map { $0.identifier.rawValue }
                try expect(pane.scroll.documentView === pane.table && visibleColumns.count == (mode == .list ? 1 : 5) && visibleColumns.contains("name"),"\(mode.rawValue) uses the expected native table columns")
                let column = pane.table.tableColumns.first(where:{ $0.identifier.rawValue == "name" })!
                let cell = pane.tableView(pane.table,viewFor:column,row:1)
                try expect(cell?.subviews.contains(where:{ ($0 as? NSTextField)?.stringValue == pane.visible[1].name }) == true && cell?.subviews.contains(where:{ ($0 as? NSImageView)?.image != nil }) == true,"\(mode.rawValue) constructs a native filename row with an icon")
            }
            try expect(Set(pane.selected.map(\.path)) == selectedPaths && pane.collection.selectionIndexPaths == Set(pane.table.selectedRowIndexes.map { IndexPath(item:$0,section:0) }),"\(mode.rawValue) preserves and synchronizes multiple selection")
        }
        try compressionControls { value,label in try expect(value,label) }
        try expect(ProgressController.durationText(3661) == "01:01:01" && ProgressController.durationText(-1) == "—" && ProgressController.durationText(.infinity) == "—","progress duration handles hours and invalid estimates")
        try transfers(in:temporaryRoot) { value,label in try expect(value,label) }
    }

    private static func reservationAliases(in root: URL, expect: (Bool,String) throws -> Void) throws {
        let rawRoot = root.path.hasPrefix("/private/var/") ? String(root.path.dropFirst("/private".count)) : root.path
        guard rawRoot.hasPrefix("/var/") else { throw UIError(message:"FAIL: reservation fixture needs the macOS /var alias") }
        let missing = URL(fileURLWithPath:rawRoot).appendingPathComponent("reservation-missing/folder")
        let privateMissing = URL(fileURLWithPath:"/private" + missing.path)
        let tmpMissing = URL(fileURLWithPath:"/tmp").appendingPathComponent("SevenZip-reservation-" + UUID().uuidString).appendingPathComponent("folder")
        let privateTmpMissing = URL(fileURLWithPath:"/private" + tmpMissing.path)
        for (name,alias,canonical) in [("/var",missing,privateMissing),("/tmp",tmpMissing,privateTmpMissing)] {
            let reservations = OperationReservations(), aliasChild = alias.appendingPathComponent("nested/output.7z"), canonicalChild = canonical.appendingPathComponent("nested/output.7z")
            guard let mutation = reservations.reserveMutation(alias) else { throw UIError(message:"FAIL: initial alias mutation reservation") }
            try expect(reservations.reserveMutation(canonical) == nil && reservations.reserveDestination(canonicalChild) == nil,name + " missing mutation blocks alias mutation and descendant extraction")
            reservations.release(mutation)
            guard let destination = reservations.reserveDestination(canonicalChild) else { throw UIError(message:"FAIL: released alias mutation still blocks extraction") }
            try expect(reservations.reserveMutation(alias) == nil,name + " missing extraction blocks ancestor alias mutation")
            reservations.release(destination)
            guard let childMutation = reservations.reserveMutation(aliasChild) else { throw UIError(message:"FAIL: initial descendant alias mutation reservation") }
            try expect(reservations.reserveDestination(canonical) == nil,name + " missing descendant mutation blocks ancestor alias extraction")
            reservations.release(childMutation)
            guard let parentDestination = reservations.reserveDestination(canonical) else { throw UIError(message:"FAIL: released descendant mutation still blocks extraction") }
            try expect(reservations.reserveMutation(aliasChild) == nil && reservations.reserveDestination(aliasChild) == nil,name + " missing ancestor extraction blocks descendant alias mutation and extraction")
            reservations.release(parentDestination)
            guard let reacquired = reservations.reserveMutation(canonicalChild) else { throw UIError(message:"FAIL: released ancestor extraction still blocks alias mutation") }
            reservations.release(reacquired)
            try expect(true,name + " alias reservations are available again after release")
        }
        let reservations = OperationReservations(), nfc = root.appendingPathComponent("reservation-unicode/café.7z"), nfd = root.appendingPathComponent("reservation-unicode/cafe\u{301}.7z")
        guard let token = reservations.reserveMutation(nfc) else { throw UIError(message:"FAIL: initial NFC reservation") }
        try expect(reservations.reserveMutation(nfd) == nil && reservations.reserveDestination(nfd) == nil,"nonexistent NFC and NFD output names share a mutation reservation")
        reservations.release(token)
        guard let destination = reservations.reserveDestination(nfd) else { throw UIError(message:"FAIL: released NFC reservation still blocks NFD extraction") }
        try expect(reservations.reserveMutation(nfc) == nil,"nonexistent NFD extraction blocks NFC mutation")
        reservations.release(destination)
        guard let reacquired = reservations.reserveMutation(nfc) else { throw UIError(message:"FAIL: released NFD extraction still blocks NFC mutation") }
        reservations.release(reacquired)
        try expect(true,"Unicode output reservations are available again after release")
    }

    private static func compressionControls(expect: (Bool,String) throws -> Void) throws {
        let form = FormDialog("Add to Archive")
        let format = form.popup("Format",["7z","tar","wim"],selected:"tar"), method = form.popup("Method",["Automatic"])
        let timestamps = ["Modified","Created","Accessed"].map { form.popup($0,["Automatic","On","Off"]) }
        let memory = NSTextField(string:"p60")
        let controller = CompressionFormatController(format:format,method:method,solid:form.popup("Solid",["on","off"]),headers:NSButton(),encryption:form.popup("Encryption",["AES256"]),password:NSSecureTextField(),repeatPassword:NSSecureTextField(),dictionary:NSTextField(),word:NSTextField(),path:NSTextField(string:"/tmp/check.tar"),symbolic:NSButton(),hard:NSButton(),timestamps:timestamps,precision:form.popup("Precision",["Automatic"]),memory:memory)
        controller.update()
        try expect(method.itemArray.compactMap { $0.representedObject as? String } == ["Automatic","gnu","pax"],"TAR compression exposes official GNU and PAX methods")
        method.selectItem(at:2); controller.update()
        try expect(timestamps[2].isEnabled && !timestamps[1].isEnabled,"PAX access time is available while unsupported creation time is disabled")
        format.selectItem(at:2); controller.update()
        try expect(!memory.isEnabled,"WIM disables unsupported compression memory budget")
    }

    private static func transfers(in root: URL,expect: (Bool,String) throws -> Void) throws {
        let manager = FileManager.default
        func fixture(_ name: String) throws -> (URL,URL,URL,URL) {
            let base = root.resolvingSymlinksInPath().appendingPathComponent(name), source = base.appendingPathComponent("source/folder"), destination = base.appendingPathComponent("destination")
            let target = destination.appendingPathComponent("folder")
            try manager.createDirectory(at:source,withIntermediateDirectories:true); try manager.createDirectory(at:target,withIntermediateDirectories:true)
            try Data("incoming-content".utf8).write(to:source.appendingPathComponent("x.txt"))
            try Data("existing-content".utf8).write(to:target.appendingPathComponent("x.txt"))
            try Data("existing-sibling".utf8).write(to:target.appendingPathComponent("keep.txt"))
            return (source,destination,source.appendingPathComponent("x.txt"),target.appendingPathComponent("x.txt"))
        }
        let (source,destination,leaf,existing) = try fixture("rename-transfer")
        let executor = FileTransferExecutor(inputs:[source],destination:destination,move:false,control:OperationControl(),decide:{ _ in ExtractionConflictResolution(action:.renameExtracted) },report:{ _ in })
        let result = try UIWorkflowChecks.awaitResult { try await executor.run() }
        guard let renamed = mappedTransferPath(leaf,mapping:result.outputs) else { throw UIError(message:"FAIL: transfer omitted renamed leaf mapping for \(leaf.path); outputs=\(result.outputs)") }
        try expect(renamed.lastPathComponent == "x_1.txt" && mappedTransferPath(source,mapping:result.outputs)?.path == destination.appendingPathComponent("folder").path,"folder merge records actual renamed leaf and directory destinations")
        try verifyTransferredItem(source,destination.appendingPathComponent("folder"),mapping:result.outputs)
        print("PASS: merged folder verification reads renamed incoming leaf instead of old destination")
        let oldBytes = try Data(contentsOf:existing), siblingBytes = try Data(contentsOf:existing.deletingLastPathComponent().appendingPathComponent("keep.txt"))
        try expect(oldBytes == Data("existing-content".utf8) && siblingBytes == Data("existing-sibling".utf8),"folder merge preserves conflicting old leaf and unrelated existing sibling")

        let (skipSource,skipDestination,skipLeaf,skipExisting) = try fixture("skip-transfer")
        let skipExecutor = FileTransferExecutor(inputs:[skipSource],destination:skipDestination,move:true,control:OperationControl(),decide:{ _ in ExtractionConflictResolution(action:.skip) },report:{ _ in })
        let skipped = try UIWorkflowChecks.awaitResult { try await skipExecutor.run() }
        let skippedBytes = try Data(contentsOf:skipExisting)
        try expect(skipped.skipped.map { $0.resolvingSymlinksInPath().path } == [skipLeaf.resolvingSymlinksInPath().path] && skipped.completed.isEmpty && manager.fileExists(atPath:skipLeaf.path) && !skipped.outputs.keys.contains(where:{ URL(fileURLWithPath:$0).resolvingSymlinksInPath().path == skipLeaf.resolvingSymlinksInPath().path }) && skippedBytes == Data("existing-content".utf8),"skipped move remains incomplete and retains source plus destination bytes")

        let (oldSource,oldDestination,oldLeaf,oldTarget) = try fixture("rename-existing-transfer")
        let oldExecutor = FileTransferExecutor(inputs:[oldSource],destination:oldDestination,move:false,control:OperationControl(),decide:{ _ in ExtractionConflictResolution(action:.renameExisting) },report:{ _ in })
        let oldResult = try UIWorkflowChecks.awaitResult { try await oldExecutor.run() }
        try verifyTransferredItem(oldSource,oldDestination.appendingPathComponent("folder"),mapping:oldResult.outputs)
        let retainedOld = try Data(contentsOf:oldTarget.deletingLastPathComponent().appendingPathComponent("x_1.txt"))
        try expect(mappedTransferPath(oldLeaf,mapping:oldResult.outputs)?.path == oldTarget.path && retainedOld == Data("existing-content".utf8),"rename-existing conflict retains old bytes and verifies incoming bytes")

        for externalConflict in [false,true] {
            let (graphSource,graphDestination,graphLeaf,graphOld) = try fixture(externalConflict ? "symlink-external-conflict" : "symlink-file-conflict")
            let sourceLink = graphSource.appendingPathComponent("alias")
            try manager.createSymbolicLink(atPath:sourceLink.path,withDestinationPath:"x.txt")
            let external = graphDestination.deletingLastPathComponent().appendingPathComponent("external.txt")
            if externalConflict {
                try Data("external-original".utf8).write(to:external)
                try manager.removeItem(at:graphOld); try manager.createSymbolicLink(at:graphOld,withDestinationURL:external)
            }
            let graphExecutor = FileTransferExecutor(inputs:[graphSource],destination:graphDestination,move:false,preserveLinkGraph:true,control:OperationControl(),decide:{ _ in ExtractionConflictResolution(action:.renameExtracted) },report:{ _ in })
            let graphOutcome = try UIWorkflowChecks.awaitResult { try await graphExecutor.run() }
            try verifyTransferredItem(graphSource,graphDestination.appendingPathComponent("folder"),mapping:graphOutcome.outputs)
            guard let copiedLink = mappedTransferPath(sourceLink,mapping:graphOutcome.outputs),let copiedLeaf = mappedTransferPath(graphLeaf,mapping:graphOutcome.outputs) else { throw UIError(message:"FAIL: symlink graph omitted transfer mapping") }
            let bytesThroughLink = try Data(contentsOf:copiedLink)
            let linkTarget = try manager.destinationOfSymbolicLink(atPath:copiedLink.path)
            let resolvedTarget = copiedLink.deletingLastPathComponent().appendingPathComponent(linkTarget).standardizedFileURL
            try expect(bytesThroughLink == Data("incoming-content".utf8) && resolvedTarget == copiedLeaf.standardizedFileURL,"merged symlink points to renamed incoming file with \(externalConflict ? "external-link" : "regular-file") conflict")
            if externalConflict {
                let externalBytes = try Data(contentsOf:external), oldLink = try manager.destinationOfSymbolicLink(atPath:graphOld.path)
                try expect(externalBytes == Data("external-original".utf8) && oldLink == external.path,"incoming symlink graph retains conflicting external link and external bytes")
            }
        }

        let canonicalSource = URL(fileURLWithPath:source.path.hasPrefix("/var/") ? "/private" + source.path : source.path)
        if canonicalSource.path.hasPrefix("/private/var/") {
            let aliasSource = URL(fileURLWithPath:String(canonicalSource.path.dropFirst("/private".count)))
            let aliasLeaf = aliasSource.appendingPathComponent("x.txt")
            try expect(mappedTransferPath(aliasSource,mapping:result.outputs)?.path == destination.appendingPathComponent("folder").path && mappedTransferPath(aliasLeaf,mapping:result.outputs) == renamed && mappedTransferPath(canonicalSource.appendingPathComponent("x.txt"),mapping:result.outputs) == renamed,"transfer mapping reconciles /var and /private/var without losing renamed leaf destinations")
            try verifyTransferredItem(aliasSource,destination.appendingPathComponent("folder"),mapping:result.outputs)
            print("PASS: verification reads canonical transfer mapping through a /var source alias")
        } else {
            throw UIError(message:"FAIL: temporary transfer fixture does not exercise /var and /private/var aliases")
        }

        let (moveSource,moveDestination,moveLeaf,_) = try fixture("successful-move-transfer")
        let moveExecutor = FileTransferExecutor(inputs:[moveSource],destination:moveDestination,move:true,control:OperationControl(),decide:{ _ in ExtractionConflictResolution(action:.renameExtracted) },report:{ _ in })
        let moved = try UIWorkflowChecks.awaitResult { try await moveExecutor.run() }
        guard let movedLeaf = mappedTransferPath(moveLeaf,mapping:moved.outputs) else { throw UIError(message:"FAIL: completed move omitted its leaf destination") }
        let movedBytes = try Data(contentsOf:movedLeaf)
        try expect(moved.skipped.isEmpty && !manager.fileExists(atPath:moveSource.path) && movedBytes == Data("incoming-content".utf8),"successful merged move removes empty source only after incoming bytes are transferred")

        let cancelRoot = root.appendingPathComponent("cancel-after-last-item"), cancelSource = cancelRoot.appendingPathComponent("source.txt"), cancelDestination = cancelRoot.appendingPathComponent("destination")
        try manager.createDirectory(at:cancelDestination,withIntermediateDirectories:true)
        try Data("cancel-preserved-content".utf8).write(to:cancelSource)
        let control = OperationControl()
        let cancelledExecutor = FileTransferExecutor(inputs:[cancelSource],destination:cancelDestination,move:false,control:control,decide:{ _ in ExtractionConflictResolution(action:.cancel) },report:{ _ in control.cancel() })
        var reportedCancellation = false
        do { _ = try UIWorkflowChecks.awaitResult { try await cancelledExecutor.run() } }
        catch ArchiveError.cancelled { reportedCancellation = true }
        let retainedSource = try Data(contentsOf:cancelSource), retainedCopy = try Data(contentsOf:cancelDestination.appendingPathComponent("source.txt"))
        try expect(reportedCancellation && retainedSource == Data("cancel-preserved-content".utf8) && retainedCopy == retainedSource,"cancellation from the final item report throws while retaining source and completed copy")
    }
}
