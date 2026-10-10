import Foundation
import CoreFoundation
import Darwin

/// Windows CAgentFolder::SetProperty only implements kpidComment for ZIP.
/// A ZIP member comment lives solely in the central directory, so compressed and
/// encrypted data can remain byte-for-byte unchanged. Unicode comment extra 0x6375
/// matches the official ZipItem.cpp reader without changing filename encoding flags.
public enum ZipMemberComments {
    public static func supports(archiveType: String) -> Bool { archiveType.lowercased() == "zip" }

    /// Read raw central comments rather than CLI text, which replaces line breaks with underscores.
    static func read(archive: URL, listing: ArchiveListing, member: String) throws -> String {
        guard supports(archiveType: listing.properties["Type"] ?? ""), listing.entries.filter({ $0.path == member }).count == 1 else { throw ArchiveError.invalid("Choose one ZIP member.") }
        let source = try Data(contentsOf: archive, options: .alwaysMapped)
        guard source.count >= 22 else { throw ArchiveError.invalid("Invalid ZIP end record.") }
        var end: Int?
        for i in stride(from: source.count - 22, through: max(0, source.count - 22 - 65_535), by: -1) {
            if u32(source, i) == 0x06054b50, i + 22 + Int(u16(source, i + 20)) == source.count { end = i; break }
        }
        guard let end else { throw ArchiveError.invalid("Invalid ZIP end record.") }
        var centralEnd = end, size = UInt64(u32(source, end + 12))
        if end >= 20, u32(source, end - 20) == 0x07064b50 {
            var record: Int?
            for i in stride(from: end - 76, through: max(0, end - 20 - 1_048_576), by: -1) {
                if i >= 0, u32(source, i) == 0x06064b50 {
                    let length = u64(source, i + 4)
                    if length >= 44, length <= 1_048_576, i + 12 + Int(length) == end - 20 { record = i; break }
                }
            }
            guard let record else { throw ArchiveError.invalid("Invalid ZIP64 end record.") }
            centralEnd = record; size = u64(source, record + 40)
        }
        guard size <= centralEnd else { throw ArchiveError.invalid("Invalid ZIP directory size.") }
        var cursor = centralEnd - Int(size)
        let chosen = listing.entries.firstIndex { $0.path == member }!
        for index in listing.entries.indices {
            guard cursor + 46 <= centralEnd, u32(source, cursor) == 0x02014b50 else { throw ArchiveError.invalid("Invalid ZIP central entry.") }
            let nameLength = Int(u16(source, cursor + 28)), extraLength = Int(u16(source, cursor + 30)), commentLength = Int(u16(source, cursor + 32))
            let commentStart = cursor + 46 + nameLength + extraLength, next = commentStart + commentLength
            guard next <= centralEnd else { throw ArchiveError.invalid("Invalid ZIP central entry size.") }
            if index == chosen {
                let comment = source.subdata(in: commentStart..<next)
                if u16(source, cursor + 8) & 0x800 == 0 {
                    var extraCursor = cursor + 46 + nameLength
                    while extraCursor + 4 <= commentStart {
                        let length = Int(u16(source, extraCursor + 2)), extraEnd = extraCursor + 4 + length
                        guard extraEnd <= commentStart else { throw ArchiveError.invalid("Malformed ZIP extra field.") }
                        if u16(source, extraCursor) == 0x6375, length >= 5, source[extraCursor + 4] == 1, u32(source, extraCursor + 5) == crc32(comment), let unicode = String(data: source.subdata(in: extraCursor + 9..<extraEnd), encoding: .utf8) { return unicode }
                        extraCursor = extraEnd
                    }
                }
                return String(data: comment, encoding: .utf8) ?? String(data: comment, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(0x400))) ?? ""
            }
            cursor = next
        }
        throw ArchiveError.invalid("ZIP member comment was not found.")
    }
    static func rewrite(archive: URL, listing: ArchiveListing, member: String, comment: String, control: OperationControl, validate: (URL) async throws -> Void) async throws {
        guard supports(archiveType: listing.properties["Type"] ?? "") else { throw ArchiveError.invalid("Member comments are supported only by ZIP, as in Windows 7-Zip.") }
        let matches = listing.entries.indices.filter { listing.entries[$0].path == member }
        guard matches.count == 1 else { throw ArchiveError.invalid("Choose one unambiguous ZIP member to comment.") }
        guard !comment.contains("\0"), Data(comment.utf8).count <= 65_530 else { throw ArchiveError.invalid("The ZIP comment is too long or contains a null character.") }
        let manager = FileManager.default
        let originalAttributes = try manager.attributesOfItem(atPath: archive.path)
        guard originalAttributes[.type] as? FileAttributeType == .typeRegular else { throw ArchiveError.invalid("ZIP comment updates require a regular archive file.") }
        // A mapped snapshot keeps large compressed payloads out of the Swift heap.
        let source = try Data(contentsOf: archive, options: .alwaysMapped)
        guard source.count >= 22 else { throw ArchiveError.invalid("Invalid ZIP end record.") }
        var end: Int?
        for index in stride(from: source.count - 22, through: max(0, source.count - 22 - 65_535), by: -1) {
            if u32(source, index) == 0x06054b50, index + 22 + Int(u16(source, index + 20)) == source.count { end = index; break }
        }
        guard let end else { throw ArchiveError.invalid("ZIP comment updates require a complete single-volume archive.") }
        guard u16(source, end + 4) == 0, u16(source, end + 6) == 0, u16(source, end + 8) == u16(source, end + 10) else { throw ArchiveError.invalid("Multi-volume ZIP comment updates are not supported.") }
        var count = UInt64(u16(source, end + 10)), centralSize = UInt64(u32(source, end + 12)), centralOffset = UInt64(u32(source, end + 16)), centralEnd = end, zip64: Int?
        if count == 65_535 || centralSize == UInt32.max || centralOffset == UInt32.max || (end >= 20 && u32(source, end - 20) == 0x07064b50) {
            guard end >= 76, u32(source, end - 20) == 0x07064b50, u32(source, end - 16) == 0, u32(source, end - 4) == 1 else { throw ArchiveError.invalid("Invalid or multi-volume ZIP64 locator.") }
            // ZIP64 record may contain an extensible data sector. Accept bounded records.
            for index in stride(from: end - 76, through: max(0, end - 20 - 1_048_576), by: -1) {
                if u32(source, index) == 0x06064b50, index + 12 <= end - 20 {
                    let length = u64(source, index + 4)
                    if length >= 44, length <= 1_048_576, index + 12 + Int(length) == end - 20 { zip64 = index; break }
                }
            }
            guard let offset = zip64, u32(source, offset + 16) == 0, u32(source, offset + 20) == 0, u64(source, offset + 24) == u64(source, offset + 32) else { throw ArchiveError.invalid("Invalid ZIP64 end record.") }
            count = u64(source, offset + 32); centralSize = u64(source, offset + 40); centralOffset = u64(source, offset + 48); centralEnd = offset
        }
        guard count == listing.entries.count, centralSize <= 268_435_456, centralSize <= centralEnd else { throw ArchiveError.invalid("ZIP directory does not match the engine listing or exceeds the safe update limit.") }
        let centralStart = centralEnd - Int(centralSize)
        guard centralOffset <= centralStart else { throw ArchiveError.invalid("Invalid ZIP central directory offset.") }
        let prefix = centralStart - Int(centralOffset) // Handles self-extracting prefixes.
        if let zip64 { guard u64(source, end - 12) == zip64 - prefix else { throw ArchiveError.invalid("Inconsistent ZIP64 self-extracting offsets.") } }
        var directory = Data(), cursor = centralStart
        for index in 0..<Int(count) {
            try control.checkpoint()
            guard cursor + 46 <= centralEnd, u32(source, cursor) == 0x02014b50 else { throw ArchiveError.invalid("Invalid ZIP central entry.") }
            let nameLength = Int(u16(source, cursor + 28)), extraLength = Int(u16(source, cursor + 30)), oldCommentLength = Int(u16(source, cursor + 32))
            let next = cursor + 46 + nameLength + extraLength + oldCommentLength
            guard next <= centralEnd, u16(source, cursor + 34) == 0 else { throw ArchiveError.invalid("Invalid or split ZIP member.") }
            if index == matches[0] {
                let name = source.subdata(in: cursor + 46..<cursor + 46 + nameLength)
                var extra = Data(), extraCursor = cursor + 46 + nameLength
                let extraEnd = extraCursor + extraLength
                while extraCursor < extraEnd {
                    guard extraCursor + 4 <= extraEnd else { throw ArchiveError.invalid("Malformed ZIP extra field.") }
                    let length = Int(u16(source, extraCursor + 2)), nextExtra = extraCursor + 4 + length
                    guard nextExtra <= extraEnd else { throw ArchiveError.invalid("Malformed ZIP extra field.") }
                    if u16(source, extraCursor) != 0x6375 { extra.append(source.subdata(in: extraCursor..<nextExtra)) }
                    extraCursor = nextExtra
                }
                let utf8 = Data(comment.utf8), isUTF8 = u16(source, cursor + 8) & 0x800 != 0
                let stored = isUTF8 ? utf8 : Data(comment.map { $0.isASCII ? String($0) : "_" }.joined().utf8)
                if !isUTF8 && !comment.isEmpty {
                    var unicode = Data([1]); append32(&unicode, crc32(stored)); unicode.append(utf8)
                    append16(&extra, 0x6375); append16(&extra, UInt16(unicode.count)); extra.append(unicode)
                }
                guard extra.count <= 65_535, stored.count <= 65_535 else { throw ArchiveError.invalid("ZIP comment and extra fields exceed the format limit.") }
                var header = source.subdata(in: cursor..<cursor + 46)
                put16(&header, 30, UInt16(extra.count)); put16(&header, 32, UInt16(stored.count))
                directory.append(header); directory.append(name); directory.append(extra); directory.append(stored)
            } else { directory.append(source.subdata(in: cursor..<next)) }
            cursor = next
        }
        guard cursor == centralEnd else { throw ArchiveError.invalid("ZIP directory signatures or unrecognized trailing directory records cannot be rewritten safely.") }
        var footer = source.subdata(in: centralEnd..<source.count)
        if let zip64 {
            put64(&footer, 40, UInt64(directory.count))
            put64(&footer, end - 12 - zip64, UInt64(centralStart + directory.count - prefix))
        }
        let endInFooter = end - centralEnd
        if u32(footer, endInFooter + 12) != UInt32.max {
            guard directory.count < UInt32.max else { throw ArchiveError.invalid("ZIP comment would require upgrading to ZIP64.") }
            put32(&footer, endInFooter + 12, UInt32(directory.count))
        }
        let temporary = archive.deletingLastPathComponent().appendingPathComponent(".7zip-comment-" + UUID().uuidString + ".zip")
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ArchiveError.io("Cannot create a private ZIP update file.") }
        defer { try? manager.removeItem(at: temporary) }
        let output = try FileHandle(forWritingTo: temporary)
        do {
            var offset = 0
            while offset < centralStart { try control.checkpoint(); let next = min(centralStart, offset + 1_048_576); try output.write(contentsOf: source.subdata(in: offset..<next)); offset = next }
            try output.write(contentsOf: directory); try output.write(contentsOf: footer); try output.synchronize(); try output.close()
        } catch { try? output.close(); throw error }
        try await validate(temporary)
        try control.checkpoint()
        let current = try manager.attributesOfItem(atPath: archive.path)
        for attribute in [FileAttributeKey.systemNumber, .systemFileNumber, .size, .modificationDate] {
            guard String(describing: current[attribute]) == String(describing: originalAttributes[attribute]) else { throw ArchiveError.invalid("The ZIP archive changed while its comment was being updated.") }
        }
        // Copy file metadata (including macOS extended attributes), then publish atomically.
        guard copyfile(archive.path, temporary.path, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else { throw ArchiveError.io("Cannot preserve ZIP archive metadata.") }
        try control.checkpoint()
        guard Darwin.rename(temporary.path, archive.path) == 0 else { throw ArchiveError.io("Cannot publish the ZIP comment update.") }
    }
    private static func u16(_ d: Data, _ i: Int) -> UInt16 { UInt16(d[i]) | UInt16(d[i + 1]) << 8 }
    private static func u32(_ d: Data, _ i: Int) -> UInt32 { UInt32(u16(d, i)) | UInt32(u16(d, i + 2)) << 16 }
    private static func u64(_ d: Data, _ i: Int) -> UInt64 { UInt64(u32(d, i)) | UInt64(u32(d, i + 4)) << 32 }
    private static func put16(_ d: inout Data, _ i: Int, _ n: UInt16) { d[i] = UInt8(truncatingIfNeeded: n); d[i + 1] = UInt8(truncatingIfNeeded: n >> 8) }
    private static func put32(_ d: inout Data, _ i: Int, _ n: UInt32) { for j in 0..<4 { d[i + j] = UInt8(truncatingIfNeeded: n >> (j * 8)) } }
    private static func put64(_ d: inout Data, _ i: Int, _ n: UInt64) { for j in 0..<8 { d[i + j] = UInt8(truncatingIfNeeded: n >> (j * 8)) } }
    private static func append16(_ d: inout Data, _ n: UInt16) { d.append(UInt8(truncatingIfNeeded: n)); d.append(UInt8(truncatingIfNeeded: n >> 8)) }
    private static func append32(_ d: inout Data, _ n: UInt32) { for j in 0..<4 { d.append(UInt8(truncatingIfNeeded: n >> (j * 8))) } }
    private static func crc32(_ d: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in d { crc ^= UInt32(byte); for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : crc >> 1 ^ 0xedb88320 } }
        return crc ^ 0xffffffff
    }
}
