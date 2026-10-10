import Foundation
import Darwin

/// Keeps nanoseconds and POSIX special bits through private staging. Directory
/// permissions are applied only after every child has been published.
struct ExtractionMetadata: Sendable {
    struct Time: Sendable {
        let seconds: Int
        let nanoseconds: Int
        var spec: timespec { timespec(tv_sec: seconds, tv_nsec: nanoseconds) }
    }
    var permissions: Int?
    var modified: Time?
    var accessed: Time?
    var created: Time?

    func overlay(_ preferred: ExtractionMetadata) -> ExtractionMetadata {
        ExtractionMetadata(permissions: preferred.permissions ?? permissions, modified: preferred.modified ?? modified, accessed: preferred.accessed ?? accessed, created: preferred.created ?? created)
    }
    static func capture(_ url: URL) throws -> ExtractionMetadata {
        var value = stat()
        guard Darwin.lstat(url.path, &value) == 0 else { throw ArchiveError.io("Cannot read staged extraction metadata.") }
        return ExtractionMetadata(permissions: Int(value.st_mode & 0o7777), modified: Time(seconds: value.st_mtimespec.tv_sec, nanoseconds: value.st_mtimespec.tv_nsec), accessed: Time(seconds: value.st_atimespec.tv_sec, nanoseconds: value.st_atimespec.tv_nsec), created: Time(seconds: value.st_birthtimespec.tv_sec, nanoseconds: value.st_birthtimespec.tv_nsec))
    }
    static func from(_ entry: ArchiveEntry) -> ExtractionMetadata {
        let words = (entry.properties["Attributes"] ?? "").split(separator: " ").map(String.init)
        let attributesMode = words.first { $0.count == 10 && ["d", "-", "0"].contains(String($0.prefix(1))) } ?? ""
        return ExtractionMetadata(permissions: permissions(from: entry.properties["Mode"] ?? attributesMode), modified: time(entry.properties["Modified"] ?? entry.modified), accessed: time(entry.properties["Accessed"] ?? ""), created: time(entry.properties["Created"] ?? ""))
    }
    static func permissions(from mode: String) -> Int? {
        let raw = mode.count == 10 ? String(mode.dropFirst()) : mode
        guard raw.count == 9 else { return nil }
        let chars = Array(raw); var value = 0
        for group in 0..<3 {
            let offset = group * 3
            if chars[offset] == "r" { value |= 0o400 >> (group * 3) }
            if chars[offset + 1] == "w" { value |= 0o200 >> (group * 3) }
            // Uppercase S/T set special bits while explicitly omitting execute.
            if ["x", "s", "t"].contains(chars[offset + 2]) { value |= 0o100 >> (group * 3) }
        }
        if chars[2] == "s" || chars[2] == "S" { value |= 0o4000 }
        if chars[5] == "s" || chars[5] == "S" { value |= 0o2000 }
        if chars[8] == "t" || chars[8] == "T" { value |= 0o1000 }
        return value
    }
    private static func time(_ text: String) -> Time? {
        guard text.count >= 19 else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"; formatter.timeZone = .current
        guard let date = formatter.date(from: String(text.prefix(19))) else { return nil }
        let suffix = String(text.dropFirst(19))
        var nanoseconds = 0
        if suffix.hasPrefix(".") {
            let digits = String(suffix.dropFirst().prefix(while: { $0.isNumber }))
            guard !digits.isEmpty, digits.count <= 9, let value = Int(digits) else { return nil }
            nanoseconds = value * Int(pow(10.0, Double(9 - digits.count)))
        }
        return Time(seconds: Int(date.timeIntervalSince1970), nanoseconds: nanoseconds)
    }
    func apply(to url: URL) throws {
        if let created {
            var attributes = attrlist(); attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT); attributes.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
            var birth = created.spec
            guard Darwin.setattrlist(url.path, &attributes, &birth, MemoryLayout<timespec>.size, UInt32(FSOPT_NOFOLLOW)) == 0 else { throw ArchiveError.io("Cannot restore extracted creation time.") }
        }
        if modified != nil || accessed != nil {
            // Darwin's UTIME_OMIT value is -2; unchanged fields remain untouched.
            let omit = timespec(tv_sec: 0, tv_nsec: -2)
            var times = [accessed?.spec ?? omit, modified?.spec ?? omit]
            guard Darwin.utimensat(AT_FDCWD, url.path, &times, AT_SYMLINK_NOFOLLOW) == 0 else { throw ArchiveError.io("Cannot restore extracted timestamps.") }
        }
        if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
    }
}
