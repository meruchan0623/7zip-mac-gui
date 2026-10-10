import Foundation
import Darwin

/// One control belongs to one workflow. Cancellation remains terminal across preflight and extraction.
public final class OperationControl: @unchecked Sendable {
    private let condition = NSCondition()
    private var process: Process?
    private var cancelled = false
    private var paused = false
    public init() {}
    public func cancel() {
        condition.lock(); cancelled = true; paused = false
        let running = process
        if let running, running.isRunning { kill(running.processIdentifier, SIGCONT); kill(running.processIdentifier, SIGTERM) }
        condition.broadcast(); condition.unlock()
        if let running {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { [weak self, weak running] in
                guard let self, let running else { return }
                self.condition.lock(); defer { self.condition.unlock() }
                if self.process === running, running.isRunning { kill(running.processIdentifier, SIGKILL) }
            }
        }
    }
    public func pause() { condition.lock(); paused = true; if let process, process.isRunning, !cancelled { kill(process.processIdentifier, SIGSTOP) }; condition.unlock() }
    public func resume() { condition.lock(); paused = false; if let process, process.isRunning { kill(process.processIdentifier, SIGCONT) }; condition.broadcast(); condition.unlock() }
    public func checkpoint() throws {
        condition.lock(); defer { condition.unlock() }
        while paused && !cancelled { condition.wait() }
        if cancelled { throw ArchiveError.cancelled }
    }
    func launch(_ process: Process) throws {
        condition.lock(); defer { condition.unlock() }
        if cancelled { throw ArchiveError.cancelled }
        guard self.process == nil else { throw ArchiveError.invalid("This operation control already has a running process.") }
        try process.run(); self.process = process
        if paused { kill(process.processIdentifier, SIGSTOP) }
    }
    func detach(_ process: Process) { condition.lock(); if self.process === process { self.process = nil }; condition.unlock() }
}

/// Keeps incomplete multibyte characters until the next pipe read.
struct UTF8StreamDecoder {
    private var pending: [UInt8] = []
    mutating func decode(_ data: Data, final: Bool = false) -> String {
        pending.append(contentsOf: data)
        var end = pending.count
        if !final && end > 0 {
            var start = end - 1
            while start > 0 && pending[start] & 0xC0 == 0x80 { start -= 1 }
            let byte = pending[start]
            let expected = byte < 0x80 ? 1 : byte & 0xE0 == 0xC0 ? 2 : byte & 0xF0 == 0xE0 ? 3 : byte & 0xF8 == 0xF0 ? 4 : 1
            if end - start < expected { end = start }
        }
        let text = String(decoding: pending.prefix(end), as: UTF8.self)
        pending.removeFirst(end)
        return text
    }
}
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let passwords: [String]
    private let callback: @Sendable (String) -> Void
    private var pending = ""
    private var output = ""
    private var rawOutput = ""
    init(passwords: [String], callback: @escaping @Sendable (String) -> Void) { self.passwords = passwords; self.callback = callback }
    func append(_ text: String, final: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        rawOutput += text
        pending += text
        // Keep possible password prefixes across pipe boundaries, including progress without a newline.
        let reserve = passwords.map(\.count).max() ?? 0
        let count = final ? pending.count : max(0, pending.count - reserve)
        guard count > 0 else { return }
        var split = pending.index(pending.startIndex, offsetBy: count)
        for password in passwords {
            var search = pending.startIndex
            while search < pending.endIndex, let range = pending.range(of: password, range: search..<pending.endIndex) {
                if range.lowerBound < split && range.upperBound > split { split = range.lowerBound }
                search = range.upperBound
            }
        }
        var emitted = String(pending[..<split]); pending.removeSubrange(..<split)
        for password in passwords { emitted = emitted.replacingOccurrences(of: password, with: "[REDACTED]") }
        output += emitted; if !emitted.isEmpty { callback(emitted) }
    }
    var rawResult: String { lock.lock(); defer { lock.unlock() }; return rawOutput }
    var result: String { lock.lock(); defer { lock.unlock() }; return output }
}
public struct SevenZipEngine: Sendable {
    public let binaryURL: URL
    public init(binaryURL: URL) { self.binaryURL = binaryURL }
    public static func locateBinary() throws -> URL {
        var candidates: [URL] = []
        if let url = Bundle.main.url(forResource: "7zz", withExtension: nil) { candidates.append(url) }
        if let path = ProcessInfo.processInfo.environment["SEVENZIP_BINARY"] { candidates.append(URL(fileURLWithPath: path)) }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("7zz"))
        guard let candidate = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { throw ArchiveError.invalid("The bundled 7zz engine is missing or not executable.") }
        return candidate
    }
    public func run(_ command: ArchiveCommand, control: OperationControl, onOutput: @escaping @Sendable (String) -> Void = { _ in }) async throws -> CommandResult {
        try await execute(command, control: control, onOutput: onOutput, preserveOutput: false)
    }
    func executeToFile(_ command: ArchiveCommand, to output: URL, control: OperationControl, onOutput: @escaping @Sendable (String) -> Void) async throws -> CommandResult {
        try await execute(command, control: control, onOutput: onOutput, preserveOutput: false, stdoutFile: output)
    }
    private func execute(_ command: ArchiveCommand, control: OperationControl, onOutput: @escaping @Sendable (String) -> Void, preserveOutput: Bool, stdoutFile: URL? = nil) async throws -> CommandResult {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process(), stdout = Pipe(), stderr = Pipe()
                    process.executableURL = binaryURL; process.arguments = command.arguments; process.currentDirectoryURL = command.workingDirectory
                    process.standardOutput = stdout; process.standardError = stderr
                    process.standardInput = FileHandle.nullDevice
                    let collector = OutputCollector(passwords: command.passwords, callback: onOutput)
                    do {
                        let directOutput = try stdoutFile.map { try FileHandle(forWritingTo: $0) }
                        defer { try? directOutput?.close() }
                        if let directOutput { process.standardOutput = directOutput }
                        try control.launch(process)
                        let readers = DispatchGroup()
                        for pipe in stdoutFile == nil ? [stdout, stderr] : [stderr] {
                            readers.enter()
                            DispatchQueue.global(qos: .userInitiated).async {
                                var decoder = UTF8StreamDecoder()
                                while let data = try? pipe.fileHandleForReading.read(upToCount: 16384), !data.isEmpty { collector.append(decoder.decode(data)) }
                                collector.append(decoder.decode(Data(), final: true))
                                try? pipe.fileHandleForReading.close(); readers.leave()
                            }
                        }
                        process.waitUntilExit(); readers.wait(); collector.append("", final: true)
                        control.detach(process); try control.checkpoint()
                        let result = CommandResult(output: collector.result, exitCode: process.terminationStatus)
                        if result.exitCode >= 2 || process.terminationReason == .uncaughtSignal { throw ArchiveError.failed(result.exitCode, result.output) }
                        continuation.resume(returning: preserveOutput ? CommandResult(output: collector.rawResult, exitCode: result.exitCode) : result)
                    } catch {
                        control.detach(process)
                        var message = error.localizedDescription
                        for password in command.passwords { message = message.replacingOccurrences(of: password, with: "[REDACTED]") }
                        if let archiveError = error as? ArchiveError { continuation.resume(throwing: archiveError) }
                        else { continuation.resume(throwing: ArchiveError.io(message)) }
                    }
                }
            }
        }, onCancel: { control.cancel() })
    }
    public func list(archive: URL, password: String? = nil, openMode: ArchiveOpenMode = .automatic, control: OperationControl = OperationControl()) async throws -> ArchiveListing {
        let args = ["l", "-slt", "-sccUTF-8", "-spd", "-bd"] + openMode.arguments + ((password?.isEmpty == false) ? ["-p" + password!] : []) + ["--", archive.standardizedFileURL.path]
        let result = try await execute(ArchiveCommand(arguments: args), control: control, onOutput: { _ in }, preserveOutput: true)
        guard result.succeeded else {
            let safeOutput = (password?.isEmpty == false) ? result.output.replacingOccurrences(of: password!, with: "[REDACTED]") : result.output
            throw ArchiveError.failed(result.exitCode, safeOutput)
        }
        return try SLTParser.parse(result.output)
    }
    public func memberComment(archive: URL, member: String, control: OperationControl = OperationControl()) async throws -> String {
        let listing = try await list(archive: archive, control: control)
        try control.checkpoint()
        return try ZipMemberComments.read(archive: archive, listing: listing, member: member)
    }
    /// Caller must hold the archive mutation reservation shared by all GUI workflows.
    public func setMemberComment(archive: URL, member: String, comment: String, control: OperationControl = OperationControl()) async throws {
        let listing = try await list(archive: archive, control: control)
        try await ZipMemberComments.rewrite(archive: archive, listing: listing, member: member, comment: comment, control: control) { temporary in
            let updated = try await self.list(archive: temporary, control: control)
            guard updated.entries.map(\.path) == listing.entries.map(\.path), try ZipMemberComments.read(archive: temporary, listing: updated, member: member) == comment else { throw ArchiveError.invalid("ZIP comment verification failed; original archive was preserved.") }
        }
    }
    private func sourceVolumes(_ archive: URL) throws -> [URL] {
        let siblings = try FileManager.default.contentsOfDirectory(at: archive.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        var sources = [archive]
        let ext = archive.pathExtension
        if ext.allSatisfy(\.isNumber), !ext.isEmpty {
            let prefix = archive.deletingPathExtension().lastPathComponent + "."
            sources += siblings.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension.allSatisfy(\.isNumber) }
        } else if ext.lowercased() == "rar" {
            let name = archive.lastPathComponent
            if let range = name.range(of: "\\.part[0-9]+\\.rar$", options: [.regularExpression, .caseInsensitive]) {
                let prefix = String(name[..<range.lowerBound])
                let pattern = "^" + NSRegularExpression.escapedPattern(for: prefix) + "\\.part[0-9]+\\.rar$"
                sources += siblings.filter { $0.lastPathComponent.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
            } else {
                let prefix = archive.deletingPathExtension().lastPathComponent + ".r"
                sources += siblings.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.lastPathComponent.dropFirst(prefix.count).allSatisfy(\.isNumber) }
            }
        } else if ext.lowercased() == "zip" {
            let prefix = archive.deletingPathExtension().lastPathComponent + ".z"
            sources += siblings.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.lastPathComponent.dropFirst(prefix.count).allSatisfy(\.isNumber) }
        }
        return sources
    }
    public func extract(archive: URL, options: ExtractionOptions, control: OperationControl, resolveConflict: ExtractionConflictResolver? = nil, onOutput: @escaping @Sendable (String) -> Void = { _ in }) async throws -> CommandResult {
        do {
            if options.overwrite == .ask && resolveConflict == nil { throw ArchiveError.invalid("Ask overwrite requires a conflict resolver.") }
            var listing = try await list(archive: archive, password: options.password, openMode: options.openMode, control: control)
            // Read link payloads without publishing them. 7z/ZIP expose mode but not always
            // the target in -slt, while the default extractor rejects even safe ../ links.
            if LinkArchiveExtractor.hasLinks(listing) {
                var entries: [ArchiveEntry] = []
                for entry in listing.entries {
                    if LinkArchiveExtractor.isSymbolic(entry), (entry.properties["Symbolic Link"] ?? "").isEmpty {
                        guard entry.size <= 65_535 else { throw ArchiveError.invalid("Archive symbolic link target is too long.") }
                        let args = ["x", "-so", "-bso0", "-bse2", "-bsp0", "-spd", "-i!" + entry.path] + options.openMode.arguments + (options.password.isEmpty ? [] : ["-p" + options.password]) + ["--", archive.path]
                        let payload = try await execute(ArchiveCommand(arguments: args), control: control, onOutput: { _ in }, preserveOutput: true)
                        guard payload.succeeded, payload.output.utf8.count <= 65_535 else { throw ArchiveError.invalid("Cannot read an archive symbolic link target safely.") }
                        var properties = entry.properties; properties["Symbolic Link"] = payload.output
                        entries.append(ArchiveEntry(path: entry.path, size: entry.size, packedSize: entry.packedSize, isDirectory: entry.isDirectory, modified: entry.modified, encrypted: entry.encrypted, properties: properties))
                    } else { entries.append(entry) }
                }
                listing = ArchiveListing(entries: entries, properties: listing.properties)
            }
            let protected = try sourceVolumes(archive)
            if options.remapAbsolutePaths { return try await extractRemapped(archive: archive, listing: listing, options: options, protected: protected, control: control, resolveConflict: resolveConflict, onOutput: onOutput) }
            let hasLinks = LinkArchiveExtractor.hasLinks(listing)
            var structuralOptions = options
            structuralOptions.destination = FileManager.default.temporaryDirectory.appendingPathComponent("sevenzip-preflight-" + UUID().uuidString)
            try ExtractionSafety.inspect(listing: listing, options: structuralOptions, protectedURLs: [], allowLinks: hasLinks)
            let layout = try ExtractionLayout(listing: listing, options: options)
            let mapped = layout.mappedListing(listing)
            try ExtractionSafety.inspect(listing: mapped, options: options, protectedURLs: protected, allowLinks: hasLinks)
            try control.checkpoint()
            var canonicalOptions = options
            canonicalOptions.destination = options.destination.standardizedFileURL.resolvingSymlinksInPath()
            if hasLinks || options.overwrite == .ask || options.eliminateDuplicateRoot {
                // Staging with -aoa must not discard repeated records, case aliases, or
                // flattened names before conflict decisions can inspect the original payloads.
                var names = Set<String>()
                for entry in listing.entries {
                    if !options.fullPaths && entry.isDirectory { continue }
                    let path = LinkArchiveExtractor.path(entry)
                    let canonical = path.precomposedStringWithCanonicalMapping.lowercased()
                    let selected = options.selectedPaths.isEmpty || options.selectedPaths.contains { selection in
                        let member = LinkArchiveExtractor.path(ArchiveEntry(path: selection)).precomposedStringWithCanonicalMapping.lowercased()
                        return canonical == member || canonical.hasPrefix(member + "/")
                    }
                    guard selected else { continue }
                    let mappedPath = layout.mappedPath(path)
                    if mappedPath.isEmpty && entry.isDirectory { continue }
                    let name = (options.fullPaths ? mappedPath : (mappedPath as NSString).lastPathComponent).precomposedStringWithCanonicalMapping.lowercased()
                    guard names.insert(name).inserted else {
                        throw ArchiveError.invalid(options.fullPaths ? "Archive contains duplicate or case-alias member paths; staged extraction cannot preserve every record." : "Flat extraction has duplicate file names. Enable full paths or select one conflicting member before using Ask overwrite.")
                    }
                }
                if hasLinks {
                    try LinkArchiveExtractor.validate(listing: listing, destination: structuralOptions.destination, protected: [], requireTargets: false)
                    if options.fullPaths { try LinkArchiveExtractor.validate(listing: mapped, destination: canonicalOptions.destination, protected: protected, requireTargets: false) }
                }
                let stage = FileManager.default.temporaryDirectory.appendingPathComponent("sevenzip-stage-" + UUID().uuidString).resolvingSymlinksInPath()
                try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: stage) }
                var stagedOptions = options; stagedOptions.destination = stage; if hasLinks { stagedOptions.fullPaths = true }; stagedOptions.overwrite = .overwrite; stagedOptions.eliminateDuplicateRoot = false
                var stagedCommand = try ArchiveCommands.extract(archive: archive, options: stagedOptions)
                if hasLinks {
                    var arguments = stagedCommand.arguments
                    arguments.insert(contentsOf: listing.entries.filter(LinkArchiveExtractor.isSymbolic).map { "-x!" + $0.path }, at: arguments.firstIndex(of: "--")!)
                    stagedCommand = ArchiveCommand(arguments: arguments)
                }
                if listing.properties["Type"] == "wim", hasLinks {
                    var arguments = stagedCommand.arguments
                    arguments.insert("-snh", at: arguments.firstIndex(of: "--")!)
                    stagedCommand = ArchiveCommand(arguments: arguments)
                }
                let result = try await run(stagedCommand, control: control, onOutput: onOutput)
                guard result.succeeded else { throw ArchiveError.failed(result.exitCode, result.output) }
                if hasLinks {
                    for entry in listing.entries where LinkArchiveExtractor.isSymbolic(entry) {
                        let name = LinkArchiveExtractor.path(entry)
                        let selected = options.selectedPaths.isEmpty || options.selectedPaths.contains { selection in
                            let member = LinkArchiveExtractor.path(ArchiveEntry(path: selection))
                            return name == member || name.hasPrefix(member + "/")
                        }
                        guard selected else { continue }
                        try control.checkpoint()
                        let target = stage.appendingPathComponent(name)
                        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: entry.properties["Symbolic Link"]!)
                    }
                }
                var stageDirectoryMetadata = try LinkArchiveExtractor.prepareStagingDirectories(stage)
                for entry in listing.entries where entry.isDirectory {
                    let name = LinkArchiveExtractor.path(entry)
                    if let captured = stageDirectoryMetadata[name] { stageDirectoryMetadata[name] = captured.overlay(ExtractionMetadata.from(entry)) }
                }
                var directoryMetadata: [String: ExtractionMetadata] = [:]
                for (name, metadata) in stageDirectoryMetadata { directoryMetadata[layout.mappedPath(name)] = metadata }
                var effectiveStage = layout.rootPrefix.map { stage.appendingPathComponent($0) } ?? stage
                var staged = FileManager.default.fileExists(atPath: effectiveStage.path) ? try LinkArchiveExtractor.stagedListing(effectiveStage) : ArchiveListing(entries: [])
                let stagedNames = Set(staged.entries.filter { !$0.isDirectory }.map { $0.path.precomposedStringWithCanonicalMapping.lowercased() })
                for entry in listing.entries where !entry.isDirectory {
                    let rawName = LinkArchiveExtractor.path(entry)
                    let selected = options.selectedPaths.isEmpty || options.selectedPaths.contains { selection in
                        let member = LinkArchiveExtractor.path(ArchiveEntry(path: selection))
                        return rawName == member || rawName.hasPrefix(member + "/")
                    }
                    guard selected else { continue }
                    let mappedName = layout.mappedPath(rawName)
                    let expected = (!options.fullPaths && !hasLinks ? (mappedName as NSString).lastPathComponent : mappedName).precomposedStringWithCanonicalMapping.lowercased()
                    guard stagedNames.contains(expected) else { throw ArchiveError.invalid("A selected archive member was not present after staged extraction; no destination files were published.") }
                }
                let flatStage = stage.appendingPathComponent(".flat-" + UUID().uuidString)
                if hasLinks && !options.fullPaths {
                    staged = try LinkArchiveExtractor.flatten(stage: effectiveStage, listing: staged, to: flatStage, control: control)
                    effectiveStage = flatStage
                }
                try ExtractionSafety.inspect(listing: staged, options: canonicalOptions, protectedURLs: protected, allowLinks: true)
                try LinkArchiveExtractor.validate(listing: staged, destination: canonicalOptions.destination, protected: protected, requireTargets: true)
                var fileMetadata: [String: ExtractionMetadata] = [:]
                for entry in listing.entries where !entry.isDirectory && !LinkArchiveExtractor.isSymbolic(entry) {
                    let name = layout.mappedPath(entry.path)
                    fileMetadata[options.fullPaths ? name : (name as NSString).lastPathComponent] = ExtractionMetadata.from(entry)
                }
                var originalPaths: [String: String] = [:]
                for entry in listing.entries { let path = layout.mappedPath(entry.path); originalPaths[options.fullPaths ? path : (path as NSString).lastPathComponent] = entry.path }
                try await LinkArchiveExtractor.commit(stage: effectiveStage, listing: staged, options: canonicalOptions, protected: protected, control: control, resolveConflict: resolveConflict, originalPaths: originalPaths, directoryMetadata: directoryMetadata, fileMetadata: fileMetadata)
                return result
            }
            return try await run(ArchiveCommands.extract(archive: archive, options: canonicalOptions), control: control, onOutput: onOutput)
        } catch {
            if !options.password.isEmpty, error.localizedDescription.contains(options.password) {
                throw ArchiveError.invalid(error.localizedDescription.replacingOccurrences(of: options.password, with: "[REDACTED]"))
            }
            throw error
        }
    }
}

public enum ExtractionSafety {
    public static func preflight(listing: ArchiveListing, options: ExtractionOptions, protectedURLs: [URL] = []) throws {
        try inspect(listing: listing, options: options, protectedURLs: protectedURLs, allowLinks: false)
    }
    static func inspect(listing: ArchiveListing, options: ExtractionOptions, protectedURLs: [URL], allowLinks: Bool) throws {
        let manager = FileManager.default
        let destination = options.destination.standardizedFileURL
        if try isLink(destination) { throw ArchiveError.invalid("Extraction destination is a symbolic link.") }
        let root = destination.resolvingSymlinksInPath()
        if manager.fileExists(atPath: root.path) {
            var directory: ObjCBool = false
            manager.fileExists(atPath: root.path, isDirectory: &directory)
            guard directory.boolValue else { throw ArchiveError.invalid("Extraction destination is not a directory.") }
        }
        let protectedPaths = Set(protectedURLs.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        let protectedIdentities = Set(protectedURLs.compactMap { identity($0) })
        for entry in listing.entries {
            let path = LinkArchiveExtractor.path(entry)
            // Validate original absolute markers before trimming directory terminators.
            guard !entry.path.hasPrefix("/"), !entry.path.hasPrefix("\\") else { throw ArchiveError.invalid("Unsafe archive path: \(entry.path)") }
            if path.isEmpty && entry.isDirectory { continue }
            try ArchiveCommands.validateMember(path)
            let props = entry.properties
            if props["Anti"] == "+" || isLinkValue(props["Link"]) || (!allowLinks && (LinkArchiveExtractor.isSymbolic(entry) || LinkArchiveExtractor.isHard(entry))) { throw ArchiveError.invalid("Link or anti-item extraction is blocked: \(entry.path)") }
            let relative = options.fullPaths ? path : (path as NSString).lastPathComponent
            let target = root.appendingPathComponent(relative).standardizedFileURL
            guard target.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") else { throw ArchiveError.invalid("Archive member escapes destination: \(entry.path)") }
            if protectedPaths.contains(target.path) || identity(target).map({ protectedIdentities.contains($0) }) == true { throw ArchiveError.invalid("Extraction would overwrite the source archive or a source volume: \(entry.path)") }
            var current = target
            while current.path != root.path {
                if try isLink(current), !(allowLinks && current.path == target.path && LinkArchiveExtractor.isSymbolic(entry)) { throw ArchiveError.invalid("Extraction would traverse a symbolic link: \(current.path)") }
                current.deleteLastPathComponent()
            }
        }
    }
    private static func isLinkValue(_ value: String?) -> Bool { guard let value else { return false }; return !value.isEmpty && value != "-" }
    private static func identity(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), let inode = attributes[.systemFileNumber] as? NSNumber, let device = attributes[.systemNumber] as? NSNumber else { return nil }
        return "\(device):\(inode)"
    }
    private static func isLink(_ url: URL) throws -> Bool {
        do { return try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeSymbolicLink }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return false }
    }
}
