import AppKit
import ArchiveCore

extension MainWindowController {
    static let archiveCutPasteboardType = NSPasteboard.PasteboardType("local.sevenzip.mac.archive-cut")
    static let cutPasteboardType = NSPasteboard.PasteboardType("local.sevenzip.mac.cut-files")
    @objc func deselectAllFiles() { active.table.deselectAll(nil) }
    @objc func deselectPattern() { updatePatternSelection(deselect:true) }
    @objc func deselectType() { updateTypeSelection(deselect:true) }
    func updatePatternSelection(deselect: Bool) {
        guard let pattern = prompt(deselect ? "Deselect by Name Pattern" : "Select by Name Pattern",message:"Use * and ? wildcards.",value:"*") else { return }
        let matches = FileSelection.patternIndexes(pattern,items:active.visible.map(\.name))
        active.table.selectRowIndexes(deselect ? active.table.selectedRowIndexes.subtracting(matches) : matches,byExtendingSelection:false)
    }
    func updateTypeSelection(deselect: Bool) {
        guard let item = active.selected.first else { return }
        let ext = URL(fileURLWithPath:item.path).pathExtension.lowercased()
        let matches = IndexSet(active.visible.indices.filter { active.visible[$0].directory == item.directory && (item.directory || URL(fileURLWithPath:active.visible[$0].path).pathExtension.lowercased() == ext) })
        active.table.selectRowIndexes(deselect ? active.table.selectedRowIndexes.subtracting(matches) : matches,byExtendingSelection:false)
    }
    func writeFileClipboard(_ urls: [URL], cut: Bool) {
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general; pasteboard.clearContents(); pasteboard.writeObjects(urls.map { $0 as NSURL })
        if cut { pasteboard.setString("1",forType:Self.cutPasteboardType) }
    }
    func copyFilesToClipboard() {
        guard !active.selected.isEmpty else { return }
        if active.location.archive { materializeMany(active.selected) { [weak self] urls in self?.writeFileClipboard(urls,cut:false) } }
        else { writeFileClipboard(selectedURLs(),cut:false) }
    }
    func cutFilesToClipboard() {
        if active.location.archive { cutArchiveItems(); return }
        writeFileClipboard(selectedURLs(),cut:true)
    }
    func pasteFilesFromClipboard(forceMove: Bool = false) {
        guard let urls = NSPasteboard.general.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL],!urls.isEmpty else { return }
        if let session = archiveClipboard,NSPasteboard.general.string(forType:Self.archiveCutPasteboardType) == session.token { pasteArchiveCut(session); return }
        let move = forceMove || NSPasteboard.general.string(forType:Self.cutPasteboardType) == "1"
        if active.location.archive {
            if move { moveFilesIntoArchive(urls,to:active.location); return }
            add(inputs:urls,proposed:active.location.url,memberPrefix:active.location.inner); return
        }
        let clipboardVersion = NSPasteboard.general.changeCount
        transferFiles(urls,to:active.location.url,move:move) { [weak self] outcome in
            if move && NSPasteboard.general.changeCount == clipboardVersion {
                self?.writeFileClipboard(urls.compactMap { mappedTransferPath($0,mapping:outcome.outputs) },cut:false)
            }
        }
    }
    func transferFiles(_ inputs: [URL], to destination: URL, move: Bool, preserveLinkGraph: Bool = false, additionalMutations: [URL] = [], completion: (@MainActor (FileTransferOutcome) async -> Void)? = nil) {
        do { try FileTransferPlan.validate(inputs:inputs,destination:destination,allowConflicts:true) } catch { showError(error); return }
        if move && !confirm("Move \(inputs.count) items?",destination.path,destructive:true) { return }
        guard let reservation = reservations.reserveMutations([destination] + inputs + additionalMutations) else { showError(UIError(message:"A source or destination is in use by another operation.")); return }
        let panel = progress(move ? "Move Files" : "Copy Files"); panel.pauseButton.isEnabled = false
        panel.append(L("Cancellation applies between individual items. Completed items remain at the destination.") + "\n")
        Task { @MainActor in
            defer { reservations.release(reservation) }
            do {
                let executor = FileTransferExecutor(inputs:inputs,destination:destination,move:move,preserveLinkGraph:preserveLinkGraph,control:panel.control,decide:{ conflict in await resolveFileTransferConflict(conflict,panel:panel) },report:{ text in Task { @MainActor in panel.append(text) } })
                let result = try await Task.detached { try await executor.run() }.value
                if panel.cancellationRequested { throw ArchiveError.cancelled }
                panel.finish(message:result.skipped.isEmpty ? "Completed successfully" : "Completed with skipped items",error:!result.skipped.isEmpty); refreshPanes()
                if result.skipped.isEmpty { await completion?(result) }
            } catch { panel.append(Localization.translate(error:error) + "\n"); panel.finish(message:"File transfer stopped — completed items are retained",error:true); refreshPanes() }
        }
    }
    func createArchiveEntry(directory: Bool) {
        let archive = active.location.url; let prefix = active.location.inner
        guard let name = prompt(directory ? "New Archive Folder" : "New Archive File",value:directory ? "New Folder" : "Untitled.txt"),!name.isEmpty,!name.contains("/"),!name.contains("\\") else { return }
        let member = prefix.isEmpty ? name : prefix + "/" + name
        do { _ = try ArchiveMemberPath.validate(member) } catch { showError(error); return }
        guard let token = reservations.reserveMutation(archive) else { showError(UIError(message:"This archive is already being changed. Wait for it to finish.")); return }
        let password = archivePasswords[archive] ?? ""
        let panel = progress(directory ? "Create Archive Folder" : "Create Archive File")
        Task { @MainActor in
            var staging: URL?
            defer { reservations.release(token); if let staging { try? FileManager.default.removeItem(at:staging) } }
            do {
                guard let engine else { throw UIError(message:"The 7-Zip engine is unavailable.") }
                let listing = try await engine.list(archive:archive,password:password,control:panel.control)
                let format = listing.properties["Type"] ?? archiveFormats[archive] ?? archive.pathExtension
                guard ["7z","zip","tar","wim"].contains(format) else { throw UIError(message:"This format cannot contain additional archive files or folders.") }
                try ArchiveCreationSafety.validate(member:member,directory:directory,listing:listing)
                let root = temporaryBaseURL.appendingPathComponent("SevenZipMac-new-" + UUID().uuidString,isDirectory:true); staging = root
                try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]); temporaryDirectories.append(root)
                let file = root.appendingPathComponent(member)
                try FileManager.default.createDirectory(at:directory ? file : file.deletingLastPathComponent(),withIntermediateDirectories:true)
                if !directory { try Data().write(to:file,options:.withoutOverwriting) }
                var options = CompressionOptions(); options.format = format; options.password = password; options.encryptHeaders = format == "7z" && !password.isEmpty
                let command = try ArchiveExactInputCommand.make(archive:archive,inputs:[file],members:[member],root:root,options:options)
                panel.append(command.redactedDescription + "\n")
                let result = try await engine.run(command,control:panel.control,onOutput:{ text in Task { @MainActor in panel.append(text) } })
                panel.finish(result); refreshPanes()
            } catch {
                panel.append(Localization.translate(error:error) + "\n"); panel.finish(message:"New entry was not created",error:true)
                if error is UIError { showError(error) }
            }
        }
    }
}
