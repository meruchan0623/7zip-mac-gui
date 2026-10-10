import Foundation
import Darwin

/// Replaces a regular GNU/PAX/USTAR payload without interpreting its absolute name
/// as a disk path. Used on an already private archive; the engine verifies the result.
enum TarMemberReimport {
    private struct Record { let range: Range<Int>; let header: Data; let type: UInt8; let body: Data }
    static func rewrite(archive: URL, member: String, input: URL, control: OperationControl) throws {
        let manager = FileManager.default, source = try Data(contentsOf: archive, options: .alwaysMapped)
        let size = (try manager.attributesOfItem(atPath: input.path)[.size] as! NSNumber).uint64Value
        guard size <= UInt64(Int.max) else { throw ArchiveError.invalid("The edited TAR file is too large.") }
        let temporary = archive.deletingLastPathComponent().appendingPathComponent("tar-update-" + UUID().uuidString)
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ArchiveError.io("Cannot create a private TAR update file.") }
        defer { try? manager.removeItem(at: temporary) }
        let output = try FileHandle(forWritingTo: temporary); defer { try? output.close() }
        var offset = 0, pending: [Record] = [], global: [String: String] = [:], local: [String: String] = [:], longName: String?, updated = false
        while offset + 512 <= source.count {
            try control.checkpoint()
            var header = source.subdata(in: offset..<offset + 512)
            if header.allSatisfy({ $0 == 0 }) {
                guard pending.isEmpty else { throw ArchiveError.invalid("TAR has dangling metadata records.") }
                try write(source, range: offset..<source.count, to: output, control: control); offset = source.count; break
            }
            let storedSize = try number(header.subdata(in: 124..<136))
            guard storedSize <= UInt64(Int.max - 1023) else { throw ArchiveError.invalid("TAR member is too large.") }
            let type = header[156]
            let actualSize: UInt64
            if [UInt8(76), 75, 120, 103].contains(type) { actualSize = storedSize }
            else if let override = local["size"] ?? global["size"] { guard let value = UInt64(override) else { throw ArchiveError.invalid("Invalid PAX member size.") }; actualSize = value }
            else { actualSize = storedSize }
            guard actualSize <= UInt64(Int.max - 1023) else { throw ArchiveError.invalid("TAR member is too large.") }
            guard actualSize <= source.count - offset - 512 else { throw ArchiveError.invalid("Truncated TAR member.") }
            let end = offset + 512 + ((Int(actualSize) + 511) / 512) * 512
            guard end >= offset, end <= source.count else { throw ArchiveError.invalid("Truncated TAR member.") }
            let metadata = [UInt8(76), 75, 120, 103].contains(type)
            if metadata, actualSize > 16_777_216 { throw ArchiveError.invalid("TAR metadata exceeds the safe editing limit.") }
            let record = Record(range: offset..<end, header: header, type: type, body: metadata ? source.subdata(in: offset + 512..<offset + 512 + Int(actualSize)) : Data())
            offset = end
            if type == 103 { for (key, value) in try pax(record.body) { global[key] = value }; pending.append(record); continue }
            if type == 120 { for (key, value) in try pax(record.body) { local[key] = value }; pending.append(record); continue }
            if type == 76 { longName = try text(record.body); pending.append(record); continue }
            if type == 75 { pending.append(record); continue }
            // GNU reuses the POSIX prefix area for atime/ctime/sparse fields.
            let isPOSIX = header.subdata(in: 257..<263) == Data("ustar\0".utf8)
            let prefix = isPOSIX ? try text(header.subdata(in: 345..<500)) : "", name = try text(header.subdata(in: 0..<100))
            let path = local["path"] ?? global["path"] ?? longName ?? (prefix.isEmpty ? name : prefix + "/" + name)
            if path == member {
                guard !updated, type == 0 || type == 48,
                      !Array(global.keys).contains(where: { $0.hasPrefix("GNU.sparse") }), !Array(local.keys).contains(where: { $0.hasPrefix("GNU.sparse") }) else {
                    throw ArchiveError.invalid("TAR editing requires one ordinary, non-sparse member.")
                }
                if local["size"] != nil || global["size"] != nil {
                    local["size"] = String(size)
                    for metadata in pending where metadata.type != 120 { try write(source, range: metadata.range, to: output, control: control) }
                    var paxHeader = pending.last(where: { $0.type == 120 })?.header ?? header
                    paxHeader[156] = 120
                    if !pending.contains(where: { $0.type == 120 }) { paxHeader.replaceSubrange(0..<100, with: padded(Data(".7zip-pax-size".utf8), count: 100)); paxHeader.replaceSubrange(345..<500, with: Data(repeating: 0, count: 155)) }
                    let body = encodePAX(local); try updateSize(&paxHeader, UInt64(body.count)); checksum(&paxHeader)
                    try output.write(contentsOf: paxHeader); try output.write(contentsOf: body); try padding(body.count, to: output)
                } else { for metadata in pending { try write(source, range: metadata.range, to: output, control: control) } }
                try updateSize(&header, size); checksum(&header); try output.write(contentsOf: header)
                let edited = try FileHandle(forReadingFrom: input)
                do { while true { try control.checkpoint(); let chunk = try edited.read(upToCount: 1_048_576) ?? Data(); if chunk.isEmpty { break }; try output.write(contentsOf: chunk) }; try edited.close() }
                catch { try? edited.close(); throw error }
                try padding(Int(size), to: output); updated = true
            } else {
                for metadata in pending { try write(source, range: metadata.range, to: output, control: control) }
                try write(source, range: record.range, to: output, control: control)
            }
            pending = []; local = [:]; longName = nil
        }
        guard updated, offset == source.count else { throw ArchiveError.invalid("The selected TAR member was not found or its trailing records are invalid.") }
        try output.synchronize(); try output.close(); try control.checkpoint()
        guard Darwin.rename(temporary.path, archive.path) == 0 else { throw ArchiveError.io("Cannot save the private TAR edit.") }
    }
    private static func text(_ bytes: Data) throws -> String {
        let value = bytes.prefix(while: { $0 != 0 })
        guard let result = String(data: value, encoding: .utf8) else { throw ArchiveError.invalid("TAR editing requires UTF-8 metadata names.") }; return result
    }
    private static func number(_ bytes: Data) throws -> UInt64 {
        if bytes.first! & 0x80 != 0 {
            guard bytes.first! & 0x40 == 0 else { throw ArchiveError.invalid("Negative TAR member size.") }
            var value: UInt64 = 0
            for (index, byte) in bytes.enumerated() { let digit = index == 0 ? byte & 0x7f : byte; guard value <= (UInt64.max - UInt64(digit)) / 256 else { throw ArchiveError.invalid("TAR size overflow.") }; value = value * 256 + UInt64(digit) }; return value
        }
        let value = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        guard let result = UInt64(value.isEmpty ? "0" : value, radix: 8) else { throw ArchiveError.invalid("Invalid TAR size.") }; return result
    }
    private static func pax(_ body: Data) throws -> [String: String] {
        var result: [String: String] = [:], offset = 0
        while offset < body.count {
            guard let space = body[offset...].firstIndex(of: 32), let count = Int(String(decoding: body[offset..<space], as: UTF8.self)), count > space - offset + 2, count <= body.count - offset, body[offset + count - 1] == 10,
                  let field = String(data: body.subdata(in: space + 1..<offset + count - 1), encoding: .utf8), let separator = field.firstIndex(of: "=") else { throw ArchiveError.invalid("Invalid PAX metadata record.") }
            result[String(field[..<separator])] = String(field[field.index(after: separator)...]); offset += count
        }; return result
    }
    private static func encodePAX(_ fields: [String: String]) -> Data {
        var result = Data()
        for key in fields.keys.sorted() { let field = Data((key + "=" + fields[key]! + "\n").utf8); var length = field.count + 2; while true { let next = field.count + String(length).utf8.count + 1; if next == length { break }; length = next }; result.append(Data((String(length) + " ").utf8)); result.append(field) }; return result
    }
    private static func updateSize(_ header: inout Data, _ size: UInt64) throws {
        let octal = String(size, radix: 8)
        if octal.count <= 11 { header.replaceSubrange(124..<136, with: Data((String(repeating: "0", count: 11 - octal.count) + octal + "\0").utf8)) }
        else { var bytes = Data(repeating: 0, count: 12); var value = size; for index in stride(from: 11, through: 1, by: -1) { bytes[index] = UInt8(truncatingIfNeeded: value); value >>= 8 }; bytes[0] = 0x80; header.replaceSubrange(124..<136, with: bytes) }
    }
    private static func checksum(_ header: inout Data) { header.replaceSubrange(148..<156, with: Data(repeating: 32, count: 8)); let value = String(header.reduce(0) { $0 + Int($1) }, radix: 8); header.replaceSubrange(148..<156, with: Data((String(repeating: "0", count: 6 - value.count) + value + "\0 ").utf8)) }
    private static func padded(_ data: Data, count: Int) -> Data { data + Data(repeating: 0, count: count - data.count) }
    private static func padding(_ count: Int, to output: FileHandle) throws { let length = (512 - count % 512) % 512; if length != 0 { try output.write(contentsOf: Data(repeating: 0, count: length)) } }
    private static func write(_ source: Data, range: Range<Int>, to output: FileHandle, control: OperationControl) throws { var offset = range.lowerBound; while offset < range.upperBound { try control.checkpoint(); let next = min(range.upperBound, offset + 1_048_576); try output.write(contentsOf: source.subdata(in: offset..<next)); offset = next } }
}
