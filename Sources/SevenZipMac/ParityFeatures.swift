import AppKit
import ArchiveCore
import CryptoKit
import Darwin

enum BrowserViewMode: String, CaseIterable { case largeIcons, smallIcons, list, details }
enum BrowserTimeDisplay {
    static func formatter() -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier:UserDefaults.standard.string(forKey:"uiLanguage") == "en" ? "en_US" : "zh_CN")
        if UserDefaults.standard.bool(forKey:"displayUTC") { f.timeZone = TimeZone(secondsFromGMT:0) }
        switch UserDefaults.standard.string(forKey:"timeDisplay") ?? "dateTime" {
        case "date": f.dateFormat = "yyyy-MM-dd"
        case "seconds": f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        case "milliseconds": f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        default: f.dateFormat = "yyyy-MM-dd HH:mm"
        }; return f
    }
    static func parse(_ value: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier:"en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSS"
        if let date = f.date(from:value) { return date }; f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f.date(from:value)
    }
    static func display(_ value: String) -> String { parse(value).map(formatter().string) ?? value }
}

extension MainWindowController {
    @objc func showLargeIcons() { active.setViewMode(.largeIcons) }
    @objc func showSmallIcons() { active.setViewMode(.smallIcons) }
    @objc func showListView() { active.setViewMode(.list) }
    @objc func showDetailsView() { active.setViewMode(.details) }
    func sort(_ key: String) { active.unsorted = false; active.table.sortDescriptors = [NSSortDescriptor(key:key,ascending:true)]; active.filter() }
    @objc func sortName() { sort("name") }
    @objc func sortType() { sort("kind") }
    @objc func sortDate() { sort("modified") }
    @objc func sortSize() { sort("size") }
    @objc func sortUnsorted() { active.unsorted = true; active.filter() }
    @objc func goRoot() { open(URL(fileURLWithPath:"/",isDirectory:true)) }
    @objc func showFolderHistory() {
        let paths = recent.map(\.path); guard !paths.isEmpty else { return }
        let f = FormDialog("Folder History"); let path = f.popup("Location",paths)
        if f.run(),let selected = path.selectedValue { open(URL(fileURLWithPath:selected)) }
    }
    @objc func showTimeSettings() {
        let f = FormDialog("Date and Time Display")
        let mode = f.popup("Precision",["Date only","Date and time","Seconds","Milliseconds"],selected:["date":"Date only","dateTime":"Date and time","seconds":"Seconds","milliseconds":"Milliseconds"][UserDefaults.standard.string(forKey:"timeDisplay") ?? "dateTime"] ?? "Date and time")
        let utc = f.check("Display times in UTC",UserDefaults.standard.bool(forKey:"displayUTC"))
        if f.run() { UserDefaults.standard.set(["date","dateTime","seconds","milliseconds"][mode.indexOfSelectedItem],forKey:"timeDisplay"); UserDefaults.standard.set(utc.state == .on,forKey:"displayUTC"); refreshPanes() }
    }
    @objc func configureColumns() {
        let f = FormDialog("File List Settings"); let font = f.field("Font size",String(max(12,UserDefaults.standard.integer(forKey:"fileFontSize"))))
        let hidden = Set(UserDefaults.standard.stringArray(forKey:"hiddenColumns") ?? [])
        let choices = [("size","Size"),("packed","Packed"),("modified","Modified"),("kind","Kind")].map { key,title in (key,f.check(title,!hidden.contains(key))) }
        guard f.run() else { return }; guard let size = Int(font.stringValue),(10...28).contains(size) else { showError(UIError(message:"Font size must be between 10 and 28.")); return }
        UserDefaults.standard.set(size,forKey:"fileFontSize"); UserDefaults.standard.set(choices.filter { $0.1.state != .on }.map { $0.0 },forKey:"hiddenColumns")
        primary.applyViewMode(); secondary.applyViewMode(); primary.filter(); secondary.filter()
    }
    @objc func toggleArchiveToolbar() { toggleToolbarGroup("hideArchiveToolbar") }
    @objc func toggleStandardToolbar() { toggleToolbarGroup("hideStandardToolbar") }
    func toggleToolbarGroup(_ key: String) { UserDefaults.standard.set(!UserDefaults.standard.bool(forKey:key),forKey:key); rebuildToolbar() }
    func rebuildToolbar() {
        guard let toolbar = window?.toolbar else { return }
        while !toolbar.items.isEmpty { toolbar.removeItem(at:0) }
        var ids: [String] = []
        if !UserDefaults.standard.bool(forKey:"hideArchiveToolbar") { ids += ["add","extract","test"] }
        ids += ["NSToolbarFlexibleSpaceItem"]
        if !UserDefaults.standard.bool(forKey:"hideStandardToolbar") { ids += ["open","copy","move","hash","delete","info","dual"] }
        for (index,id) in ids.enumerated() { toolbar.insertItem(withItemIdentifier:.init(id),at:index) }
    }
    @objc func toggleLargeButtons() { UserDefaults.standard.set(!UserDefaults.standard.bool(forKey:"largeToolbarButtons"),forKey:"largeToolbarButtons"); window?.toolbar?.sizeMode = UserDefaults.standard.bool(forKey:"largeToolbarButtons") ? .regular : .small }
    @objc func toggleButtonText() { UserDefaults.standard.set(!UserDefaults.standard.bool(forKey:"hideToolbarText"),forKey:"hideToolbarText"); window?.toolbar?.displayMode = UserDefaults.standard.bool(forKey:"hideToolbarText") ? .iconOnly : .iconAndLabel }
    @objc func openOutside() {
        guard let item = active.selected.first else { return }
        if active.location.archive { materialize(item,mode:.open) } else if let url = item.url { NSWorkspace.shared.open(url) }
    }
    @objc func openInside() { openSelectedAsArchive(mode:.automatic) }
    @objc func openInsideAll() { openSelectedAsArchive(mode:.topLevel) }
    @objc func openInsideParser() { openSelectedAsArchive(mode:.parser) }
    func openSelectedAsArchive(mode: ArchiveOpenMode) {
        guard let item = active.selected.first,!item.directory else { return }
        if active.location.archive {
            let parent = active.location; let pane = active!
            materializeMany([item]) { [weak self] files in guard let self,let file = files.first else { return }; self.nestedParents[file] = parent; pane.navigate(BrowserLocation(url:file,archive:true,openMode:mode)) }
        } else if let file = item.url { active.navigate(BrowserLocation(url:file,archive:true,openMode:mode)) }
    }
    func editableProperties(_ items: [BrowserItem]) {
        guard !items.isEmpty,!active.location.archive else { return }
        let files = items.compactMap(\.url); guard let first = files.first else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath:first.path)
            let f = FormDialog("Edit File Properties",message:files.count == 1 ? first.path : "Apply changes to \(files.count) selected items")
            let permission = f.field("POSIX permissions",String(format:"%03o",(attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644))
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]
            let modification = f.field("Modification date",(attributes[.modificationDate] as? Date).map(formatter.string) ?? "")
            let creation = f.field("Creation date",(attributes[.creationDate] as? Date).map(formatter.string) ?? "")
            let changePermissions = f.check("Apply permissions",false), changeModification = f.check("Apply modification date",false), changeCreation = f.check("Apply creation date",false)
            let hidden = f.check("Hidden in Finder",(try? first.resourceValues(forKeys:[.isHiddenKey]).isHidden) == true), changeHidden = f.check("Apply hidden flag",false)
            f.note("Dates use ISO 8601, for example 2026-10-10T08:00:00Z. Changes apply only to selected items, not folder contents.")
            guard f.run() else { return }
            var changes: [FileAttributeKey:Any] = [:]
            if changePermissions.state == .on { guard let mode = Int(permission.stringValue,radix:8),(0...0o7777).contains(mode) else { throw UIError(message:"Enter valid octal permissions, for example 644 or 755.") }; changes[.posixPermissions] = mode }
            if changeModification.state == .on { guard let date = formatter.date(from:modification.stringValue) else { throw UIError(message:"Enter a valid ISO 8601 modification date.") }; changes[.modificationDate] = date }
            if changeCreation.state == .on { guard let date = formatter.date(from:creation.stringValue) else { throw UIError(message:"Enter a valid ISO 8601 creation date.") }; changes[.creationDate] = date }
            guard let token = reservations.reserveMutations(files) else { throw UIError(message:"A selected item is in use by another operation.") }; defer { reservations.release(token) }
            for var file in files { if !changes.isEmpty { try FileManager.default.setAttributes(changes,ofItemAtPath:file.path) }; if changeHidden.state == .on { var values = URLResourceValues(); values.isHidden = hidden.state == .on; try file.setResourceValues(values) } }
            refreshPanes()
        } catch { showError(error) }
    }
}

struct ArchiveClipboardSession {
    let token: String
    let archive: URL
    let members: [String]
    let files: [URL]
    let digest: String
    let payloadDigests: [String]
    let password: String
    let openMode: ArchiveOpenMode
}
func contentDigest(_ file: URL) throws -> String {
    let h = try FileHandle(forReadingFrom:file); defer { try? h.close() }; var hash = SHA256()
    while let data = try h.read(upToCount:1_048_576),!data.isEmpty { hash.update(data:data) }
    return hash.finalize().map { String(format:"%02x",$0) }.joined()
}
func verifyTransferredItem(_ source: URL, _ destination: URL, mapping: [String:URL]? = nil) throws {
    let destination = mapping.flatMap { mappedTransferPath(source,mapping:$0) } ?? destination
    let keys: Set<URLResourceKey> = [.isDirectoryKey,.isSymbolicLinkKey]
    let values = try source.resourceValues(forKeys:keys), target = try destination.resourceValues(forKeys:keys)
    guard values.isSymbolicLink == target.isSymbolicLink,values.isDirectory == target.isDirectory else { throw UIError(message:"Transferred item type does not match the source.") }
    if values.isSymbolicLink == true {
        let sourceLink = try FileManager.default.destinationOfSymbolicLink(atPath:source.path)
        let actual = try FileManager.default.destinationOfSymbolicLink(atPath:destination.path)
        if let mapping {
            let sourceTarget = source.deletingLastPathComponent().appendingPathComponent(sourceLink).standardizedFileURL
            guard let expected = mappedTransferPath(sourceTarget,mapping:mapping),destination.deletingLastPathComponent().appendingPathComponent(actual).standardizedFileURL == expected.standardizedFileURL else { throw UIError(message:"Transferred link target does not match.") }
        } else { guard sourceLink == actual else { throw UIError(message:"Transferred link target does not match.") } }
    }
    else if values.isDirectory == true { for child in try FileManager.default.contentsOfDirectory(at:source,includingPropertiesForKeys:nil) { try verifyTransferredItem(child,destination.appendingPathComponent(child.lastPathComponent),mapping:mapping) } }
    else { guard try contentDigest(source) == contentDigest(destination) else { throw UIError(message:"Transferred file content does not match. The source archive was retained.") } }
}

extension MainWindowController {
    func cutArchiveItems(moveDestination: URL? = nil) {
        let location = active.location; let items = active.selected; guard !items.isEmpty else { return }
        Task { @MainActor [self] in
            do {
                let digest = try await Task.detached { try contentDigest(location.url) }.value
                let password = archivePasswords[location.url] ?? ""
                materializeMany(items,from:location) { [weak self] files in
                    guard let self else { return }
                    Task { @MainActor [self] in do {
                        let (after,payload) = try await Task.detached { (try contentDigest(location.url),try files.map(treeDigest)) }.value
                        guard after == digest else { throw UIError(message:"The archive changed while preparing the clipboard. Cut was cancelled.") }
                        let token = UUID().uuidString
                        let session = ArchiveClipboardSession(token:token,archive:location.url,members:items.map(\.path),files:files,digest:digest,payloadDigests:payload,password:password,openMode:location.openMode)
                        if let destination = moveDestination {
                            self.transferFiles(files,to:destination,move:false,preserveLinkGraph:true,additionalMutations:[session.archive]) { [weak self] outcome in
                                await self?.finishArchiveCut(session,outputs:files.compactMap { outcome.outputs[$0.path] },mapping:outcome.outputs,sourceAlreadyReserved:true)
                            }
                        } else {
                            self.archiveClipboard = session
                            self.writeFileClipboard(files,cut:true); NSPasteboard.general.setString(token,forType:Self.archiveCutPasteboardType)
                        }
                    } catch { showError(error) } }
                }
            } catch { showError(error) }
        }
    }
    func moveArchiveItems(to destination: URL) {
        guard confirm("Move Archive Entries?","Files will be extracted and verified before removing the original archive entries.",destructive:true) else { return }
        cutArchiveItems(moveDestination:destination)
    }
    func clearArchiveClipboard(_ session: ArchiveClipboardSession, outputs: [URL]? = nil) {
        if archiveClipboard?.token == session.token { archiveClipboard = nil }
        if NSPasteboard.general.string(forType:Self.archiveCutPasteboardType) == session.token {
            if let outputs { writeFileClipboard(outputs,cut:false) }
            else {
                NSPasteboard.general.setString("",forType:Self.archiveCutPasteboardType)
                NSPasteboard.general.setString("",forType:Self.cutPasteboardType)
            }
        }
    }
    @MainActor func finishArchiveCut(_ session: ArchiveClipboardSession, outputs: [URL], mapping: [String:URL]? = nil, sourceAlreadyReserved: Bool = false) async {
        guard outputs.count == session.files.count else { return }
        let token = sourceAlreadyReserved ? nil : reservations.reserveMutation(session.archive)
        guard sourceAlreadyReserved || token != nil else { showError(UIError(message:"The source archive is busy. The copied files were retained and source entries were not removed.")); return }
        defer { if let token { reservations.release(token) } }
        let panel = progress("Verify and Complete Archive Move")
        do {
            try await Task.detached { for (index,pair) in zip(session.files,outputs).enumerated() { guard try treeDigest(pair.0) == session.payloadDigests[index] else { throw UIError(message:"The clipboard files changed. Original archive entries were retained.") }; try verifyTransferredItem(pair.0,pair.1,mapping:mapping) }; guard try contentDigest(session.archive) == session.digest else { throw UIError(message:"The source archive changed. Original entries were retained.") } }.value
            guard let engine else { throw UIError(message:"The 7-Zip engine is unavailable.") }
            if panel.cancellationRequested { throw ArchiveError.cancelled }
            let result = try await engine.run(ArchiveCommands.delete(archive:session.archive,paths:session.members,password:session.password),control:panel.control)
            guard result.succeeded else { throw UIError(message:"Original archive entries could not be removed.") }
            clearArchiveClipboard(session,outputs:outputs)
            panel.finish(result); refreshPanes()
        } catch { panel.append(Localization.translate(error:error) + "\n"); panel.finish(message:"Move verification failed; source entries were retained",error:true) }
    }

}

extension MainWindowController {
    @objc func archiveMemberComment() {
        guard active.location.archive,active.selected.count == 1,let item = active.selected.first else { return }
        let archive = active.location.url
        guard let token = reservations.reserveMutation(archive) else { showError(UIError(message:"The archive is already being changed.")); return }
        Task { @MainActor in
            defer { reservations.release(token) }
            var panel: ProgressController?
            do {
                guard let engine else { throw UIError(message:"The 7-Zip engine is unavailable.") }
                let current = try await engine.memberComment(archive:archive,member:item.path)
                let form = FormDialog("Archive Entry Comment",message:item.path); let comment = form.multiline("Comment",current)
                guard form.run() else { return }; let progress = self.progress("Update Archive Comment"); panel = progress
                try await engine.setMemberComment(archive:archive,member:item.path,comment:comment.string,control:progress.control)
                progress.finish(message:"Archive comment updated"); refreshPanes()
            } catch { if let panel { panel.append(Localization.translate(error:error) + "\n"); panel.finish(message:"Archive comment was not changed",error:true) } else { showError(error) } }
        }
    }
    func pasteArchiveCut(_ session: ArchiveClipboardSession) {
        guard confirm("Complete Archive Move?","The destination will be verified before removing the selected entries from the source archive.",destructive:true) else { return }
        let destination = active.location
        if destination.archive {
            if destination.url.standardizedFileURL == session.archive.standardizedFileURL { moveMembersWithinArchive(session,to:destination.inner); return }
            add(inputs:session.files,proposed:destination.url,memberPrefix:destination.inner,allowSourceDeletion:false) { [weak self] archive,options in
                guard let self else { return }
                let panel = self.progress("Verify Destination Archive")
                do {
                    guard let engine = self.engine else { throw UIError(message:"The 7-Zip engine is unavailable.") }
                    let root = self.temporaryBaseURL.appendingPathComponent("7zipMac-movecheck-" + UUID().uuidString)
                    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); self.temporaryDirectories.append(root)
                    let members = session.files.map { file in !destination.inner.isEmpty ? destination.inner + "/" + file.lastPathComponent : options.pathMode == .relative ? file.lastPathComponent : options.pathMode == .absolute ? file.path : String(file.path.dropFirst()) }
                    let before = try await Task.detached { try contentDigest(archive) }.value
                    var extract = ExtractionOptions(destination:root); extract.password = options.password; extract.selectedPaths = members; extract.remapAbsolutePaths = true
                    let result = try await engine.extract(archive:archive,options:extract,control:panel.control)
                    guard result.succeeded,try await Task.detached(operation:{ try contentDigest(archive) }).value == before else { throw UIError(message:"The destination archive could not be verified.") }
                    panel.finish(result); await self.finishArchiveCut(session,outputs:members.map { root.appendingPathComponent((try? ArchiveCommands.remappedArchivePath($0)) ?? $0) })
                } catch { panel.append(Localization.translate(error:error) + "\n"); panel.finish(message:"Destination verification failed; source entries were retained",error:true) }
            }
        } else {
            transferFiles(session.files,to:destination.url,move:false,preserveLinkGraph:true,additionalMutations:[session.archive]) { [weak self] outcome in await self?.finishArchiveCut(session,outputs:session.files.compactMap { outcome.outputs[$0.path] },mapping:outcome.outputs,sourceAlreadyReserved:true) }
        }
    }
    func moveMembersWithinArchive(_ session: ArchiveClipboardSession, to prefix: String) {
        guard session.openMode == .automatic,let token = reservations.reserveMutation(session.archive) else { showError(UIError(message:"The source archive is busy or opened in parser mode.")); return }
        let panel = progress("Move Entries Within Archive")
        Task { @MainActor in
            defer { reservations.release(token) }
            do {
                guard let engine else { throw UIError(message:"The 7-Zip engine is unavailable.") }
                guard try await Task.detached(operation:{ try contentDigest(session.archive) }).value == session.digest else { throw UIError(message:"The source archive changed. Original entries were retained.") }
                let listing = try await engine.list(archive:session.archive,password:session.password,control:panel.control)
                var pairs: [String] = []; var destinations: Set<String> = []
                let selected = session.members.filter { member in !session.members.contains { member != $0 && member.hasPrefix($0 + "/") } }
                for member in selected {
                    let target = prefix.isEmpty ? (member as NSString).lastPathComponent : prefix + "/" + (member as NSString).lastPathComponent
                    guard target != member,!target.hasPrefix(member + "/") else { throw UIError(message:"Cannot move an entry into itself or its own subfolder.") }
                    guard destinations.insert(target.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw UIError(message:"The selected entries have conflicting destination names.") }
                    let isDirectory = listing.entries.contains { $0.path == member && $0.isDirectory } || listing.entries.contains { $0.path.hasPrefix(member + "/") }
                    try ArchiveCreationSafety.validate(member:target,directory:isDirectory,listing:listing)
                    pairs += [member,target]
                }
                var arguments = ["rn","-y","-sae","-sccUTF-8","-spd"]
                if !session.password.isEmpty { arguments += ["-p" + session.password] }
                arguments += ["--",session.archive.path] + pairs
                let result = try await engine.run(ArchiveCommand(arguments:arguments),control:panel.control)
                guard result.succeeded else { throw UIError(message:"Archive entries could not all be moved. Review the archive contents.") }
                clearArchiveClipboard(session)
                panel.finish(result); refreshPanes()
            } catch { panel.append(Localization.translate(error:error) + "\n"); panel.finish(message:"Archive move stopped or failed",error:true) }
        }
    }
}

func treeDigest(_ file: URL) throws -> String {
    let values = try file.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
    if values.isSymbolicLink == true { return "link:" + (try FileManager.default.destinationOfSymbolicLink(atPath:file.path)) }
    if values.isDirectory != true { return "file:" + (try contentDigest(file)) }
    var hash = SHA256()
    for child in try FileManager.default.contentsOfDirectory(at:file,includingPropertiesForKeys:nil).sorted(by:{ $0.lastPathComponent < $1.lastPathComponent }) {
        hash.update(data:Data((child.lastPathComponent + "\0" + (try treeDigest(child)) + "\0").utf8))
    }
    return "dir:" + hash.finalize().map { String(format:"%02x",$0) }.joined()
}

extension MainWindowController {
    @objc func toggleAutoRefresh() { UserDefaults.standard.set(!UserDefaults.standard.bool(forKey:"autoRefresh"),forKey:"autoRefresh"); configureAutoRefresh() }
    @objc func manageFavorites() {
        guard !favorites.isEmpty else { return }
        let f = FormDialog("Manage Favorites"); let selected = f.popup("Folder",favorites.map(\.path)); let remove = f.check("Remove selected favorite")
        if f.run(),remove.state == .on,let path = selected.selectedValue { favorites.removeAll { $0.path == path }; UserDefaults.standard.set(favorites.map(\.path),forKey:"favorites"); reloadSidebar() }
    }
    @objc func showExtendedAttributes() {
        guard !active.location.archive,active.selected.count == 1,let file = selectedURLs().first else { return }
        do {
            let size = listxattr(file.path,nil,0,XATTR_NOFOLLOW)
            if size < 0 { throw UIError(message:String(cString:strerror(errno))) }
            guard size <= 1_048_576 else { throw UIError(message:"Extended attribute list is too large.") }
            var names = [CChar](repeating:0,count:size)
            guard listxattr(file.path,&names,size,XATTR_NOFOLLOW) >= 0 else { throw UIError(message:String(cString:strerror(errno))) }
            let keys = names.split(separator:0).map { String(decoding:$0.map { UInt8(bitPattern:$0) },as:UTF8.self) }.sorted()
            let f = FormDialog("Extended Attributes",message:file.path)
            if keys.isEmpty { f.note("This item has no extended attributes."); f.alert.buttons[0].title = L("Close"); f.alert.buttons[1].isHidden = true; _ = f.run(); return }
            let key = f.popup("Attribute",keys); let action = f.popup("Action",["View value","Replace value (hex)","Remove attribute"])
            let value = f.multiline("Hex value","")
            f.note("macOS extended attributes are the local metadata equivalent of an alternate-stream browser. They are distinct from NTFS streams. Hex editing preserves arbitrary binary values.")
            guard f.run(),let name = key.selectedValue else { return }
            if action.indexOfSelectedItem == 0 {
                let count = getxattr(file.path,name,nil,0,0,XATTR_NOFOLLOW); guard count >= 0,count <= 16_777_216 else { throw UIError(message:"The attribute is unavailable or too large to display.") }
                var data = Data(count:count); let read = data.withUnsafeMutableBytes { getxattr(file.path,name,$0.baseAddress,count,0,XATTR_NOFOLLOW) }; guard read == count else { throw UIError(message:"The extended attribute changed while reading.") }
                let view = FormDialog("Extended Attribute Value",message:name); _ = view.multiline("Hex value",data.map { String(format:"%02x",$0) }.joined(separator:" ")); view.note(String(data:data,encoding:.utf8) ?? L("Binary data")); view.alert.buttons[0].title = L("Close"); view.alert.buttons[1].isHidden = true; _ = view.run(); return
            }
            guard confirm("Change Extended Attribute?",name,destructive:true),let token = reservations.reserveMutation(file) else { return }; defer { reservations.release(token) }
            if action.indexOfSelectedItem == 2 { guard removexattr(file.path,name,XATTR_NOFOLLOW) == 0 else { throw UIError(message:String(cString:strerror(errno))) } }
            else {
                let compact = value.string.filter { !$0.isWhitespace }; guard compact.count % 2 == 0,compact.allSatisfy({ $0.isHexDigit }) else { throw UIError(message:"Enter pairs of hexadecimal digits.") }
                var data = Data(); var index = compact.startIndex
                while index < compact.endIndex { let end = compact.index(index,offsetBy:2); data.append(UInt8(compact[index..<end],radix:16)!); index = end }
                guard data.withUnsafeBytes({ setxattr(file.path,name,$0.baseAddress,data.count,0,XATTR_NOFOLLOW) }) == 0 else { throw UIError(message:String(cString:strerror(errno))) }
            }
        } catch { showError(error) }
    }
}

@MainActor func resolveFileTransferConflict(_ conflict: ExtractionConflict, panel: ProgressController) -> ExtractionConflictResolution {
    guard !panel.cancellationRequested else { return .init(action:.cancel) }
    let form = FormDialog("Existing Destination Item",message:LF("Source: %@\nDestination: %@",conflict.archivePath,conflict.destination.path))
    let action = form.popup("Action",["Skip","Overwrite","Rename incoming item","Rename existing item"]), all = form.check("Apply this choice to all remaining conflicts")
    form.note("Replaced destination items are moved to Trash. Completed transfers remain if the operation is cancelled.")
    let dialogWindow = form.alert.window
    let timer = Timer(timeInterval:0.1,repeats:true) { _ in if panel.cancellationRequested,NSApp.modalWindow === dialogWindow { NSApp.abortModal() } }
    RunLoop.main.add(timer,forMode:.modalPanel); defer { timer.invalidate() }
    guard form.run(),!panel.cancellationRequested else { return .init(action:.cancel) }
    return .init(action:[.skip,.overwrite,.renameExtracted,.renameExisting][action.indexOfSelectedItem],applyToAll:all.state == .on)
}


extension MainWindowController {
    func moveFilesIntoArchive(_ inputs: [URL], to destination: BrowserLocation) {
        guard confirm("Move Files Into Archive?","Source files will be moved to Trash only after verifying every archived file.",destructive:true) else { return }
        Task { @MainActor [self] in
            do {
                guard !SHA256Manifest.wouldReplaceInput(output:destination.url,inputs:inputs) else { throw UIError(message:"The output archive cannot replace a selected source.") }
                let root = temporaryBaseURL.appendingPathComponent("7zipMac-stage-move-" + UUID().uuidString)
                try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]); temporaryDirectories.append(root)
                let snapshots = try await Task.detached { () throws -> ([URL],[String]) in
                    var copies: [URL] = []; var hashes: [String] = []; var names: Set<String> = []
                    for file in inputs {
                        guard names.insert(file.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw UIError(message:"The selected entries have conflicting destination names.") }
                        let before = try treeDigest(file), copy = root.appendingPathComponent(file.lastPathComponent)
                        try FileManager.default.copyItem(at:file,to:copy); try verifyTransferredItem(file,copy)
                        guard try treeDigest(file) == before else { throw UIError(message:"A source changed while preparing the move.") }
                        copies.append(copy); hashes.append(before)
                    }; return (copies,hashes)
                }.value
                add(inputs:snapshots.0,proposed:destination.url,memberPrefix:destination.inner,allowSourceDeletion:false,additionalMutations:inputs) { [weak self] archive,options in
                    guard let self else { return }; let panel = self.progress("Verify and Complete Archive Move")
                    do {
                        guard let engine = self.engine else { throw UIError(message:"The 7-Zip engine is unavailable.") }
                        let checkRoot = self.temporaryBaseURL.appendingPathComponent("7zipMac-move-proof-" + UUID().uuidString)
                        try FileManager.default.createDirectory(at:checkRoot,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:checkRoot) }
                        let members: [String]
                        if !destination.inner.isEmpty { members = snapshots.0.map { destination.inner + "/" + $0.lastPathComponent } }
                        else if options.pathMode == .relative { members = snapshots.0.map(\.lastPathComponent) }
                        else { members = snapshots.0.map { options.pathMode == .absolute ? $0.path : String($0.path.dropFirst()) } }
                        var extraction = ExtractionOptions(destination:checkRoot); extraction.selectedPaths = members; extraction.password = options.password; extraction.remapAbsolutePaths = true
                        let result = try await engine.extract(archive:archive,options:extraction,control:panel.control)
                        guard result.succeeded else { throw UIError(message:"Archive verification failed. Original entries were retained.") }
                        try await Task.detached {
                            for (index,file) in inputs.enumerated() {
                                guard try treeDigest(file) == snapshots.1[index] else { throw UIError(message:"A source changed. Original files were retained.") }
                                try verifyTransferredItem(file,checkRoot.appendingPathComponent(try ArchiveCommands.remappedArchivePath(members[index])))
                            }
                        }.value
                        if panel.cancellationRequested { throw ArchiveError.cancelled }
                        for (index,file) in inputs.enumerated() {
                            guard try treeDigest(file) == snapshots.1[index] else { throw UIError(message:"A source changed. Original files were retained.") }
                            try FileManager.default.trashItem(at:file,resultingItemURL:nil)
                        }
                        panel.finish(message:"Completed successfully"); self.refreshPanes()
                    } catch { panel.append(Localization.translate(error:error) + "\n"); panel.finish(message:"Move verification failed; source entries were retained",error:true) }
                }
            } catch { showError(error) }
        }
    }
}


/// Resolve existing ancestors with realpath while preserving the leaf, even after
/// a move has removed the source. Foundation intentionally retains /var aliases.
func canonicalTransferPath(_ url: URL) -> String {
    var parent = url.deletingLastPathComponent(), suffix = [url.lastPathComponent]
    while true {
        if let pointer = Darwin.realpath(parent.path,nil) {
            let root = String(cString:pointer); Darwin.free(pointer)
            var parts = root.split(separator:"/").map(String.init)
            for component in suffix.reversed() {
                if component == ".." { if !parts.isEmpty { parts.removeLast() } }
                else if component != "." && !component.isEmpty { parts.append(component) }
            }
            return "/" + parts.joined(separator:"/")
        }
        guard parent.path != "/" else { return url.standardizedFileURL.path }
        suffix.append(parent.lastPathComponent); parent.deleteLastPathComponent()
    }
}
func mappedTransferPath(_ source: URL, mapping: [String:URL]) -> URL? {
    if let exact = mapping[source.path] { return exact }
    let canonical = canonicalTransferPath(source)
    let candidates = mapping.map { key,value in (canonicalTransferPath(URL(fileURLWithPath:key)),value) }
    if let exact = candidates.first(where:{ $0.0 == canonical }) { return exact.1 }
    guard let match = candidates.filter({ canonical.hasPrefix($0.0 + "/") }).max(by:{ $0.0.count < $1.0.count }) else { return nil }
    return match.1.appendingPathComponent(String(canonical.dropFirst(match.0.count + 1)))
}
func rewriteTransferredLinks(inputs: [URL], mapping: [String:URL]) throws {
    func visit(_ source: URL) throws {
        let values = try source.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            let link = try FileManager.default.destinationOfSymbolicLink(atPath:source.path)
            let sourceTarget = source.deletingLastPathComponent().appendingPathComponent(link).standardizedFileURL
            guard let output = mappedTransferPath(source,mapping:mapping),let target = mappedTransferPath(sourceTarget,mapping:mapping) else { throw UIError(message:"A transferred link target is not included. Original archive entries were retained.") }
            let from = output.deletingLastPathComponent().standardizedFileURL.pathComponents, to = target.standardizedFileURL.pathComponents
            var common = 0; while common < min(from.count,to.count),from[common] == to[common] { common += 1 }
            let relative = (Array(repeating:"..",count:from.count-common) + Array(to.dropFirst(common))).joined(separator:"/")
            guard !relative.isEmpty else { throw UIError(message:"Transferred link target does not match.") }
            if link != relative { try FileManager.default.removeItem(at:output); try FileManager.default.createSymbolicLink(atPath:output.path,withDestinationPath:relative) }
        } else if values.isDirectory == true { for child in try FileManager.default.contentsOfDirectory(at:source,includingPropertiesForKeys:nil) { try visit(child) } }
    }
    for input in inputs { try visit(input) }
}
