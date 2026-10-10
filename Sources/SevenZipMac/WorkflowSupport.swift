import Foundation
import ArchiveCore
import Darwin

/// Reservations cover every UI entry point, including Finder/Services and editor reimport.
final class OperationReservations {
    private let lock = NSLock()
    private var mutations: [String:UUID] = [:]
    private var destinations: [String:UUID] = [:]
    static func reservationPath(_ url: URL) -> String {
        if let pointer = Darwin.realpath(url.path,nil) {
            let path = String(cString:pointer); Darwin.free(pointer)
            return path.precomposedStringWithCanonicalMapping.lowercased()
        }
        return canonicalTransferPath(url).precomposedStringWithCanonicalMapping.lowercased()
    }
    static func mutationKeys(_ url: URL) -> [String] {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        var keys = ["path:" + reservationPath(url)]
        if let attributes = try? FileManager.default.attributesOfItem(atPath:resolved.path), let inode = attributes[.systemFileNumber] as? NSNumber, let device = attributes[.systemNumber] as? NSNumber { keys.append("inode:\(device):\(inode)") }
        return keys
    }
    func reserveMutation(_ url: URL) -> UUID? { reserveMutations([url]) }
    func reserveMutations(_ urls: [URL]) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        let keys = urls.flatMap(Self.mutationKeys)
        let paths = urls.map(Self.reservationPath)
        guard !keys.contains(where:{ mutations[$0] != nil }),
              !paths.contains(where:{ path in
                  mutations.keys.filter({ $0.hasPrefix("path:") }).contains(where:{ let existing = String($0.dropFirst(5)); return Self.contains(existing,path) || Self.contains(path,existing) }) ||
                  destinations.keys.contains(where:{ Self.contains($0,path) || Self.contains(path,$0) })
              }) else { return nil }
        let token = UUID(); keys.forEach { mutations[$0] = token }; return token
    }
    func reserveDestination(_ url: URL) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        let path = Self.reservationPath(url)
        guard !destinations.keys.contains(where:{ Self.contains($0,path) || Self.contains(path,$0) }),
              !mutations.keys.filter({ $0.hasPrefix("path:") }).contains(where:{ let mutation = String($0.dropFirst(5)); return Self.contains(path,mutation) || Self.contains(mutation,path) }) else { return nil }
        let token = UUID(); destinations[path] = token; return token
    }
    private static func contains(_ parent: String, _ child: String) -> Bool { parent == "/" || child == parent || child.hasPrefix(parent + "/") }
    func release(_ token: UUID) {
        lock.lock(); defer { lock.unlock() }
        mutations = mutations.filter { $0.value != token }; destinations = destinations.filter { $0.value != token }
    }
}

struct ConsoleDisplayBuffer {
    private var buffer = ""
    mutating func consume(_ text: String) -> String {
        var output = ""
        for character in text {
            switch character {
            case "\u{8}": if !buffer.isEmpty { buffer.removeLast() }
            case "\r": buffer = ""
            case "\n": output += finishLine()
            default: if character == "\t" || character.unicodeScalars.allSatisfy({ $0.value >= 32 }) { buffer.append(character) }
            }
            if buffer.count > 8192 { output += finishLine() }
        }
        return output
    }
    mutating func finishLine() -> String {
        let line = buffer.trimmingCharacters(in:.whitespaces); buffer = ""
        guard !line.isEmpty, line.range(of:"^\\d{1,3}%",options:.regularExpression) == nil else { return "" }
        return line + "\n"
    }
}

enum ArchiveEditCommand {
    static func make(archive: URL, file: URL, member: String, format: String, password: String) throws -> ArchiveCommand {
        let normalized = member.replacingOccurrences(of:"\\",with:"/")
        let parts = normalized.split(separator:"/",omittingEmptySubsequences:false)
        guard !normalized.hasPrefix("/"),!parts.contains(".."),!parts.contains(""),!member.contains(":"),!member.contains("\n"),!member.contains("\r"),!member.contains("\0") else { throw UIError(message:"The archive member path is unsafe.") }
        var root = file
        for _ in parts { root.deleteLastPathComponent() }
        guard root.appendingPathComponent(normalized).standardizedFileURL == file.standardizedFileURL else { throw UIError(message:"The extracted edit path does not match its archive member.") }
        var options = CompressionOptions(); options.format = format; options.password = password
        // Never reveal names when updating an existing passworded 7z archive.
        options.encryptHeaders = format == "7z" && !password.isEmpty
        return try ArchiveExactInputCommand.make(archive:archive,inputs:[file],members:[normalized],root:root,options:options)
    }
}

/// Runs without showing app windows; used by the native bundle's objective regression check.
enum UIWorkflowChecks {
    static func run() throws {
        let manager = FileManager.default
        let dir = manager.temporaryDirectory.appendingPathComponent("SevenZipUI-check-" + UUID().uuidString)
        try manager.createDirectory(at:dir,withIntermediateDirectories:true); defer { try? manager.removeItem(at:dir) }
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) throws { guard condition() else { throw UIError(message:"FAIL: " + label) }; print("PASS: " + label) }
        let archive = dir.appendingPathComponent("archive.7z"); try Data("test".utf8).write(to:archive)
        let alias = dir.appendingPathComponent("hardlink.7z"); try manager.linkItem(at:archive,to:alias)
        let symlink = dir.appendingPathComponent("symbolic.7z"); try manager.createSymbolicLink(at:symlink,withDestinationURL:archive)
        let reservations = OperationReservations()
        let token = reservations.reserveMutation(archive)!
        try expect(reservations.reserveMutation(alias) == nil,"hard-link mutation collision rejected")
        try expect(reservations.reserveMutation(symlink) == nil,"symbolic-link mutation collision rejected")
        try expect(reservations.reserveDestination(dir) == nil,"extraction containing an archive mutation rejected")
        reservations.release(token)
        let next = reservations.reserveMutation(alias); try expect(next != nil,"mutation reservation released"); reservations.release(next!)
        let output = dir.appendingPathComponent("out",isDirectory:true); let destToken = reservations.reserveDestination(output)!
        try expect(reservations.reserveDestination(output.appendingPathComponent("child")) == nil,"child extraction collision rejected")
        try expect(reservations.reserveDestination(dir) == nil,"ancestor extraction collision rejected")
        try expect(reservations.reserveMutation(output.appendingPathComponent("new.7z")) == nil,"archive mutation inside extraction destination rejected")
        try expect(reservations.reserveDestination(dir.appendingPathComponent("out-other")) != nil,"unrelated extraction allowed")
        reservations.release(destToken)
        try expect(reservations.reserveDestination(output) != nil,"destination reservation released")
        let caseToken = reservations.reserveMutation(dir.appendingPathComponent("NewArchive.7z"))!
        try expect(reservations.reserveMutation(dir.appendingPathComponent("newarchive.7z")) == nil,"case-alias mutation collision rejected before creation")
        reservations.release(caseToken)
        let nested = dir.appendingPathComponent("edit/folder/member.txt"); try manager.createDirectory(at:nested.deletingLastPathComponent(),withIntermediateDirectories:true); try Data("edit".utf8).write(to:nested)
        let edit = try ArchiveEditCommand.make(archive:archive,file:nested,member:"folder/member.txt",format:"7z",password:"private")
        try expect(edit.arguments.contains("-i!folder/member.txt") && edit.arguments.contains("-spf") && edit.arguments.contains("-spd") && edit.arguments.last == archive.path,"nested reimport exact include and relative path preserved")
        try expect(edit.workingDirectory == dir.appendingPathComponent("edit"),"nested reimport extraction root preserved")
        try expect(edit.arguments.contains("-mhe=on"),"reimport retains encrypted file names")
        try expect(!edit.redactedDescription.contains("private"),"reimport password description redacted")
        var deleteOptions = CompressionOptions(); deleteOptions.deleteSourcesAfterCompression = true
        let deletionCommand = try ArchiveCommands.create(archive:dir.appendingPathComponent("delete-option.7z"),inputs:[nested],options:deleteOptions)
        try expect(deletionCommand.arguments.contains("-sdel"),"compression delete-source option uses official engine switch")
        var display = ConsoleDisplayBuffer()
        let rendered = display.consume("Start\n 10%\u{8}\u{8}\u{8}\u{8}    \r") + display.consume("Everything is Ok\n") + display.finishLine()
        try expect(rendered == "Start\nEverything is Ok\n","console progress control characters normalized")
        let digest = String(repeating:"a",count:64)
        let starEntry = try SHA256Manifest.parse(digest + "  *leading-star.txt")
        try expect(starEntry.name == "*leading-star.txt","manifest preserves leading literal star")
        let spacedEntry = try SHA256Manifest.parse(digest + "   leading and trailing .txt ")
        try expect(spacedEntry.name == " leading and trailing .txt ","manifest preserves filename whitespace")
        let binaryEntry = try SHA256Manifest.parse(digest + " *binary.txt")
        try expect(binaryEntry.name == "binary.txt","manifest accepts binary marker")
        try expect(SHA256Manifest.wouldReplaceInput(output:alias,inputs:[archive]),"manifest refuses hard-link input overwrite")
        let destination = dir.appendingPathComponent("clipboard-destination"); try manager.createDirectory(at:destination,withIntermediateDirectories:true)
        try FileTransferPlan.validate(inputs:[nested],destination:destination)
        print("PASS: clipboard accepts an ordinary file transfer")
        var refusedSameFile = false; do { try FileTransferPlan.validate(inputs:[nested],destination:nested.deletingLastPathComponent()) } catch { refusedSameFile = true }; try expect(refusedSameFile,"clipboard refuses same-file overwrite")
        var refusedRecursive = false; do { try FileTransferPlan.validate(inputs:[dir],destination:destination) } catch { refusedRecursive = true }; try expect(refusedRecursive,"clipboard refuses recursive folder transfer")
        try expect(FileSelection.patternIndexes("*.txt",items:["a.txt","folder","b.txt"]) == IndexSet([0,2]),"file selection wildcard matching")
        try checkRealReimport(in:dir)
        try ParityChecks.run(in:dir)
        print("UI workflow regression checks complete.")
    }
    private static func checkRealReimport(in dir: URL) throws {
        let engine = SevenZipEngine(binaryURL:try SevenZipEngine.locateBinary())
        let source = dir.appendingPathComponent("real-edit",isDirectory:true)
        let folder = source.appendingPathComponent("folder",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let names = ["member.txt","@member.txt","star*.txt","star-sibling.txt","é.txt"]
        for name in names { try Data(("original-" + name).utf8).write(to:folder.appendingPathComponent(name)) }
        let archive = dir.appendingPathComponent("real-edit.7z")
        var options = CompressionOptions(); options.password = "regression-password"; options.encryptHeaders = true
        let initial = try ArchiveCommands.create(archive:archive,inputs:[folder],options:options)
        _ = try awaitResult { try await engine.run(initial,control:OperationControl()) }
        let before = try awaitResult { try await engine.list(archive:archive,password:"regression-password") }
        let baselinePaths = Set(before.entries.map(\.path))
        for name in names.prefix(3) {
            let file = folder.appendingPathComponent(name)
            try Data(("changed-and-confirmed-" + name).utf8).write(to:file)
            let command = try ArchiveEditCommand.make(archive:archive,file:file,member:"folder/" + name,format:"7z",password:"regression-password")
            _ = try awaitResult { try await engine.run(command,control:OperationControl()) }
        }
        let after = try awaitResult { try await engine.list(archive:archive,password:"regression-password") }
        guard Set(after.entries.map(\.path)) == baselinePaths else { throw UIError(message:"FAIL: real-engine reimport created or removed member paths.") }
        print("PASS: real-engine nested, @ and wildcard reimport retain exact member paths")
        let destination = dir.appendingPathComponent("real-readback")
        var extractOptions = ExtractionOptions(destination:destination); extractOptions.password = "regression-password"
        let readbackOptions = extractOptions
        _ = try awaitResult { try await engine.extract(archive:archive,options:readbackOptions,control:OperationControl()) }
        for name in names.prefix(3) {
            let contents = try Data(contentsOf:destination.appendingPathComponent("folder/" + name))
            guard contents == Data(("changed-and-confirmed-" + name).utf8) else { throw UIError(message:"FAIL: real-engine reimport did not update " + name) }
            print("PASS: real-engine reimport changed bytes for " + name)
        }
        let sibling = try Data(contentsOf:destination.appendingPathComponent("folder/star-sibling.txt"))
        guard sibling == Data("original-star-sibling.txt".utf8) else { throw UIError(message:"FAIL: wildcard reimport changed a sibling.") }
        print("PASS: real-engine wildcard reimport leaves sibling bytes unchanged")
        do {
            _ = try awaitResult { try await engine.list(archive:archive) }
            throw UIError(message:"FAIL: real-engine reimport exposed encrypted member names.")
        } catch is ArchiveError { print("PASS: real-engine reimport retains header encryption") }
        let collisionSnapshot = try Data(contentsOf:archive)
        for (member,directory) in [("folder/member.txt",false),("folder/member.txt",true),("folder/MEMBER.txt",false),("folder/e\u{301}.txt",false),("folder/member.txt/child",false),("folder",false)] {
            var refused = false
            do { try ArchiveCreationSafety.validate(member:member,directory:directory,listing:after) } catch { refused = true }
            guard refused else { throw UIError(message:"FAIL: new archive entry accepted collision " + member) }
        }
        guard try Data(contentsOf:archive) == collisionSnapshot else { throw UIError(message:"FAIL: collision rejection changed archive bytes.") }
        print("PASS: real-archive exact, case, Unicode, ancestor and descendant creation collisions preserve valuable archive bytes")
        let newFolder = folder.appendingPathComponent("new empty folder",isDirectory:true)
        let newFile = folder.appendingPathComponent("new empty file.txt")
        try FileManager.default.createDirectory(at:newFolder,withIntermediateDirectories:true); try Data().write(to:newFile)
        let additions = try ArchiveExactInputCommand.make(archive:archive,inputs:[newFolder,newFile],members:["folder/new empty folder","folder/new empty file.txt"],root:source,options:options)
        _ = try awaitResult { try await engine.run(additions,control:OperationControl()) }
        let withAdditions = try awaitResult { try await engine.list(archive:archive,password:"regression-password") }
        let addedPaths = Set(withAdditions.entries.map(\.path)).subtracting(baselinePaths)
        guard addedPaths == Set(["folder/new empty folder","folder/new empty file.txt"]),withAdditions.entries.first(where:{ $0.path == "folder/new empty folder" })?.isDirectory == true else { throw UIError(message:"FAIL: exact archive folder/file creation produced unexpected paths.") }
        print("PASS: real-engine creates archive folder and empty file at exact nested paths")
    }
    static func awaitResult<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value:0), box = SynchronousCheckResult<T>()
        Task.detached {
            do { box.store(.success(try await body())) } catch { box.store(.failure(error)) }
            semaphore.signal()
        }
        guard semaphore.wait(timeout:.now() + 30) == .success else { throw UIError(message:"Real-engine regression timed out.") }
        return try box.load().get()
    }

}

enum SHA256Manifest {
    struct Entry { let digest: String; let name: String }
    static func parse(_ line: String) throws -> Entry {
        let bytes = Array(line.utf8)
        guard bytes.count > 66, bytes[64] == 32, [UInt8(32),UInt8(42)].contains(bytes[65]), bytes.prefix(64).allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw UIError(message:"Invalid SHA-256 manifest entry. Use '<64 hex digits><space><space or *><relative filename>'.") }
        let name = String(decoding:bytes.dropFirst(66),as:UTF8.self)
        guard !name.hasPrefix("/"), !name.split(separator:"/").contains(".."), !name.contains("\0"), !name.contains("\n"), !name.contains("\r"), !name.isEmpty else { throw UIError(message:"Manifest contains an unsafe file path.") }
        return Entry(digest:String(decoding:bytes.prefix(64),as:UTF8.self).lowercased(),name:name)
    }
    static func wouldReplaceInput(output: URL, inputs: [URL]) -> Bool {
        let outputKeys = Set(OperationReservations.mutationKeys(output))
        return inputs.contains { !outputKeys.isDisjoint(with:OperationReservations.mutationKeys($0)) }
    }
}

private final class SynchronousCheckResult<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T,Error>?
    func store(_ result: Result<T,Error>) { lock.lock(); self.result = result; lock.unlock() }
    func load() -> Result<T,Error> { lock.lock(); defer { lock.unlock() }; return result! }
}

enum ArchiveMemberPath {
    static func validate(_ member: String) throws -> String {
        let normalized = member.replacingOccurrences(of:"\\",with:"/")
        let parts = normalized.split(separator:"/",omittingEmptySubsequences:false)
        guard !normalized.hasPrefix("/"),!normalized.hasPrefix("~"),!parts.contains(".."),!parts.contains("."),!parts.contains(""),!member.contains(":"),!member.contains("\n"),!member.contains("\r"),!member.contains("\0") else { throw UIError(message:"The archive member path is unsafe.") }
        return normalized
    }
}
enum ArchiveExactInputCommand {
    static func make(archive: URL, inputs: [URL], members: [String], root: URL, options: CompressionOptions) throws -> ArchiveCommand {
        guard inputs.count == members.count,!inputs.isEmpty else { throw UIError(message:"Each input needs an archive member path.") }
        let paths = try members.map(ArchiveMemberPath.validate)
        for (input,path) in zip(inputs,paths) { guard root.appendingPathComponent(path).standardizedFileURL == input.standardizedFileURL else { throw UIError(message:"The input path does not match its archive member.") } }
        let base = try ArchiveCommands.create(archive:archive,inputs:inputs,options:options)
        var args = base.arguments
        guard let separator = args.firstIndex(of:"--"),args.indices.contains(separator + 1) else { throw UIError(message:"Could not locate the archive operand.") }
        args.removeSubrange((separator + 2)..<args.count)
        args.insert(contentsOf:["-spf"] + paths.map { "-i!" + $0 },at:separator)
        return ArchiveCommand(arguments:args,workingDirectory:root)
    }
}
enum FileSelection {
    static func patternIndexes(_ pattern: String, items: [String]) -> IndexSet {
        let escaped = NSRegularExpression.escapedPattern(for:pattern).replacingOccurrences(of:"\\*",with:".*").replacingOccurrences(of:"\\?",with:".")
        guard let regex = try? NSRegularExpression(pattern:"^" + escaped + "$") else { return [] }
        return IndexSet(items.indices.filter { regex.firstMatch(in:items[$0],range:NSRange(items[$0].startIndex...,in:items[$0])) != nil })
    }
}
enum FileTransferPlan {
    static func validate(inputs: [URL], destination: URL, allowConflicts: Bool = false) throws {
        guard !inputs.isEmpty,inputs.allSatisfy(\.isFileURL) else { throw UIError(message:"Choose local file inputs.") }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath:destination.path,isDirectory:&directory),directory.boolValue else { throw UIError(message:"Choose an existing destination folder.") }
        let resolvedDestination = destination.standardizedFileURL.resolvingSymlinksInPath()
        var seen: Set<String> = []
        for input in inputs {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath:input.path,isDirectory:&isDirectory) else { throw UIError(message:"Input no longer exists: " + input.path) }
            let source = input.standardizedFileURL.resolvingSymlinksInPath()
            if isDirectory.boolValue && (resolvedDestination.path.lowercased() == source.path.lowercased() || resolvedDestination.path.lowercased().hasPrefix(source.path.lowercased() + "/")) { throw UIError(message:"A folder cannot be copied or moved into itself.") }
            let target = destination.appendingPathComponent(input.lastPathComponent)
            guard !SHA256Manifest.wouldReplaceInput(output:target,inputs:[input]),(allowConflicts || !FileManager.default.fileExists(atPath:target.path)) else { throw UIError(message:"The destination already contains " + input.lastPathComponent + ". Choose another folder or rename the existing item.") }
            guard seen.insert(target.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw UIError(message:"Two inputs have the same destination name.") }
        }
    }
}

enum ArchiveCreationSafety {
    static func validate(member: String, directory: Bool, listing: ArchiveListing) throws {
        func key(_ path: String) throws -> String { try ArchiveMemberPath.validate(path).precomposedStringWithCanonicalMapping.lowercased() }
        let target = try key(member)
        for entry in listing.entries {
            var entryPath = entry.path
            if entry.isDirectory { while entryPath.hasSuffix("/") || entryPath.hasSuffix("\\") { entryPath.removeLast() } }
            let existing = try key(entryPath)
            if existing == target || existing.hasPrefix(target + "/") { throw UIError(message:"An archive item already exists at this name or below it. Choose a different name; New never replaces existing entries.") }
            if target.hasPrefix(existing + "/") && !entry.isDirectory { throw UIError(message:"A file occupies a parent of the requested archive path. Choose another folder.") }
        }
    }
}
