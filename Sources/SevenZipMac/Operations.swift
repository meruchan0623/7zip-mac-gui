import AppKit
import ArchiveCore

enum MaterializeMode { case open, preview, archive, edit }

extension MainWindowController {
    @discardableResult
    func operation(_ title: String, command: ArchiveCommand, additionalMutations: [URL] = [], completion: ((CommandResult) async -> Void)? = nil) -> ProgressController? {
        var reservation: UUID?
        if ["a","u","d","rn"].contains(command.arguments.first ?? ""), let separator = command.arguments.firstIndex(of:"--"), command.arguments.indices.contains(separator + 1) {
            let target = URL(fileURLWithPath:command.arguments[separator + 1])
            guard let token = reservations.reserveMutations([target] + additionalMutations) else { showError(UIError(message:"This archive is already being changed. Wait for the current operation to finish, then try again.")); return nil }
            reservation = token
        }
        let panel = progress(title)
        panel.append(command.redactedDescription + "\n")
        Task { @MainActor in
            defer { if let reservation { reservations.release(reservation) } }
            do {
                guard let engine else { throw UIError(message:"The 7-Zip engine is unavailable.") }
                let result = try await engine.run(command,control:panel.control,onOutput:{ text in Task { @MainActor in panel.append(text) } })
                panel.finish(result); await completion?(result); refreshPanes()
            } catch { panel.append("\n" + Localization.translate(error:error) + "\n"); panel.finish(message:"Operation stopped or failed — review the log",error:true) }
        }
        return panel
    }
    func progress(_ title: String) -> ProgressController {
        operations.removeAll { !$0.running && $0.window?.isVisible != true }
        let panel = ProgressController(title:title); operations.append(panel); panel.showWindow(nil); return panel
    }
    func refreshPanes() { primary.refresh(); if !secondary.isHidden { secondary.refresh() } }
    @objc func addArchive() {
        let inputs = selectedURLs()
        if inputs.isEmpty {
            let p = NSOpenPanel(); p.title = L("Choose Files to Archive"); p.canChooseDirectories = true; p.allowsMultipleSelection = true
            guard p.runModal() == .OK else { return }; add(inputs:p.urls,proposed:active.location.archive ? active.location.url : nil,memberPrefix:active.location.archive ? active.location.inner : "")
        } else { add(inputs:inputs,proposed:active.location.archive ? active.location.url : nil,memberPrefix:active.location.archive ? active.location.inner : "") }
    }
    func add(inputs: [URL], proposed: URL? = nil, email: Bool = false, memberPrefix: String = "", allowSourceDeletion: Bool = true, additionalMutations: [URL] = [], completion: ((URL,CompressionOptions) async -> Void)? = nil) {
        guard !inputs.isEmpty, let choice = compressionDialog(inputs:inputs,proposed:proposed,password:proposed.flatMap { archivePasswords[$0] } ?? "",allowSourceDeletion:allowSourceDeletion && memberPrefix.isEmpty) else { return }
        if email && !choice.options.volumeSize.isEmpty { showError(UIError(message:"Compress and Email requires a single archive. Clear Split volumes and try again.")); return }
        if FileManager.default.fileExists(atPath:choice.output.path) && !confirm("Update existing archive?",choice.output.path + "\nThe archive will be changed.",destructive:true) { return }
        if FileManager.default.fileExists(atPath:choice.output.path), choice.options.format == "7z", !choice.options.password.isEmpty, !choice.options.encryptHeaders,
           !confirm("Make archive file names visible?","Updating this archive with file name encryption disabled may expose previously encrypted names.",destructive:true) { return }
        var staging: URL?
        do {
            let command: ArchiveCommand
            if let proposed,choice.output.standardizedFileURL == proposed.standardizedFileURL,!memberPrefix.isEmpty {
                _ = try ArchiveMemberPath.validate(memberPrefix)
                let root = temporaryBaseURL.appendingPathComponent("SevenZipMac-add-" + UUID().uuidString,isDirectory:true); staging = root
                try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]); temporaryDirectories.append(root)
                let parent = root.appendingPathComponent(memberPrefix); try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
                let stagedInputs = try inputs.map { input -> URL in let target = parent.appendingPathComponent(input.lastPathComponent); try FileManager.default.copyItem(at:input,to:target); return target }
                command = try ArchiveExactInputCommand.make(archive:choice.output,inputs:stagedInputs,members:inputs.map { memberPrefix + "/" + $0.lastPathComponent },root:root,options:choice.options)
            } else { command = try ArchiveCommands.create(archive:choice.output,inputs:inputs,options:choice.options) }
            let panel = operation(LF("Compress — %@",choice.output.lastPathComponent),command:command,additionalMutations:additionalMutations) { [weak self] result in
                if result.succeeded {
                    await completion?(choice.output,choice.options)
                    if choice.createExtractor { self?.createExtractor(archive:choice.output) }
                }
                if result.succeeded || result.warning {
                    self?.remember(choice.output); if !choice.options.password.isEmpty { self?.archivePasswords[choice.output] = choice.options.password }
                    if email {
                        guard FileManager.default.fileExists(atPath:choice.output.path) else { showError(UIError(message:"The compressed archive is missing; email composition was not opened.")); return }
                        if let service = NSSharingService(named:.composeEmail) { service.perform(withItems:[choice.output]) } else { showError(UIError(message:"The macOS email sharing service is unavailable. Configure a mail application first.")) }
                    }
                }
            }
            if let staging { panel?.onFinished = { try? FileManager.default.removeItem(at:staging) }; if panel == nil { try? FileManager.default.removeItem(at:staging) } }
        } catch { if let staging { try? FileManager.default.removeItem(at:staging) }; showError(error) }
    }
    func quickArchive(_ inputs: [URL], format: String) {
        guard let first = inputs.first else { return }
        let output = first.deletingLastPathComponent().appendingPathComponent(first.deletingPathExtension().lastPathComponent + "." + format)
        if FileManager.default.fileExists(atPath:output.path) && !confirm("Update existing archive?",output.path,destructive:true) { return }
        var options = CompressionOptions(); options.format = format; options.storeSymbolicLinks = format == "7z"
        do { operation(LF("Compress — %@",output.lastPathComponent),command:try ArchiveCommands.create(archive:output,inputs:inputs,options:options)) } catch { showError(error) }
    }
    @objc func extractSelected() { extractURLs(selectedArchiveURLs()) }
    func extractURLs(_ urls: [URL]) {
        for url in urls {
            let selected = active.location.archive && active.location.url == url ? active.selected.map(\.path) : []
            guard let options = extractionDialog(archive:url,selected:selected,password:archivePasswords[url] ?? "") else { continue }
            var configured = options; if active.location.archive && active.location.url == url { configured.openMode = active.location.openMode }; extract(url,options:configured)
        }
    }
    func extract(_ url: URL, options: ExtractionOptions, completion: (() -> Void)? = nil) {
        guard let token = reservations.reserveDestination(options.destination) else { showError(UIError(message:"Another extraction is writing to this destination or a containing folder. Wait for it to finish, then try again.")); return }
        let panel = progress(LF("Extract — %@",url.lastPathComponent))
        Task { @MainActor in
            defer { reservations.release(token) }
            do {
                guard let engine else { throw UIError(message:"The 7-Zip engine is unavailable.") }
                if options.overwrite == .ask { panel.append("Extract with per-file conflict decisions: " + url.path + " → " + options.destination.path + "\n") }
                else { let command = try ArchiveCommands.extract(archive:url,options:options); panel.append(command.redactedDescription + "\n") }
                let result = try await engine.extract(archive:url,options:options,control:panel.control,resolveConflict:{ conflict in await resolveExtractionConflict(conflict,panel:panel) },onOutput:{ text in Task { @MainActor in panel.append(text) } })
                panel.finish(result); refreshPanes(); if result.succeeded || result.warning { completion?() }
            } catch { panel.append(Localization.translate(error:error) + "\n"); panel.finish(message:"Extraction stopped or failed — review the log",error:true) }
        }
    }
    @objc func testSelected() { testURLs(selectedArchiveURLs()) }
    func testURLs(_ urls: [URL]) { for url in urls { operation(LF("Test — %@",url.lastPathComponent),command:ArchiveCommands.test(archive:url,password:archivePasswords[url] ?? "",openMode:active.location.archive && active.location.url == url ? active.location.openMode : .automatic)) } }
    @objc func hashSelected() {
        if active.location.archive {
            let items = active.selected.filter { !$0.directory }
            guard !items.isEmpty else { return }
            materializeMany(items) { [weak self] urls in self?.hashURLs(urls) }
        } else { hashURLs(selectedURLs()) }
    }
    func hashURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let form = FormDialog("Calculate Checksums")
        let method = form.popup("Algorithm",["SHA256","SHA1","SHA384","SHA512","SHA3-256","MD5","XXH64","CRC32","CRC64","BLAKE2sp","*"],selected:UserDefaults.standard.string(forKey:"hash") ?? "SHA256")
        let save = form.check("Save checksum output to a text file")
        guard form.run() else { return }
        UserDefaults.standard.set(method.selectedValue,forKey:"hash")
        let output = save.state == .on ? saveURL("Save Checksums",name:"checksums.txt") : nil
        if let output,SHA256Manifest.wouldReplaceInput(output:output,inputs:urls) { showError(UIError(message:"The checksum report cannot replace an input file or its link.")); return }
        do { operation("Checksums",command:try ArchiveCommands.hash(inputs:urls,method:method.selectedValue!)) { result in
            if let output, result.succeeded { do { try result.output.write(to:output,atomically:true,encoding:.utf8) } catch { showError(error) } }
        } } catch { showError(error) }
    }
    @objc func benchmark() {
        let f = FormDialog("7-Zip Benchmark",message:"Measures compression and decompression performance using LZMA. This may use substantial CPU and memory.")
        let threads = f.field("CPU threads","0"); let dictionary = f.field("Dictionary",""); dictionary.placeholderString = L("e.g. 32m, empty = automatic")
        guard f.run(), let count = Int(threads.stringValue),count >= 0 else { return }
        do { operation("7-Zip Benchmark",command:try ArchiveCommands.benchmark(threads:count,dictionary:dictionary.stringValue)) } catch { showError(error) }
    }
    @objc func deleteSelected() {
        let items = active.selected; guard !items.isEmpty else { return }
        if active.location.archive {
            guard confirm("Delete \(items.count) archive entries?","This changes the archive permanently. Archive entries cannot be recovered from the Trash.",destructive:true) else { return }
            do { operation("Delete Archive Entries",command:try ArchiveCommands.delete(archive:active.location.url,paths:items.map(\.path),password:archivePasswords[active.location.url] ?? "")) } catch { showError(error) }
        } else {
            guard confirm("Move \(items.count) items to Trash?","You can restore these items from the Finder Trash.",destructive:true) else { return }
            guard let token = reservations.reserveMutations(items.compactMap(\.url)) else { showError(UIError(message:"A selected item is being used by another operation. Wait for it to finish.")); return }
            defer { reservations.release(token) }
            do { for item in items { if let url = item.url { try FileManager.default.trashItem(at:url,resultingItemURL:nil) } }; refreshPanes() } catch { showError(error); refreshPanes() }
        }
    }
    @objc func renameSelected() {
        guard active.selected.count == 1,let item = active.selected.first,let name = prompt("Rename",value:URL(fileURLWithPath:item.path).lastPathComponent),!name.isEmpty,name != ".",name != "..",!name.contains("/"),!name.contains("\\") else { return }
        if active.location.archive {
            guard confirm("Rename archive entry?","\(item.path) → \(name)",destructive:true) else { return }
            let parent = (item.path as NSString).deletingLastPathComponent
            let path = parent.isEmpty || parent == "." ? name : parent + "/" + name
            do { operation("Rename Archive Entry",command:try ArchiveCommands.rename(archive:active.location.url,from:item.path,to:path,password:archivePasswords[active.location.url] ?? "")) } catch { showError(error) }
        } else if let url = item.url {
            let output = url.deletingLastPathComponent().appendingPathComponent(name)
            guard let token = reservations.reserveMutations([url,output]) else { showError(UIError(message:"The source or destination is in use by another operation.")); return }
            defer { reservations.release(token) }
            do { try FileManager.default.moveItem(at:url,to:output); refreshPanes() } catch { showError(error) }
        }
    }
    @objc func newFolder() {
        if active.location.archive { createArchiveEntry(directory:true); return }
        guard let name = prompt("New Folder",value:"New Folder"), !name.isEmpty,!name.contains("/"), name != ".",name != ".." else { return }
        do { try FileManager.default.createDirectory(at:active.location.url.appendingPathComponent(name),withIntermediateDirectories:false); refreshPanes() } catch { showError(error) }
    }
    @objc func copySelected() { transfer(move:false) }
    @objc func moveSelected() { transfer(move:true) }
    func transfer(move: Bool) {
        guard !active.selected.isEmpty else { return }
        if active.location.archive {
            guard let dest = chooseDirectory(move ? "Move Archive Entries To" : "Copy Archive Entries To") else { return }
            if move { moveArchiveItems(to:dest); return }
            materializeMany(active.selected) { [weak self] files in self?.transferFiles(files,to:dest,move:false,preserveLinkGraph:true) }; return
        }
        let other = active === primary ? secondary : primary
        guard let dest = chooseDirectory(move ? "Move Files To" : "Copy Files To",initial:other.location.archive ? nil : other.location.url) else { return }
        transferFiles(selectedURLs(),to:dest,move:move)
    }

    @objc func splitSelected() {
        guard let file = selectedURLs().first,active.selected.count == 1,!active.selected[0].directory else { return }
        let f = FormDialog("Split File",message:file.lastPathComponent); let size = f.field("Volume size (bytes)","104857600")
        guard f.run(),let bytes = UInt64(size.stringValue),bytes > 0, let dest = chooseDirectory("Save Volumes",initial:file.deletingLastPathComponent()) else { return }
        let panel = progress("Split File")
        Task { @MainActor in do {
            let urls = try await FileUtilities.split(file:file,destination:dest,volumeBytes:bytes,control:panel.control,onProgress:{ value in Task { @MainActor in panel.fraction(value) } })
            panel.append(urls.map(\.path).joined(separator:"\n") + "\n"); panel.finish(message:"Completed successfully"); refreshPanes()
        } catch { panel.append(Localization.translate(error:error) + "\n"); panel.finish(message:"Split stopped or failed",error:true) } }
    }
    @objc func combineSelected() {
        guard let first = selectedURLs().first, let output = saveURL("Combine Volumes",name:first.deletingPathExtension().lastPathComponent,initial:first.deletingLastPathComponent()) else { return }
        let panel = progress("Combine Volumes")
        Task { @MainActor in do {
            let url = try await FileUtilities.combine(firstVolume:first,output:output,control:panel.control,onProgress:{ value in Task { @MainActor in panel.fraction(value) } })
            panel.append(url.path + "\n"); panel.finish(message:"Completed successfully"); refreshPanes()
        } catch { panel.append(Localization.translate(error:error) + "\n"); panel.finish(message:"Combine stopped or failed",error:true) } }
    }
    func materializeMany(_ items: [BrowserItem], from sourceLocation: BrowserLocation? = nil, completion: @escaping ([URL]) -> Void) {
        let source = sourceLocation ?? active.location
        do {
            let dir = temporaryBaseURL.appendingPathComponent("SevenZipMac-" + UUID().uuidString,isDirectory:true)
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]); temporaryDirectories.append(dir)
            var options = ExtractionOptions(destination:dir); options.selectedPaths = items.map(\.path); options.password = archivePasswords[source.url] ?? ""; options.openMode = source.openMode; options.remapAbsolutePaths = true
            extract(source.url,options:options) { completion(items.map { dir.appendingPathComponent((try? ArchiveCommands.remappedArchivePath($0.path)) ?? $0.path) }) }
        } catch { showError(error) }
    }
    func materialize(_ item: BrowserItem, mode: MaterializeMode) {
        let archive = active.location.url; let pane = active!; let parent = active.location; let password = archivePasswords[archive] ?? ""
        materializeMany([item]) { [weak self] urls in
            guard let self,let file = urls.first else { return }
            switch mode {
            case .archive: self.nestedParents[file] = parent; self.open(file,pane:pane)
            case .open: NSWorkspace.shared.open(file)
            case .preview: self.preview(file)
            case .edit:
                self.openEditor(file)
                let editor = EditSessionController(file:file,archive:archive,path:item.path,password:password,format:self.archiveFormats[archive] ?? archive.pathExtension,owner:self)
                self.editSessions.append(editor); editor.showWindow(nil)
            }
        }
    }
    @objc func createExtractor() {
        guard active.location.archive else { return }
        createExtractor(archive:active.location.url)
    }
    func createExtractor(archive: URL) {
        guard archive.pathExtension != "001", archiveFormats[archive] != "Split" else { showError(UIError(message:"A split archive needs all its volumes. Create a single-volume archive before making an extractor app.")); return }
        guard let output = saveURL("Create macOS Extractor App",name:archive.deletingPathExtension().lastPathComponent + " Extractor.app") else { return }
        guard Bundle.main.bundleURL.pathExtension == "app" else { showError(UIError(message:"Build and launch the bundled .app before creating an extractor.")); return }
        let source = Bundle.main.bundleURL
        let panel = progress("Create macOS Extractor App"); panel.pauseButton.isEnabled = false
        panel.append(L("Copy application and payload, assign a unique application identity, then sign locally.\nCancellation applies between copy stages.") + "\n")
        Task.detached {
            var created = false
            do {
                if FileManager.default.fileExists(atPath:output.path) { throw UIError(message:"The output already exists. Choose a new name.") }
                if await MainActor.run(body:{ panel.cancellationRequested }) { throw ArchiveError.cancelled }
                try FileManager.default.copyItem(at:source,to:output); created = true
                if await MainActor.run(body:{ panel.cancellationRequested }) { throw ArchiveError.cancelled }
                let resource = output.appendingPathComponent("Contents/Resources/Payload.7z")
                if FileManager.default.fileExists(atPath:resource.path) { try FileManager.default.removeItem(at:resource) }
                try FileManager.default.copyItem(at:archive,to:resource)
                let plist = output.appendingPathComponent("Contents/Info.plist")
                var info = try PropertyListSerialization.propertyList(from:Data(contentsOf:plist),options:[],format:nil) as? [String:Any] ?? [:]
                info["CFBundleIdentifier"] = "local.sevenzip.extractor." + UUID().uuidString.lowercased()
                info["CFBundleDisplayName"] = output.deletingPathExtension().lastPathComponent; info["CFBundleName"] = output.deletingPathExtension().lastPathComponent
                for key in ["CFBundleURLTypes","CFBundleDocumentTypes","NSServices","UTExportedTypeDeclarations","UTImportedTypeDeclarations"] { info.removeValue(forKey:key) }
                try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:plist,options:.atomic)
                let plugins = output.appendingPathComponent("Contents/PlugIns"); if FileManager.default.fileExists(atPath:plugins.path) { try FileManager.default.removeItem(at:plugins) }
                if await MainActor.run(body:{ panel.cancellationRequested }) { throw ArchiveError.cancelled }
                let signer = SevenZipEngine(binaryURL:URL(fileURLWithPath:"/usr/bin/codesign"))
                _ = try await signer.run(ArchiveCommand(arguments:["--force","--deep","--sign","-",output.path]),control:panel.control,onOutput:{ text in Task { @MainActor in panel.append(text) } })
                await MainActor.run { panel.append(output.path + "\n" + L("This app uses local ad-hoc signing; it is not notarized.") + "\n"); panel.finish(message:"Extractor app created"); NSWorkspace.shared.activateFileViewerSelecting([output]) }
            } catch {
                if created { try? FileManager.default.removeItem(at:output) }
                await MainActor.run { panel.append(Localization.translate(error:error) + "\n"); panel.finish(message:"Extractor creation stopped or failed",error:true) }
            }
        }
    }
}

final class EditSessionController: NSWindowController {
    let file: URL
    let archive: URL
    let path: String
    let password: String
    let format: String
    weak var coordinator: MainWindowController?
    init(file: URL, archive: URL, path: String, password: String, format: String, owner: MainWindowController) {
        self.file = file; self.archive = archive; self.path = path; self.password = password; self.format = format; self.coordinator = owner
        let w = NSWindow(contentRect:NSRect(x:0,y:0,width:480,height:180),styleMask:[.titled,.closable],backing:.buffered,defer:false); w.title = L("Archive Edit Session")
        super.init(window:w)
        let text = NSTextField(wrappingLabelWithString:LF("Edit and save %@ in its application. When finished, choose Reimport to explicitly update %@.\nThe original archive is unchanged until you confirm.",file.lastPathComponent,archive.lastPathComponent))
        let button = NSButton(title:L("Reimport Saved File…"),target:self,action:#selector(reimport)); button.bezelStyle = .rounded
        let reveal = NSButton(title:L("Show Extracted File"),target:self,action:#selector(reveal)); reveal.bezelStyle = .rounded
        let stack = NSStackView(views:[text,reveal,button]); stack.orientation = .vertical; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false; w.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:w.contentView!.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:w.contentView!.trailingAnchor,constant:-20),stack.topAnchor.constraint(equalTo:w.contentView!.topAnchor,constant:20)])
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func reveal() { NSWorkspace.shared.activateFileViewerSelecting([file]) }
    @objc func reimport() {
        guard let owner = coordinator,confirm("Update archive with saved edits?",path + "\nSave the file in the editor before continuing.",destructive:true) else { return }
        guard let token = owner.reservations.reserveMutations([archive,file]) else { showError(UIError(message:"The archive or edited file is in use by another operation.")); return }
        let panel = owner.progress("Reimport Saved File")
        Task { @MainActor [weak self] in
            defer { owner.reservations.release(token) }
            do {
                guard let engine = owner.engine else { throw UIError(message:"The 7-Zip engine is unavailable.") }
                let result = try await engine.reimportMember(archive:archive,member:path,file:file,format:format,password:password,control:panel.control)
                panel.finish(result); owner.refreshPanes(); self?.close()
            } catch { panel.append(Localization.translate(error:error) + "\n"); panel.finish(message:"Edited file was not reimported; the original archive was retained",error:true) }
        }
    }
}

@MainActor func resolveExtractionConflict(_ conflict: ExtractionConflict, panel: ProgressController) -> ExtractionConflictResolution {
    guard !panel.cancellationRequested else { return ExtractionConflictResolution(action:.cancel) }
    let form = FormDialog("Existing Destination Item",message:"Archive member: " + conflict.archivePath + "\nDestination: " + conflict.destination.path)
    let action = form.popup("Action",["Skip","Overwrite","Rename extracted item","Rename existing item"])
    let all = form.check("Apply this choice to all remaining conflicts")
    form.note("All conflict decisions are collected before destination files are changed. Cancel stops the extraction.")
    let dialogWindow = form.alert.window
    let timer = Timer(timeInterval:0.1,repeats:true) { _ in if panel.cancellationRequested,NSApp.modalWindow === dialogWindow { NSApp.abortModal() } }
    RunLoop.main.add(timer,forMode:.modalPanel); defer { timer.invalidate() }
    guard form.run(),!panel.cancellationRequested else { return ExtractionConflictResolution(action:.cancel) }
    let selected: ExtractionConflictAction = [.skip,.overwrite,.renameExtracted,.renameExisting][action.indexOfSelectedItem]
    return ExtractionConflictResolution(action:selected,applyToAll:all.state == .on)
}
