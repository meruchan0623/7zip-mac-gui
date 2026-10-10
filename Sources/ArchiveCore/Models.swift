import Foundation

public struct ArchiveEntry: Identifiable, Hashable, Sendable {
    public let path: String
    public let size: UInt64
    public let packedSize: UInt64
    public let isDirectory: Bool
    public let modified: String
    public let encrypted: Bool
    public let properties: [String: String]
    public var id: String { path }
    public init(path: String, size: UInt64 = 0, packedSize: UInt64 = 0, isDirectory: Bool = false, modified: String = "", encrypted: Bool = false, properties: [String: String] = [:]) {
        self.path = path; self.size = size; self.packedSize = packedSize; self.isDirectory = isDirectory; self.modified = modified; self.encrypted = encrypted; self.properties = properties
    }
}
public struct ArchiveListing: Sendable {
    public let entries: [ArchiveEntry]
    public let properties: [String: String]
    public init(entries: [ArchiveEntry], properties: [String: String] = [:]) { self.entries = entries; self.properties = properties }
}
public struct CommandResult: Sendable {
    public let output: String
    public let exitCode: Int32
    public var succeeded: Bool { exitCode == 0 }
    public var warning: Bool { exitCode == 1 }
    public init(output: String, exitCode: Int32) { self.output = output; self.exitCode = exitCode }
}
public struct ArchiveCommand: Sendable {
    public let arguments: [String]
    public let workingDirectory: URL?
    public var redactedDescription: String {
        var description = arguments.map { $0.hasPrefix("-p") ? "-p[REDACTED]" : $0 }.joined(separator: " ")
        for secret in passwords { description = description.replacingOccurrences(of: secret, with: "[REDACTED]") }
        return description
    }
    public init(arguments: [String], workingDirectory: URL? = nil) { self.arguments = arguments; self.workingDirectory = workingDirectory }
    var passwords: [String] { arguments.filter { $0.hasPrefix("-p") && $0.count > 2 }.map { String($0.dropFirst(2)) } }
}
public enum ArchiveError: LocalizedError, Sendable {
    case invalid(String), failed(Int32, String), cancelled, io(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let text), .io(let text): return text
        case .failed(let code, let text): return "7-Zip exited with code \(code).\n\(text)"
        case .cancelled: return "Operation cancelled."
        }
    }
}
public enum UpdateMode: String, CaseIterable, Sendable { case add, update, freshen, synchronize }
public enum OverwriteMode: String, CaseIterable, Sendable { case skip, overwrite, renameExtracted, renameExisting, ask }
/// Matches official Windows Open Inside * and # / CLI -t modes.
public enum ArchiveOpenMode: String, CaseIterable, Sendable {
    case automatic, topLevel, parser
    public var arguments: [String] { switch self { case .automatic: return []; case .topLevel: return ["-t*"]; case .parser: return ["-t#"] } }
}
public enum CompressionPathMode: String, CaseIterable, Sendable { case relative, full, absolute }
public enum TimestampStorage: String, CaseIterable, Sendable { case automatic, store, omit }
public enum ArchiveTimePrecision: Int, CaseIterable, Sendable {
    case automatic = -1, windows100ns = 0, unixSeconds = 1, dosTwoSeconds = 2, nanoseconds = 3
    case seconds = 16, milliseconds = 19, microseconds = 22, hundredNanoseconds = 23, exactNanoseconds = 25
}
public struct CompressionOptions: Sendable {
    public var format = "7z", level = 5, method = "", dictionary = "", wordSize = "", solid = "on", threads = 0, volumeSize = "", password = "", encryptHeaders = false, encryptionMethod = "AES256", updateMode: UpdateMode = .add, exclusions: [String] = [], parameters = "", compressShared = false
    public var pathMode: CompressionPathMode = .relative
    public var setArchiveTimeToLatest = false
    /// Official 7-Zip soft memory budget: p{percent} or positive size with b/k/m/g/t.
    public var memoryLimit = ""
    public var timePrecision: ArchiveTimePrecision = .automatic
    public var modificationTime: TimestampStorage = .automatic, creationTime: TimestampStorage = .automatic, accessTime: TimestampStorage = .automatic
    public var storeSymbolicLinks = false, storeHardLinks = false, preserveAccessTime = false
    /// Uses the engine's -sdel behavior: delete successfully archived source files after compression.
    public var deleteSourcesAfterCompression = false
    public init() {}
}
public struct ExtractionOptions: Sendable {
    public var destination: URL
    public var openMode: ArchiveOpenMode = .automatic
    /// Explicitly map absolute archive names into the chosen destination. Never writes to original roots.
    public var remapAbsolutePaths = false
    public var eliminateDuplicateRoot = false
    public var fullPaths = true, overwrite: OverwriteMode = .skip, password = "", selectedPaths: [String] = []
    public init(destination: URL) { self.destination = destination }
}

public struct ExtractionConflict: Sendable {
    public let archivePath: String
    public let destination: URL
    public let isDirectory: Bool
    public init(archivePath: String, destination: URL, isDirectory: Bool) { self.archivePath = archivePath; self.destination = destination; self.isDirectory = isDirectory }
}
public enum ExtractionConflictAction: String, CaseIterable, Sendable { case skip, overwrite, renameExtracted, renameExisting, cancel }
public struct ExtractionConflictResolution: Sendable {
    public let action: ExtractionConflictAction
    public let applyToAll: Bool
    public init(action: ExtractionConflictAction, applyToAll: Bool = false) { self.action = action; self.applyToAll = applyToAll }
}
public typealias ExtractionConflictResolver = @Sendable (ExtractionConflict) async -> ExtractionConflictResolution

/// Parses technical listings by the explicit entry separator, never by the archive's own Path field.
public enum SLTParser {
    public static func parse(_ output: String) throws -> ArchiveListing {
        let lines = output.components(separatedBy: .newlines)
        guard let divider = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "----------" }) else { throw ArchiveError.invalid("7-Zip returned an incomplete technical listing.") }
        var archive: [String: String] = [:]
        for line in lines[..<divider] { if let (key, value) = pair(line) { archive[key] = value } }
        var records: [[String: String]] = [], record: [String: String] = [:]
        for (offset, line) in lines[(divider + 1)...].enumerated() {
            if record.isEmpty, !records.isEmpty, line.range(of: "^Warnings: [0-9]+$", options: .regularExpression) != nil,
               lines[(divider + 1 + offset)...].allSatisfy({ $0.isEmpty || $0.range(of: "^Warnings: [0-9]+$", options: .regularExpression) != nil }) { break }
            if line.isEmpty { if !record.isEmpty { records.append(record); record = [:] } }
            else if let (key, value) = pair(line) {
                guard record[key] == nil else { throw ArchiveError.invalid("Ambiguous technical listing (duplicate field).") }
                record[key] = value
            } else {
                throw ArchiveError.invalid("Ambiguous technical listing (unescaped filename or unexpected data).")
            }
        }
        if !record.isEmpty { records.append(record) }
        let entries = records.compactMap { values -> ArchiveEntry? in
            let path: String
            if let named = values["Path"] { path = named }
            else if let archivePath = archive["Path"] {
                // Raw stream formats do not store a filename. Match upstream DefaultName.cpp.
                let filename = (archivePath as NSString).lastPathComponent
                let ext = (filename as NSString).pathExtension.lowercased()
                let tarSuffix = ["tgz", "taz", "tbz", "tbz2", "txz"].contains(ext) ? ".tar" : ""
                let dot = filename.lastIndex(of: ".")
                let stem = dot.flatMap { $0 > filename.startIndex ? String(filename[..<$0]) : nil }
                path = ((stem ?? (filename + (tarSuffix.isEmpty ? "~" : ""))) + tarSuffix).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            } else { return nil }
            let attrs = values["Attributes"] ?? ""
            return ArchiveEntry(path: path, size: UInt64(values["Size"] ?? "") ?? 0, packedSize: UInt64(values["Packed Size"] ?? "") ?? 0, isDirectory: values["Folder"] == "+" || attrs.hasPrefix("D") || attrs.contains(" drwx"), modified: values["Modified"] ?? "", encrypted: values["Encrypted"] == "+", properties: values)
        }
        return ArchiveListing(entries: entries, properties: archive)
    }
    private static func pair(_ line: String) -> (String, String)? {
        guard let range = line.range(of: " = ") else { return nil }
        return (String(line[..<range.lowerBound]), String(line[range.upperBound...]))
    }
}
