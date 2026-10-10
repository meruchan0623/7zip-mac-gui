import Foundation

extension SevenZipEngine {
    /// Binary stdout is streamed straight into private files: original absolute names
    /// remain only literal archive selectors and never become filesystem destinations.
    func extractRemapped(archive: URL, listing: ArchiveListing, options: ExtractionOptions, protected: [URL], control: OperationControl, resolveConflict: ExtractionConflictResolver?, onOutput: @escaping @Sendable (String) -> Void) async throws -> CommandResult {
        let manager = FileManager.default
        for entry in listing.entries { _ = try ArchiveCommands.remappedArchivePath(entry.path) }
        for selected in options.selectedPaths { _ = try ArchiveCommands.remappedArchivePath(selected) }
        let layout = try ExtractionLayout(listing: listing, options: options)
        let selected = listing.entries.filter { entry in
            let name = entry.path.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return options.selectedPaths.isEmpty || options.selectedPaths.contains { path in
                let choice = path.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return name == choice || name.hasPrefix(choice + "/")
            }
        }
        var mappedEntries: [ArchiveEntry] = [], originals: [String: String] = [:], names = Set<String>()
        for entry in selected {
            let name = layout.mappedPath(entry.path)
            if name.isEmpty && entry.isDirectory { continue }
            guard names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw ArchiveError.invalid("Absolute path mapping has duplicate or case-alias member names.") }
            var properties = entry.properties
            if let target = properties["Hard Link"], !target.isEmpty, target != "-" { properties["Hard Link"] = layout.mappedPath(target) }
            if let target = properties["Symbolic Link"], !target.isEmpty {
                if target.hasPrefix("/") || target.hasPrefix("\\") || target.range(of: "^[A-Za-z]:[/\\\\]", options: .regularExpression) != nil {
                    let mappedTarget = layout.mappedPath(target)
                    _ = try ArchiveCommands.remappedArchivePath(target)
                    properties["Symbolic Link"] = Self.relativePath(from: (name as NSString).deletingLastPathComponent, to: mappedTarget)
                }
            }
            mappedEntries.append(ArchiveEntry(path: name, size: entry.size, packedSize: entry.packedSize, isDirectory: entry.isDirectory, modified: entry.modified, encrypted: entry.encrypted, properties: properties))
            originals[name] = entry.path
        }
        let mapped = ArchiveListing(entries: mappedEntries, properties: listing.properties)
        var safeOptions = options; safeOptions.fullPaths = true; safeOptions.selectedPaths = []; safeOptions.eliminateDuplicateRoot = false; safeOptions.remapAbsolutePaths = false
        let stage = manager.temporaryDirectory.appendingPathComponent("7zip-absolute-stage-" + UUID().uuidString).resolvingSymlinksInPath()
        var structural = safeOptions; structural.destination = stage
        try ExtractionSafety.inspect(listing: mapped, options: structural, protectedURLs: [], allowLinks: true)
        try LinkArchiveExtractor.validate(listing: mapped, destination: stage, protected: [], requireTargets: true)
        let preview = options.fullPaths ? mapped : ArchiveListing(entries: mapped.entries.filter { !$0.isDirectory }.map { entry in
            ArchiveEntry(path: (entry.path as NSString).lastPathComponent, size: entry.size, properties: entry.properties)
        })
        try ExtractionSafety.inspect(listing: preview, options: safeOptions, protectedURLs: protected, allowLinks: true)
        try control.checkpoint()
        try manager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: stage) }
        for entry in mapped.entries where entry.isDirectory { try manager.createDirectory(at: stage.appendingPathComponent(entry.path), withIntermediateDirectories: true) }
        var inodeGroups: [String: URL] = [:], output = ""
        for entry in mapped.entries where !entry.isDirectory && !LinkArchiveExtractor.isSymbolic(entry) && !LinkArchiveExtractor.isHard(entry) {
            try control.checkpoint()
            let destination = stage.appendingPathComponent(entry.path)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let group = (Int(entry.properties["Links"] ?? "") ?? 0) > 1 ? entry.properties["iNode"] : nil
            if let group, let existing = inodeGroups[group] { try manager.linkItem(at: existing, to: destination) }
            else {
                guard manager.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ArchiveError.io("Cannot create a private extraction file.") }
                let args = ["x", "-so", "-bso0", "-bse2", "-bsp0", "-spd", "-i!" + originals[entry.path]!] + options.openMode.arguments + (options.password.isEmpty ? [] : ["-p" + options.password]) + ["--", archive.path]
                let result = try await executeToFile(ArchiveCommand(arguments: args), to: destination, control: control, onOutput: onOutput)
                guard result.succeeded else { throw ArchiveError.failed(result.exitCode, result.output) }
                output += result.output
                guard (try manager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.uint64Value == entry.size else { throw ArchiveError.invalid("The remapped extracted member size does not match its listing.") }
                if let group { inodeGroups[group] = destination }
            }
            try ExtractionMetadata.from(entry).apply(to: destination)
        }
        var pending = mapped.entries.filter(LinkArchiveExtractor.isHard)
        while !pending.isEmpty {
            var remaining: [ArchiveEntry] = [], madeProgress = false
            for entry in pending {
                let target = stage.appendingPathComponent(entry.properties["Hard Link"]!), destination = stage.appendingPathComponent(entry.path)
                if (try? manager.attributesOfItem(atPath: target.path)[.type] as? FileAttributeType) == .typeRegular {
                    try control.checkpoint(); try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try manager.linkItem(at: target, to: destination); madeProgress = true
                } else { remaining.append(entry) }
            }
            guard madeProgress else { throw ArchiveError.invalid("Absolute path mapping requires each hard link target to be a selected regular file.") }
            pending = remaining
        }
        for entry in mapped.entries where LinkArchiveExtractor.isSymbolic(entry) {
            try control.checkpoint()
            let destination = stage.appendingPathComponent(entry.path)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.createSymbolicLink(atPath: destination.path, withDestinationPath: entry.properties["Symbolic Link"]!)
        }
        let directoryMetadata = Dictionary(uniqueKeysWithValues: mapped.entries.filter(\.isDirectory).map { ($0.path, ExtractionMetadata.from($0)) })
        var fileMetadata = Dictionary(uniqueKeysWithValues: mapped.entries.filter { !$0.isDirectory && !LinkArchiveExtractor.isSymbolic($0) }.map { ($0.path, ExtractionMetadata.from($0)) })
        var effectiveStage = stage, staged = mapped
        if !options.fullPaths {
            let flat = stage.appendingPathComponent(".flat-" + UUID().uuidString)
            staged = try LinkArchiveExtractor.flatten(stage: stage, listing: staged, to: flat, control: control)
            effectiveStage = flat
            fileMetadata = Dictionary(uniqueKeysWithValues: fileMetadata.map { (($0.key as NSString).lastPathComponent, $0.value) })
            originals = Dictionary(uniqueKeysWithValues: mapped.entries.filter { !$0.isDirectory }.map { (($0.path as NSString).lastPathComponent, originals[$0.path]!) })
        }
        try LinkArchiveExtractor.validate(listing: staged, destination: options.destination, protected: protected, requireTargets: true)
        try ExtractionSafety.inspect(listing: staged, options: safeOptions, protectedURLs: protected, allowLinks: true)
        try await LinkArchiveExtractor.commit(stage: effectiveStage, listing: staged, options: safeOptions, protected: protected, control: control, resolveConflict: resolveConflict, originalPaths: originals, directoryMetadata: directoryMetadata, fileMetadata: fileMetadata)
        return CommandResult(output: output, exitCode: 0)
    }
    private static func relativePath(from parent: String, to target: String) -> String {
        let first = parent.split(separator: "/").map(String.init), second = target.split(separator: "/").map(String.init)
        var shared = 0
        while shared < min(first.count, second.count), first[shared] == second[shared] { shared += 1 }
        let path = (Array(repeating: "..", count: first.count - shared) + second.dropFirst(shared)).joined(separator: "/")
        return path.isEmpty ? "." : path
    }
}
