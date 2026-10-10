import Foundation
import Darwin

/// Link archives use a private staging directory. No member may write through a link ancestor.
/// Targets are checked again from actual staged filesystem objects before destination writes.
enum LinkArchiveExtractor {
    static func isSymbolic(_ entry: ArchiveEntry) -> Bool {
        let value = entry.properties["Symbolic Link"] ?? ""
        return (!value.isEmpty && value != "-") || (entry.properties["Mode"] ?? "").hasPrefix("l") || (entry.properties["Attributes"] ?? "").split(whereSeparator: { $0.isWhitespace }).contains(where: { $0.hasPrefix("l") })
    }
    static func isHard(_ entry: ArchiveEntry) -> Bool { let value = entry.properties["Hard Link"] ?? ""; return !value.isEmpty && value != "-" }
    static func hasLinks(_ listing: ArchiveListing) -> Bool { listing.entries.contains { isSymbolic($0) || isHard($0) || (Int($0.properties["Links"] ?? "") ?? 0) > 1 && !($0.properties["iNode"] ?? "").isEmpty } }
    static func path(_ entry: ArchiveEntry) -> String { entry.path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").filter { $0 != "." }.joined(separator: "/") }
    private static func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
    static func validate(listing: ArchiveListing, destination: URL, protected: [URL], requireTargets: Bool) throws {
        var links: [String: String] = [:], symbolic = Set<String>(), all = Set<String>()
        let root = destination.standardizedFileURL.resolvingSymlinksInPath()
        for entry in listing.entries {
            let name = path(entry), canonical = key(name)
            if name.isEmpty && entry.isDirectory { continue }
            guard all.insert(canonical).inserted else { throw ArchiveError.invalid("Link archives cannot contain duplicate or case-alias member paths.") }
            if isSymbolic(entry) {
                symbolic.insert(canonical)
                if let target = entry.properties["Symbolic Link"], !target.isEmpty {
                    links[canonical] = try normalize(target: target, parent: (name as NSString).deletingLastPathComponent)
                } else if requireTargets { throw ArchiveError.invalid("Cannot determine symbolic link target: \(name)") }
            } else if isHard(entry) {
                links[canonical] = try normalize(target: entry.properties["Hard Link"]!, parent: "")
            }
        }
        for entry in listing.entries {
            let components = path(entry).split(separator: "/")
            guard components.count > 1 else { continue }
            for count in 1..<components.count {
                if symbolic.contains(key(components.prefix(count).joined(separator: "/"))) { throw ArchiveError.invalid("An archive member would write through a symbolic link ancestor: \(entry.path)") }
            }
        }
        for (name, target) in links {
            var resolved = target, visited = Set<String>([name])
            // Resolve symbolic links in any target ancestor, e.g. Versions/Current/Headers.
            while true {
                let components = resolved.split(separator: "/").map(String.init)
                var replacement: String?
                for count in 1...max(1, components.count) {
                    guard count <= components.count else { break }
                    let prefix = key(components.prefix(count).joined(separator: "/"))
                    if let next = links[prefix] {
                        guard visited.insert(prefix).inserted else { throw ArchiveError.invalid("Archive link cycle is blocked.") }
                        replacement = ([next] + components.dropFirst(count)).filter { !$0.isEmpty }.joined(separator: "/")
                        break
                    }
                }
                guard let replacement else { break }; resolved = replacement
            }
            let targetURL = root.appendingPathComponent(resolved).standardizedFileURL
            guard targetURL.path == root.path || targetURL.path.hasPrefix(root.path + "/") else { throw ArchiveError.invalid("Link target escapes extraction destination.") }
            for source in protected {
                let canonical = source.resolvingSymlinksInPath().standardizedFileURL
                if targetURL.path == canonical.path || canonical.path.hasPrefix(targetURL.path + "/") || sameIdentity(targetURL, canonical) { throw ArchiveError.invalid("A link would alias the source archive or a source volume.") }
            }
            var existing = targetURL
            while existing.path != root.path {
                if (try? FileManager.default.attributesOfItem(atPath: existing.path)[.type] as? FileAttributeType) == .typeSymbolicLink { throw ArchiveError.invalid("Link target traverses an existing destination symbolic link.") }
                existing.deleteLastPathComponent()
            }
        }
    }
    static func normalize(target: String, parent: String) throws -> String {
        guard !target.isEmpty, !target.hasPrefix("/"), !target.hasPrefix("\\"), !target.contains(":"), !target.contains("\\"), !target.contains("\0"), !target.contains("\n"), !target.contains("\r") else { throw ArchiveError.invalid("Absolute or ambiguous archive link targets are blocked.") }
        var components = parent.split(separator: "/").map(String.init)
        for part in target.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { guard !components.isEmpty else { throw ArchiveError.invalid("Archive link target escapes destination.") }; components.removeLast() }
            else { components.append(String(part)) }
        }
        return components.joined(separator: "/")
    }
    static func stagedListing(_ stage: URL) throws -> ArchiveListing {
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: stage, includingPropertiesForKeys: nil, options: [], errorHandler: { _, error in enumerationError = error; return false }) else { throw ArchiveError.io("Cannot inspect staged extraction.") }
        var entries: [ArchiveEntry] = []
        for case let url as URL in enumerator {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            guard let stageIndex = url.pathComponents.firstIndex(of: stage.lastPathComponent) else { throw ArchiveError.invalid("Staged member is outside the private extraction directory.") }
            let relative = url.pathComponents.dropFirst(stageIndex + 1).joined(separator: "/")
            if type == .typeSymbolicLink {
                enumerator.skipDescendants()
                entries.append(ArchiveEntry(path: relative, properties: ["Symbolic Link": try FileManager.default.destinationOfSymbolicLink(atPath: url.path)]))
            } else if type == .typeDirectory { entries.append(ArchiveEntry(path: relative, isDirectory: true)) }
            else if type == .typeRegular { entries.append(ArchiveEntry(path: relative, size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0)) }
            else { throw ArchiveError.invalid("Device and special-file extraction is blocked.") }
        }
        if let enumerationError { throw ArchiveError.io("Cannot enumerate staged extraction: " + enumerationError.localizedDescription) }
        return ArchiveListing(entries: entries)
    }
    /// Flat extraction first validates full paths, then builds a second private tree.
    /// Links to directories cannot be represented by a flat file layout.
    static func flatten(stage: URL, listing: ArchiveListing, to flat: URL, control: OperationControl) throws -> ArchiveListing {
        let manager = FileManager.default
        try validate(listing: listing, destination: stage, protected: [], requireTargets: true)
        var byKey: [String: ArchiveEntry] = [:], basenames = Set<String>()
        for entry in listing.entries { byKey[key(path(entry))] = entry }
        let files = listing.entries.filter { !$0.isDirectory }
        for entry in files {
            guard basenames.insert(key((path(entry) as NSString).lastPathComponent)).inserted else { throw ArchiveError.invalid("Flat extraction has duplicate or case-alias file names.") }
        }
        try manager.createDirectory(at: flat, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var hardLinks: [String: URL] = [:]
        for entry in files.filter({ !isSymbolic($0) }) {
            try control.checkpoint()
            let source = stage.appendingPathComponent(path(entry)), target = flat.appendingPathComponent((path(entry) as NSString).lastPathComponent)
            if let id = identity(source), let previous = hardLinks[id] { try manager.linkItem(at: previous, to: target) }
            else { try manager.copyItem(at: source, to: target); if let id = identity(source) { hardLinks[id] = target } }
        }
        for entry in files.filter({ isSymbolic($0) }) {
            try control.checkpoint()
            var target = try normalize(target: entry.properties["Symbolic Link"]!, parent: (path(entry) as NSString).deletingLastPathComponent)
            var seen = Set<String>()
            while let next = byKey[key(target)], isSymbolic(next) {
                guard seen.insert(key(target)).inserted else { throw ArchiveError.invalid("Archive link cycle is blocked.") }
                target = try normalize(target: next.properties["Symbolic Link"]!, parent: (path(next) as NSString).deletingLastPathComponent)
            }
            guard let destination = byKey[key(target)], !destination.isDirectory else { throw ArchiveError.invalid("Flat extraction requires each symbolic link target to be a selected regular file.") }
            try manager.createSymbolicLink(atPath: flat.appendingPathComponent((path(entry) as NSString).lastPathComponent).path, withDestinationPath: (path(destination) as NSString).lastPathComponent)
        }
        return try stagedListing(flat)
    }
    /// Make private directories traversable before enumeration, retaining their final metadata.
    static func prepareStagingDirectories(_ stage: URL) throws -> [String: ExtractionMetadata] {
        let manager = FileManager.default
        var metadata: [String: ExtractionMetadata] = [:], enumerationError: Error?
        guard let enumerator = manager.enumerator(at: stage, includingPropertiesForKeys: nil, options: [], errorHandler: { _, error in enumerationError = error; return false }) else { throw ArchiveError.io("Cannot enumerate staged extraction.") }
        for case let url as URL in enumerator {
            let attributes = try manager.attributesOfItem(atPath: url.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink { enumerator.skipDescendants() }
            else if attributes[.type] as? FileAttributeType == .typeDirectory {
                guard let stageIndex = url.pathComponents.firstIndex(of: stage.lastPathComponent) else { throw ArchiveError.invalid("Staged directory is outside the private extraction root.") }
                let name = url.pathComponents.dropFirst(stageIndex + 1).joined(separator: "/")
                let preserved = try ExtractionMetadata.capture(url); metadata[name] = preserved
                try manager.setAttributes([.posixPermissions: (preserved.permissions ?? 0) | 0o700], ofItemAtPath: url.path)
            }
        }
        if let enumerationError { throw ArchiveError.io("Cannot enumerate staged extraction: " + enumerationError.localizedDescription) }
        return metadata
    }
    private struct Publication {
        let entry: ArchiveEntry
        let destination: URL
        let mode: OverwriteMode
        let backup: URL?
    }
    static func commit(stage: URL, listing: ArchiveListing, options: ExtractionOptions, protected: [URL], control: OperationControl, resolveConflict: ExtractionConflictResolver?, originalPaths: [String: String], directoryMetadata: [String: ExtractionMetadata] = [:], fileMetadata: [String: ExtractionMetadata] = [:]) async throws {
        let manager = FileManager.default, root = options.destination.standardizedFileURL.resolvingSymlinksInPath()
        let directories = listing.entries.filter(\.isDirectory).sorted { $0.path.split(separator: "/").count < $1.path.split(separator: "/").count }
        for entry in directories {
            try control.checkpoint()
            try ExtractionSafety.inspect(listing: ArchiveListing(entries: [entry]), options: options, protectedURLs: protected, allowLinks: true)
            if let type = (try? manager.attributesOfItem(atPath: root.appendingPathComponent(entry.path).path))?[.type] as? FileAttributeType, type != .typeDirectory {
                throw ArchiveError.invalid("A file conflicts with an archive directory. Choose another extraction destination.")
            }
        }
        let files = listing.entries.filter { !$0.isDirectory && !isSymbolic($0) } + listing.entries.filter { isSymbolic($0) }
        var publications: [Publication] = [], reserved = Set(listing.entries.map { key(root.appendingPathComponent($0.path).path) }), allDecision: OverwriteMode?
        // Rename destinations must not fill a formerly dangling archive-link target with an unsafe old link.
        for entry in listing.entries where isSymbolic(entry) {
            let target = try normalize(target: entry.properties["Symbolic Link"]!, parent: (entry.path as NSString).deletingLastPathComponent)
            let components = target.split(separator: "/")
            if !components.isEmpty { for count in 1...components.count { reserved.insert(key(root.appendingPathComponent(components.prefix(count).joined(separator: "/")).path)) } }
        }
        // Gather every decision before any destination write, so Cancel preserves existing user files.
        for entry in files {
            try control.checkpoint()
            var destination = root.appendingPathComponent(entry.path)
            try ExtractionSafety.inspect(listing: ArchiveListing(entries: [entry]), options: options, protectedURLs: protected, allowLinks: true)
            let attributes = try? manager.attributesOfItem(atPath: destination.path) // lstat semantics, including dangling links
            var mode = options.overwrite, backup: URL?
            if attributes != nil {
                if mode == .ask {
                    if let allDecision { mode = allDecision }
                    else {
                        guard let resolveConflict else { throw ArchiveError.invalid("Ask overwrite requires a conflict resolver.") }
                        let answer = await resolveConflict(ExtractionConflict(archivePath: originalPaths[entry.path] ?? entry.path, destination: destination, isDirectory: entry.isDirectory))
                        try control.checkpoint()
                        if answer.action == .cancel { control.cancel(); throw ArchiveError.cancelled }
                        mode = OverwriteMode(rawValue: answer.action.rawValue)!
                        if answer.applyToAll { allDecision = mode }
                    }
                }
                if attributes?[.type] as? FileAttributeType == .typeSymbolicLink, isSymbolic(entry), mode == .skip || mode == .renameExtracted {
                    guard try manager.destinationOfSymbolicLink(atPath: destination.path) == entry.properties["Symbolic Link"] else {
                        throw ArchiveError.invalid("Preserving an existing symbolic link requires its target to match the validated archive link.")
                    }
                }
                switch mode {
                case .skip: continue
                case .renameExtracted: destination = try uniqueName(destination, reserved: reserved)
                case .renameExisting: backup = try uniqueName(destination, reserved: reserved); reserved.insert(key(backup!.path))
                case .overwrite:
                    if attributes?[.type] as? FileAttributeType == .typeDirectory { throw ArchiveError.invalid("A directory conflicts with an archive file. Choose Rename or Skip.") }
                case .ask: throw ArchiveError.invalid("Unresolved extraction conflict.")
                }
            }
            reserved.insert(key(destination.path))
            publications.append(Publication(entry: entry, destination: destination, mode: mode, backup: backup))
        }
        let plannedTargets = Dictionary(uniqueKeysWithValues: publications.map { (key($0.entry.path), $0.destination) })
        try control.checkpoint()
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        for entry in directories {
            try control.checkpoint()
            try ExtractionSafety.inspect(listing: ArchiveListing(entries: [entry]), options: options, protectedURLs: protected, allowLinks: true)
            try manager.createDirectory(at: root.appendingPathComponent(entry.path), withIntermediateDirectories: true)
        }
        var hardLinks: [String: URL] = [:]
        // Regular files and hard-link groups are published before all symbolic links.
        for publication in publications {
            try control.checkpoint()
            let entry = publication.entry, destination = publication.destination
            let source = stage.appendingPathComponent(entry.path)
            try ExtractionSafety.inspect(listing: ArchiveListing(entries: [entry]), options: options, protectedURLs: protected, allowLinks: true)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".sevenzip-extract-" + UUID().uuidString)
            do {
                if isSymbolic(entry) {
                    let originalTarget = try normalize(target: entry.properties["Symbolic Link"]!, parent: (entry.path as NSString).deletingLastPathComponent)
                    let target = plannedTargets[key(originalTarget)] ?? root.appendingPathComponent(originalTarget)
                    let parentComponents = destination.deletingLastPathComponent().pathComponents, targetComponents = target.pathComponents
                    var common = 0
                    while common < min(parentComponents.count, targetComponents.count), parentComponents[common] == targetComponents[common] { common += 1 }
                    let relative = (Array(repeating: "..", count: parentComponents.count - common) + targetComponents.dropFirst(common)).joined(separator: "/")
                    try manager.createSymbolicLink(atPath: temporary.path, withDestinationPath: relative.isEmpty ? "." : relative)
                }
                else if let identity = identity(source), let previous = hardLinks[identity] { try manager.linkItem(at: previous, to: temporary) }
                else { try manager.copyItem(at: source, to: temporary) }
                if !isSymbolic(entry) {
                    let captured = try ExtractionMetadata.capture(source)
                    try (fileMetadata[entry.path].map { captured.overlay($0) } ?? captured).apply(to: temporary)
                }
                try control.checkpoint()
                if let backup = publication.backup {
                    guard Darwin.renamex_np(destination.path, backup.path, UInt32(RENAME_EXCL)) == 0 else { throw ArchiveError.io("Cannot safely rename the existing extracted file.") }
                }
                if publication.mode == .overwrite {
                    guard Darwin.rename(temporary.path, destination.path) == 0 else { throw ArchiveError.io("Cannot publish extracted file: \(String(cString: strerror(errno)))") }
                } else {
                    guard Darwin.renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                        if errno == EEXIST && publication.mode == .skip { try? manager.removeItem(at: temporary); continue }
                        throw ArchiveError.io("Cannot publish extracted file without replacing an existing item: \(String(cString: strerror(errno)))")
                    }
                }
                if !isSymbolic(entry), let identity = identity(source) { hardLinks[identity] = destination }
            } catch {
                try? manager.removeItem(at: temporary)
                if let backup = publication.backup { _ = Darwin.renamex_np(backup.path, destination.path, UInt32(RENAME_EXCL)) }
                throw error
            }
        }
        for entry in directories.reversed() {
            try control.checkpoint()
            let metadata = try directoryMetadata[entry.path] ?? ExtractionMetadata.capture(stage.appendingPathComponent(entry.path))
            try metadata.apply(to: root.appendingPathComponent(entry.path))
        }
    }
    private static func uniqueName(_ destination: URL, reserved: Set<String> = []) throws -> URL {
        let manager = FileManager.default, parent = destination.deletingLastPathComponent(), ext = destination.pathExtension
        let stem = destination.deletingPathExtension().lastPathComponent
        for index in 1...100_000 {
            let candidate = parent.appendingPathComponent(stem + "_\(index)" + (ext.isEmpty ? "" : "." + ext))
            if !reserved.contains(key(candidate.path)), (try? manager.attributesOfItem(atPath: candidate.path)) == nil { return candidate }
        }
        throw ArchiveError.io("Cannot choose a free extracted filename.")
    }
    private static func identity(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), let inode = attributes[.systemFileNumber] as? NSNumber, let device = attributes[.systemNumber] as? NSNumber else { return nil }
        return "\(device):\(inode)"
    }
    private static func sameIdentity(_ first: URL, _ second: URL) -> Bool { guard let value = identity(first) else { return false }; return value == identity(second) }
}
