import AppKit
import ArchiveCore
import CryptoKit
import Darwin

extension MainWindowController {
    @objc func invertSelection() {
        let all = IndexSet(integersIn:0..<active.visible.count)
        active.table.selectRowIndexes(all.subtracting(active.table.selectedRowIndexes),byExtendingSelection:false)
    }
    @objc func selectPattern() {
        updatePatternSelection(deselect:false)
    }
    @objc func selectType() { updateTypeSelection(deselect:false) }
    @objc func newFile() {
        if active.location.archive { createArchiveEntry(directory:false); return }
        guard let name = prompt("New Empty File",value:"Untitled.txt"), !name.isEmpty,name != ".",name != "..",!name.contains("/") else { return }
        let url = active.location.url.appendingPathComponent(name)
        let descriptor = Darwin.open(url.path,O_WRONLY | O_CREAT | O_EXCL,0o644)
        if descriptor < 0 { showError(UIError(message:String(cString:strerror(errno)))); return }
        Darwin.close(descriptor); refreshPanes()
    }
    @objc func createLink() {
        guard !active.location.archive,let source = selectedURLs().first else { return }
        let form = FormDialog("Create Link",message:source.path)
        let kind = form.popup("Link type",["Symbolic link","Hard link (files only)"])
        let path = form.field("Link path",source.deletingLastPathComponent().appendingPathComponent(source.lastPathComponent + " link").path)
        guard form.run(),!path.stringValue.isEmpty else { return }
        let target = URL(fileURLWithPath:(path.stringValue as NSString).expandingTildeInPath)
        do {
            if kind.indexOfSelectedItem == 0 { try FileManager.default.createSymbolicLink(at:target,withDestinationURL:source) }
            else { try FileManager.default.linkItem(at:source,to:target) }
            refreshPanes()
        } catch { showError(error) }
    }
    @objc func finderComment() {
        if active.location.archive { archiveMemberComment(); return }
        guard let file = selectedURLs().first else { return }
        let key = "com.apple.metadata:kMDItemFinderComment"
        var existing = ""
        let count = getxattr(file.path,key,nil,0,0,XATTR_NOFOLLOW)
        if count > 0 && count < 1_048_576 {
            var data = Data(count:count)
            let read = data.withUnsafeMutableBytes { getxattr(file.path,key,$0.baseAddress,count,0,XATTR_NOFOLLOW) }
            if read == count { existing = (try? PropertyListSerialization.propertyList(from:data,options:[],format:nil)) as? String ?? "" }
        }
        guard let comment = prompt("Finder Comment",message:file.lastPathComponent,value:existing) else { return }
        do {
            let data = try PropertyListSerialization.data(fromPropertyList:comment,format:.binary,options:0)
            let result = data.withUnsafeBytes { setxattr(file.path,key,$0.baseAddress,data.count,0,XATTR_NOFOLLOW) }
            if result < 0 { throw UIError(message:String(cString:strerror(errno))) }
        } catch { showError(error) }
    }
    @objc func compareSelected() {
        let items = active.selected; guard items.count == 2 else { return }
        if active.location.archive { materializeMany(items) { [weak self] files in self?.compare(files) } }
        else { compare(items.compactMap(\.url)) }
    }
    func compare(_ files: [URL]) {
        guard files.count == 2 else { return }
        if let configured = UserDefaults.standard.string(forKey:"diffProgramPath"),!configured.isEmpty,URL(fileURLWithPath:configured).pathExtension == "app" {
            NSWorkspace.shared.open(files,withApplicationAt:URL(fileURLWithPath:configured),configuration:NSWorkspace.OpenConfiguration()) { _,error in if let error { DispatchQueue.main.async { showError(error) } } }; return
        }
        let panel = progress("Compare Files")
        Task { @MainActor in
            do {
                let configured = UserDefaults.standard.string(forKey:"diffProgramPath") ?? ""
                let diff = SevenZipEngine(binaryURL:URL(fileURLWithPath:configured.isEmpty ? "/usr/bin/diff" : configured))
                let arguments = configured.isEmpty ? ["-ru","--"] : (UserDefaults.standard.string(forKey:"diffArguments") ?? "").split(separator:" ").map(String.init)
                let result = try await diff.run(ArchiveCommand(arguments:arguments + files.map(\.path)),control:panel.control,onOutput:{ text in Task { @MainActor in panel.append(text) } })
                panel.finish(message:result.exitCode == 0 ? "Files are identical" : "Differences found",error:result.exitCode > 1)
            } catch { panel.append(Localization.translate(error:error) + "\n"); panel.finish(message:"Comparison stopped or failed",error:true) }
        }
    }
    @objc func createChecksumManifest() {
        let items = active.selected.filter { !$0.directory }
        guard !items.isEmpty else { return }
        if active.location.archive { materializeMany(items) { [weak self] files in self?.writeManifest(files) } }
        else { writeManifest(items.compactMap(\.url)) }
    }
    func writeManifest(_ files: [URL]) {
        guard !files.isEmpty,let output = saveURL("Save SHA-256 Manifest",name:"checksums.sha256",initial:files[0].deletingLastPathComponent()) else { return }
        guard !SHA256Manifest.wouldReplaceInput(output:output,inputs:files) else { showError(UIError(message:"The manifest output cannot replace a selected input file or its link. Choose a different file.")); return }
        let base = output.deletingLastPathComponent().standardizedFileURL
        guard files.allSatisfy({ $0.standardizedFileURL.path.hasPrefix(base.path + "/") }) else { showError(UIError(message:"Save the manifest in a parent folder containing every selected file. Relative paths keep the manifest portable.")); return }
        guard files.allSatisfy({ !$0.path.contains("\n") && !$0.path.contains("\r") && !$0.path.contains("\\") }) else { showError(UIError(message:"Checksum manifests cannot represent names containing newlines or backslashes.")); return }
        let panel = progress("Write SHA-256 Manifest"); panel.pauseButton.isEnabled = false
        Task.detached {
            do {
                var lines: [String] = []
                for (index,file) in files.enumerated() {
                    let digest = try await sha256(file,panel:panel)
                    let name = String(file.standardizedFileURL.path.dropFirst(base.path.count + 1))
                    lines.append(digest + "  " + name)
                    await MainActor.run { panel.append(name + "\n"); panel.fraction(Double(index + 1)/Double(files.count)) }
                }
                if await MainActor.run(body:{ panel.cancellationRequested }) { throw ArchiveError.cancelled }
                try (lines.joined(separator:"\n") + "\n").write(to:output,atomically:true,encoding:.utf8)
                await MainActor.run { panel.finish(message:"SHA-256 manifest saved") }
            } catch { await MainActor.run { panel.append(Localization.translate(error:error) + "\n"); panel.finish(message:"Checksum creation stopped or failed",error:true) } }
        }
    }
    @objc func verifyChecksumManifest() {
        let chooser = NSOpenPanel(); chooser.title = L("Verify SHA-256 Manifest"); chooser.canChooseDirectories = false
        guard chooser.runModal() == .OK,let manifest = chooser.url else { return }
        let panel = progress("Verify SHA-256 Manifest"); panel.pauseButton.isEnabled = false
        Task.detached {
            do {
                let contents = try String(contentsOf:manifest,encoding:.utf8)
                let lines = contents.components(separatedBy:.newlines).filter { !$0.isEmpty && !$0.hasPrefix("#") }
                guard !lines.isEmpty else { throw UIError(message:"Manifest contains no checksums.") }
                var failures = 0
                for (index,line) in lines.enumerated() {
                    let entry = try SHA256Manifest.parse(line)
                    let name = entry.name
                    let file = manifest.deletingLastPathComponent().appendingPathComponent(name)
                    let expected = entry.digest
                    do {
                        let actual = try await sha256(file,panel:panel)
                        if actual != expected { failures += 1 }
                        await MainActor.run { panel.append((actual == expected ? "OK: " : "FAILED: ") + name + "\n") }
                    } catch ArchiveError.cancelled { throw ArchiveError.cancelled }
                    catch { failures += 1; await MainActor.run { panel.append("FAILED: " + name + " — " + Localization.translate(error:error) + "\n") } }
                    await MainActor.run { panel.fraction(Double(index + 1)/Double(lines.count)) }
                }
                let failureCount = failures
                await MainActor.run { panel.finish(message:failureCount == 0 ? "All checksums match" : "\(failureCount) checksum(s) failed",error:failureCount != 0) }
            } catch { await MainActor.run { panel.append(Localization.translate(error:error) + "\n"); panel.finish(message:"Verification stopped or failed",error:true) } }
        }
    }
}

private func sha256(_ file: URL, panel: ProgressController) async throws -> String {
    let handle = try FileHandle(forReadingFrom:file); defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount:1_048_576),!data.isEmpty {
        if await MainActor.run(body:{ panel.cancellationRequested }) { throw ArchiveError.cancelled }
        hash.update(data:data)
    }
    return hash.finalize().map { String(format:"%02x",$0) }.joined()
}
