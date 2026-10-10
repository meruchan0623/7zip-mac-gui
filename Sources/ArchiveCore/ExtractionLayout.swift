import Foundation

/// One mapping is used for safety checks and staged publication. Selections always use original member paths.
public struct ExtractionLayout: Sendable {
    public let rootPrefix: String?
    private let remapAbsolutePaths: Bool
    public init(listing: ArchiveListing, options: ExtractionOptions) throws {
        remapAbsolutePaths = options.remapAbsolutePaths
        guard options.eliminateDuplicateRoot, options.fullPaths, !listing.entries.isEmpty else { rootPrefix = nil; return }
        let requested = options.destination.standardizedFileURL.lastPathComponent
        guard !requested.isEmpty, requested != "/" else { rootPrefix = nil; return }
        var actual: String?
        for entry in listing.entries {
            // Upstream checks raw names before wildcard filtering; './root' disables elimination.
            let parts = (options.remapAbsolutePaths ? try ArchiveCommands.remappedArchivePath(entry.path) : entry.path).replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: false)
            guard let first = parts.first, String(first).caseInsensitiveCompare(requested) == .orderedSame,
                  parts.count > 1 || entry.isDirectory else { rootPrefix = nil; return }
            if let actual, actual != String(first) { throw ArchiveError.invalid("Ambiguous case variants of a duplicate archive root are blocked.") }
            actual = String(first)
        }
        rootPrefix = actual
    }
    public func mappedPath(_ original: String) -> String {
        let normalized = remapAbsolutePaths ? ((try? ArchiveCommands.remappedArchivePath(original)) ?? "") : LinkArchiveExtractor.path(ArchiveEntry(path: original))
        guard let rootPrefix else { return normalized }
        let components = normalized.split(separator: "/")
        guard components.first.map(String.init)?.caseInsensitiveCompare(rootPrefix) == .orderedSame else { return normalized }
        return components.dropFirst().joined(separator: "/")
    }
    public func mappedListing(_ listing: ArchiveListing) -> ArchiveListing {
        let entries = listing.entries.compactMap { entry -> ArchiveEntry? in
            let name = mappedPath(entry.path)
            if name.isEmpty && entry.isDirectory { return nil }
            var properties = entry.properties
            if let hard = properties["Hard Link"], !hard.isEmpty, hard != "-" { properties["Hard Link"] = mappedPath(hard) }
            return ArchiveEntry(path: name, size: entry.size, packedSize: entry.packedSize, isDirectory: entry.isDirectory, modified: entry.modified, encrypted: entry.encrypted, properties: properties)
        }
        return ArchiveListing(entries: entries, properties: listing.properties)
    }
}
