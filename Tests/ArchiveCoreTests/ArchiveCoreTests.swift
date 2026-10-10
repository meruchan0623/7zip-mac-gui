import Foundation
import Darwin
import Testing
@testable import ArchiveCore

@Suite(.serialized)
final class ArchiveCoreTests {
    private var root: URL!
    private var engine: SevenZipEngine!
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveCore-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        engine = SevenZipEngine(binaryURL: try SevenZipEngine.locateBinary())
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    private func file(_ name: String, _ content: String = "Unicode 中文 🙂\n") throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url); return url
    }
    @discardableResult private func run(_ command: ArchiveCommand) async throws -> CommandResult { try await engine.run(command, control: OperationControl()) }
    private func expectFailure(_ action: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await action(); XCTFail("Expected failure", file: file, line: line) } catch {}
    }
    @Test func testForcedTopLevelAndParserListingExtraction() async throws {
        let input = try file("inside.txt", "forced mode")
        let archive = root.appendingPathComponent("forced.7z")
        try await run(ArchiveCommands.create(archive: archive, inputs: [input], options: CompressionOptions()))
        let listing = try await engine.list(archive: archive, openMode: .topLevel)
        XCTAssertEqual(listing.entries.map(\.path), ["inside.txt"])
        var options = ExtractionOptions(destination: root.appendingPathComponent("forced-out")); options.openMode = .topLevel
        XCTAssertTrue(try ArchiveCommands.extract(archive: archive, options: options).arguments.contains("-t*"))
        _ = try await engine.extract(archive: archive, options: options, control: OperationControl())
        XCTAssertEqual(try String(contentsOf: options.destination.appendingPathComponent("inside.txt"), encoding: .utf8), "forced mode")
        XCTAssertTrue(ArchiveCommands.test(archive: archive, openMode: .parser).arguments.contains("-t#"))
        // Parser mode intentionally ignores a full archive at offset zero.
        await expectFailure { _ = try await self.engine.list(archive: archive, openMode: .parser) }
        let embedded = root.appendingPathComponent("embedded.bin")
        var embeddedData = Data(repeating: 0x61, count: 256); embeddedData.append(try Data(contentsOf: archive)); try embeddedData.write(to: embedded)
        let parsed = try await engine.list(archive: embedded, openMode: .parser)
        XCTAssertFalse(parsed.entries.isEmpty)
        options.destination = root.appendingPathComponent("parser-out"); options.openMode = .parser
        _ = try await engine.extract(archive: embedded, options: options, control: OperationControl())
        XCTAssertTrue(FileManager.default.fileExists(atPath: options.destination.path))
    }
    @Test func testTypedTimePrecisionAndStorageCapabilities() async throws {
        let input = try file("time.txt")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000.123456)], ofItemAtPath: input.path)
        for (format, precision, suffix) in [("7z", ArchiveTimePrecision.windows100ns, ".123456"), ("zip", .unixSeconds, "00"), ("tar", .microseconds, ".123456"), ("gzip", .unixSeconds, "00")] {
            var options = CompressionOptions(); options.format = format; options.timePrecision = precision; options.modificationTime = .store
            if format == "tar" { options.method = "pax" }
            let archive = root.appendingPathComponent("time." + format)
            try await run(ArchiveCommands.create(archive: archive, inputs: [input], options: options))
            let value = try await engine.list(archive: archive).entries.first!.modified
            XCTAssertTrue(suffix == "00" ? !value.contains(".") : value.contains(suffix), value)
        }
        var invalid = CompressionOptions(); invalid.format = "zip"; invalid.timePrecision = .nanoseconds
        XCTAssertThrowsError(try ArchiveCommands.create(archive: root.appendingPathComponent("bad.zip"), inputs: [input], options: invalid))
        invalid.timePrecision = .unixSeconds; invalid.creationTime = .store
        XCTAssertThrowsError(try ArchiveCommands.create(archive: root.appendingPathComponent("bad.zip"), inputs: [input], options: invalid))
        invalid.format = "xz"; invalid.timePrecision = .automatic; invalid.creationTime = .automatic; invalid.modificationTime = .store
        XCTAssertThrowsError(try ArchiveCommands.create(archive: root.appendingPathComponent("bad.xz"), inputs: [input], options: invalid))
    }
    @Test func testCompressionPathModesArchiveTimestampAndMemoryBudgets() async throws {
        let input = try file("paths/nested/absolute [*].txt", "path payload")
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: input.path)
        for mode in CompressionPathMode.allCases {
            var options = CompressionOptions(); options.pathMode = mode; options.setArchiveTimeToLatest = true; options.memoryLimit = "p60"
            let archive = root.appendingPathComponent("path-" + mode.rawValue + ".7z")
            let command = try ArchiveCommands.create(archive: archive, inputs: [input], options: options)
            XCTAssertTrue(command.arguments.contains("-stl")); XCTAssertTrue(command.arguments.contains("-mmemuse=p60"))
            try await run(command)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: archive.path)[.modificationDate] as? Date)?.timeIntervalSince1970, timestamp.timeIntervalSince1970)
            let listing = try await engine.list(archive: archive)
            XCTAssertEqual(listing.entries.count, 1)
            if mode == .relative { XCTAssertEqual(listing.entries[0].path, input.lastPathComponent) }
            else { XCTAssertTrue(listing.entries[0].path.hasSuffix("paths/nested/absolute [*].txt")) }
            var extraction = ExtractionOptions(destination: root.appendingPathComponent("path-out-" + mode.rawValue)); extraction.remapAbsolutePaths = true; extraction.selectedPaths = [listing.entries[0].path]
            _ = try await engine.extract(archive: archive, options: extraction, control: OperationControl())
            let mapped = try ArchiveCommands.remappedArchivePath(listing.entries[0].path)
            XCTAssertEqual(try String(contentsOf: extraction.destination.appendingPathComponent(mapped), encoding: .utf8), "path payload")
            XCTAssertEqual(try String(contentsOf: input, encoding: .utf8), "path payload")
        }
        for format in ["7z", "zip", "gzip", "bzip2", "xz"] {
            var options = CompressionOptions(); options.format = format; options.memoryLimit = "128m"
            try await run(ArchiveCommands.create(archive: root.appendingPathComponent("budget." + format), inputs: [input], options: options))
        }
        for value in ["p0", "p101", "0m", "-1m", "128m -sdel"] {
            var options = CompressionOptions(); options.memoryLimit = value
            XCTAssertThrowsError(try ArchiveCommands.create(archive: root.appendingPathComponent("invalid-budget.7z"), inputs: [input], options: options))
        }
        var unsupported = CompressionOptions(); unsupported.format = "tar"; unsupported.memoryLimit = "128m"
        XCTAssertThrowsError(try ArchiveCommands.create(archive: root.appendingPathComponent("unsupported.tar"), inputs: [input], options: unsupported))
        XCTAssertThrowsError(try ArchiveCommands.remappedArchivePath("/safe/../escape"))
        XCTAssertThrowsError(try ArchiveCommands.remappedArchivePath("C:/safe/../escape"))
    }
    @Test func testAbsoluteWindowsUNCAndPOSIXNamesStayInsideDestination() async throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
import zipfile,sys,stat
with zipfile.ZipFile(sys.argv[1],'w') as z:
 z.writestr('/posix/value.bin',bytes(range(256)))
 z.writestr('C:/win/中文 [*].txt','windows')
 z.writestr(r'\\\\Server\\Share\\file.txt','unc')
 i=zipfile.ZipInfo('/posix/alias');i.create_system=3;i.external_attr=(stat.S_IFLNK|0o777)<<16;z.writestr(i,b'/posix/value.bin')
""", root.appendingPathComponent("absolute.zip").path]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        let archive = root.appendingPathComponent("absolute.zip")
        await expectFailure { _ = try await self.engine.extract(archive: archive, options: ExtractionOptions(destination: self.root.appendingPathComponent("default-reject")), control: OperationControl()) }
        var options = ExtractionOptions(destination: root.appendingPathComponent("absolute-out")); options.remapAbsolutePaths = true
        _ = try await engine.extract(archive: archive, options: options, control: OperationControl())
        XCTAssertEqual(try Data(contentsOf: options.destination.appendingPathComponent("posix/value.bin")), Data((0...255).map(UInt8.init)))
        XCTAssertEqual(try String(contentsOf: options.destination.appendingPathComponent("C/win/中文 [*].txt"), encoding: .utf8), "windows")
        XCTAssertEqual(try String(contentsOf: options.destination.appendingPathComponent("UNC/Server/Share/file.txt"), encoding: .utf8), "unc")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: options.destination.appendingPathComponent("posix/alias").path), "value.bin")
        options.destination = root.appendingPathComponent("absolute-selected"); options.selectedPaths = ["C:/win/中文 [*].txt"]
        _ = try await engine.extract(archive: archive, options: options, control: OperationControl())
        XCTAssertEqual(try String(contentsOf: options.destination.appendingPathComponent("C/win/中文 [*].txt"), encoding: .utf8), "windows")
        XCTAssertFalse(FileManager.default.fileExists(atPath: options.destination.appendingPathComponent("posix/value.bin").path))
        try await run(ArchiveCommands.rename(archive: archive, from: "C:/win/中文 [*].txt", to: "C:/win/renamed.txt"))
        try await run(ArchiveCommands.delete(archive: archive, paths: ["C:/win/renamed.txt"]))
        XCTAssertFalse(try await engine.list(archive: archive).entries.contains { $0.path.hasPrefix("C:") })
    }
    @Test func testAbsoluteRemapProtectsArchiveHardlinkAndCancelsBeforeWrites() async throws {
        let archive = root.appendingPathComponent("source.zip")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],'w'); z.writestr('/source.zip',b'replacement'); z.writestr('/alias.zip',b'alias replacement'); z.writestr('/existing.txt',b'new'); z.writestr('/fresh.txt',b'fresh'); z.close()", archive.path]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        try FileManager.default.linkItem(at: archive, to: root.appendingPathComponent("alias.zip"))
        let before = try Data(contentsOf: archive)
        var options = ExtractionOptions(destination: root); options.remapAbsolutePaths = true; options.overwrite = .overwrite
        for member in ["/source.zip", "/alias.zip"] {
            options.selectedPaths = [member]; let guarded = options
            await expectFailure { _ = try await self.engine.extract(archive: archive, options: guarded, control: OperationControl()) }
            XCTAssertEqual(try Data(contentsOf: archive), before)
        }
        _ = try file("cancel-remap/existing.txt", "keep")
        options.destination = root.appendingPathComponent("cancel-remap"); options.selectedPaths = ["/existing.txt", "/fresh.txt"]; options.overwrite = .ask
        let cancelled = options
        await expectFailure {
            _ = try await self.engine.extract(archive: archive, options: cancelled, control: OperationControl(), resolveConflict: { _ in ExtractionConflictResolution(action: .cancel) })
        }
        XCTAssertEqual(try String(contentsOf: options.destination.appendingPathComponent("existing.txt"), encoding: .utf8), "keep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: options.destination.appendingPathComponent("fresh.txt").path))
    }
    @Test func testRemappedPOSIXSpecialBitsNanosecondsAndRestrictedDirectories() async throws {
        XCTAssertEqual(ExtractionMetadata.permissions(from: "-rwSr-Sr-T"), 0o7644)
        XCTAssertEqual(ExtractionMetadata.permissions(from: "-rwsr-sr-t"), 0o7755)
        XCTAssertEqual(ExtractionMetadata.permissions(from: "drwSrwSr-T"), 0o7664)
        for absolute in [false, true] {
            for permission in [0o000, 0o200] {
                let archive = root.appendingPathComponent("restricted-\(absolute)-\(permission).tar")
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                process.arguments = ["-c", """
import tarfile,sys,io
prefix='/restricted' if sys.argv[2]=='True' else 'restricted'
with tarfile.open(sys.argv[1],'w',format=tarfile.PAX_FORMAT) as t:
 d=tarfile.TarInfo(prefix);d.type=tarfile.DIRTYPE;d.mode=int(sys.argv[3]);t.addfile(d)
 f=tarfile.TarInfo(prefix+'/file.bin');f.mode=0o7644;f.size=4;f.pax_headers={'mtime':'1700000000.123456789'};t.addfile(f,io.BytesIO(b'DATA'))
 s=tarfile.TarInfo(prefix+'/alias');s.type=tarfile.SYMTYPE;s.linkname='file.bin';t.addfile(s)
""", archive.path, absolute ? "True" : "False", String(permission)]
                try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
                var options = ExtractionOptions(destination: root.appendingPathComponent("restricted-out-\(absolute)-\(permission)")); options.remapAbsolutePaths = absolute
                _ = try await engine.extract(archive: archive, options: options, control: OperationControl())
                let directory = options.destination.appendingPathComponent("restricted")
                XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, permission)
                // Temporarily grant traversal only after checking final restored permissions.
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
                let file = directory.appendingPathComponent("file.bin")
                var metadata = stat(); XCTAssertEqual(Darwin.lstat(file.path, &metadata), 0)
                XCTAssertEqual(Int(metadata.st_mode & 0o7777), 0o7644)
                XCTAssertEqual(metadata.st_mtimespec.tv_sec, 1_700_000_000)
                XCTAssertEqual(metadata.st_mtimespec.tv_nsec, 123_456_789)
                XCTAssertEqual(try Data(contentsOf: file), Data("DATA".utf8))
                XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("alias"), encoding: .utf8), "DATA")
            }
        }
    }
    @Test func testStageEnumerationThrowsForInaccessibleDirectories() throws {
        _ = try file("enumeration/locked/file.txt", "must not be omitted")
        let stage = root.appendingPathComponent("enumeration"), locked = stage.appendingPathComponent("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        // UID 0 can traverse mode 000; the normal desktop user must receive an error.
        if Darwin.getuid() != 0 { XCTAssertThrowsError(try LinkArchiveExtractor.stagedListing(stage)) }
        let saved = try LinkArchiveExtractor.prepareStagingDirectories(stage)
        XCTAssertEqual(saved["locked"]?.permissions, 0o000)
        XCTAssertTrue(try LinkArchiveExtractor.stagedListing(stage).entries.contains { $0.path == "locked/file.txt" })
    }
    @Test func testZIPUnicodeCommentEncryptedPayloadDirectoryAndRemoval() async throws {
        let first = try file("comment-input/ascii.txt", "sensitive payload"), second = try file("comment-input/中文.txt", "second payload")
        let directory = first.deletingLastPathComponent()
        for encrypted in [false, true] {
            var options = CompressionOptions(); options.format = "zip"; if encrypted { options.password = "secret-password" }
            let archive = root.appendingPathComponent(encrypted ? "encrypted-comment.zip" : "plain-comment.zip")
            try await run(ArchiveCommands.create(archive: archive, inputs: [directory], options: options))
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: archive.path)
            let before = try Data(contentsOf: archive)
            for member in ["comment-input/ascii.txt", "comment-input/中文.txt", "comment-input"] {
                try await engine.setMemberComment(archive: archive, member: member, comment: "中文注释 🙂\n第二行")
                let listing = try await engine.list(archive: archive)
                XCTAssertEqual(try await engine.memberComment(archive: archive, member: member), "中文注释 🙂\n第二行")
            }
            let after = try Data(contentsOf: archive)
            // Every local record, including encrypted compressed content, is byte-identical.
            let signature = Data([0x50, 0x4b, 0x01, 0x02]), central = before.range(of: signature)!.lowerBound
            XCTAssertEqual(after.prefix(central), before.prefix(central))
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: archive.path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
            try await engine.setMemberComment(archive: archive, member: "comment-input/ascii.txt", comment: "")
            XCTAssertEqual(try await engine.list(archive: archive).entries.first { $0.path == "comment-input/ascii.txt" }?.properties["Comment"] ?? "", "")
            XCTAssertTrue(try await run(ArchiveCommands.test(archive: archive, password: options.password)).succeeded)
            var extraction = ExtractionOptions(destination: root.appendingPathComponent("comment-out-\(encrypted)")); extraction.password = options.password
            _ = try await engine.extract(archive: archive, options: extraction, control: OperationControl())
            XCTAssertEqual(try Data(contentsOf: extraction.destination.appendingPathComponent("comment-input/ascii.txt")), try Data(contentsOf: first))
            XCTAssertEqual(try Data(contentsOf: extraction.destination.appendingPathComponent("comment-input/中文.txt")), try Data(contentsOf: second))
            let cancelled = OperationControl(); cancelled.cancel(); let untouched = try Data(contentsOf: archive)
            await expectFailure { try await self.engine.setMemberComment(archive: archive, member: "comment-input/ascii.txt", comment: "cancelled", control: cancelled) }
            XCTAssertEqual(try Data(contentsOf: archive), untouched)
        }
    }
    @Test func testZIP64SFXCommentAndUnsupportedSplitPreserveOriginal() async throws {
        let fixture = root.appendingPathComponent("source.zip")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
import zipfile,struct,sys,pathlib
root=pathlib.Path(sys.argv[1])
with zipfile.ZipFile(root/'source.zip','w',compression=zipfile.ZIP_DEFLATED) as z:
 z.writestr('a.txt',b'zip64 payload')
data=(root/'source.zip').read_bytes(); end=data.rfind(b'PK\\x05\\x06')
_,disk,cdisk,n1,n2,size,offset,comment=struct.unpack('<IHHHHIIH',data[end:end+22])
z64=struct.pack('<IQHHIIQQQQ',0x06064b50,44,45,45,0,0,n2,n2,size,offset)
locator=struct.pack('<IIQI',0x07064b50,0,end,1)
eocd=struct.pack('<IHHHHIIH',0x06054b50,0,0,65535,65535,0xffffffff,0xffffffff,0)
out=data[:end]+z64+locator+eocd
(root/'zip64.zip').write_bytes(out)
prefix=b'MZ'+b'_'*208
central=bytearray(data[offset:end]);struct.pack_into('<I',central,42,len(prefix))
sfx64=struct.pack('<IQHHIIQQQQ',0x06064b50,44,45,45,0,0,n2,n2,size,offset+len(prefix))
sfxlocator=struct.pack('<IIQI',0x07064b50,0,end+len(prefix),1)
(root/'sfx.zip').write_bytes(prefix+data[:offset]+central+sfx64+sfxlocator+eocd)
bad=bytearray(data);struct.pack_into('<H',bad,end+4,1);(root/'split.zip').write_bytes(bad)
""", root.path]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        for name in ["zip64.zip", "sfx.zip"] {
            let archive = root.appendingPathComponent(name), before = try Data(contentsOf: archive)
            try await engine.setMemberComment(archive: archive, member: "a.txt", comment: "ZIP64 中文 🙂")
            XCTAssertEqual(try await engine.memberComment(archive: archive, member: "a.txt"), "ZIP64 中文 🙂")
            XCTAssertTrue(try await run(ArchiveCommands.test(archive: archive)).succeeded)
            let central = before.range(of: Data([0x50, 0x4b, 0x01, 0x02]))!.lowerBound
            XCTAssertEqual(try Data(contentsOf: archive).prefix(central), before.prefix(central))
        }
        let split = root.appendingPathComponent("split.zip"), before = try Data(contentsOf: split)
        await expectFailure { try await self.engine.setMemberComment(archive: split, member: "a.txt", comment: "must not change") }
        XCTAssertEqual(try Data(contentsOf: split), before)
        XCTAssertFalse(ZipMemberComments.supports(archiveType: "7z"))
        // Excessive comments are rejected before an update file is published.
        let normal = try Data(contentsOf: fixture)
        await expectFailure { try await self.engine.setMemberComment(archive: fixture, member: "a.txt", comment: String(repeating: "a", count: 65_536)) }
        XCTAssertEqual(try Data(contentsOf: fixture), normal)
    }
    @Test func testFlatLinksRewriteRelativeTargetsAndKeepHardLinkIdentity() async throws {
        let target = try file("flatlinks/a/target.txt", "flat contents"), tree = root.appendingPathComponent("flatlinks")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("b"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("b/alias").path, withDestinationPath: "../a/target.txt")
        try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("b/chain").path, withDestinationPath: "alias")
        try FileManager.default.linkItem(at: target, to: tree.appendingPathComponent("b/hard.txt"))
        for format in ["tar", "7z", "zip", "wim"] {
            var compression = CompressionOptions(); compression.format = format; compression.storeSymbolicLinks = true; compression.storeHardLinks = ["tar", "wim"].contains(format)
            let archive = root.appendingPathComponent("flatlinks." + format)
            try await run(ArchiveCommands.create(archive: archive, inputs: [tree], options: compression))
            var options = ExtractionOptions(destination: root.appendingPathComponent("flat-out-" + format)); options.fullPaths = false
            _ = try await engine.extract(archive: archive, options: options, control: OperationControl())
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: options.destination.appendingPathComponent("alias").path), "target.txt")
            XCTAssertEqual(try String(contentsOf: options.destination.appendingPathComponent("chain"), encoding: .utf8), "flat contents")
            if ["tar", "wim"].contains(format) {
                XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: options.destination.appendingPathComponent("target.txt").path)[.systemFileNumber] as? NSNumber, try FileManager.default.attributesOfItem(atPath: options.destination.appendingPathComponent("hard.txt").path)[.systemFileNumber] as? NSNumber)
            }
            let repeated = try file("flat-out-" + format + "/target.txt", "old")
            options.overwrite = .renameExtracted
            _ = try await engine.extract(archive: archive, options: options, control: OperationControl())
            XCTAssertEqual(try String(contentsOf: repeated, encoding: .utf8), "old")
            XCTAssertEqual(try String(contentsOf: options.destination.appendingPathComponent("alias_1"), encoding: .utf8), "flat contents")
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: options.destination.appendingPathComponent("alias_1").path), "target_1.txt")
            options.destination = root.appendingPathComponent("flat-missing-" + format); options.selectedPaths = ["flatlinks/b/alias"]
            await expectFailure { _ = try await self.engine.extract(archive: archive, options: options, control: OperationControl()) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: options.destination.path))
        }
    }
    @Test func testUTF8StreamingAcrossEveryByteBoundary() {
        let text = "0%\r中文🙂 é 100%\n"
        var decoder = UTF8StreamDecoder(), result = ""
        for byte in text.utf8 { result += decoder.decode(Data([byte])) }
        result += decoder.decode(Data(), final: true)
        XCTAssertEqual(result, text)
    }
    @Test func testSLTSeparatesArchiveAndHandlesEqualsNames() throws {
        let listing = try SLTParser.parse("Path = archive.7z\nType = 7z\n\n----------\nPath = x = 中文.txt\nSize = 9\nEncrypted = +\n\nPath = folder\nFolder = +\nSize = 0\n")
        XCTAssertEqual(listing.properties["Path"], "archive.7z")
        XCTAssertEqual(listing.entries.count, 2); XCTAssertEqual(listing.entries[0].path, "x = 中文.txt")
        XCTAssertTrue(listing.entries[0].encrypted); XCTAssertTrue(listing.entries[1].isDirectory)
        XCTAssertThrowsError(try SLTParser.parse("Path = incomplete"))
        XCTAssertThrowsError(try SLTParser.parse("----------\nPath = innocent\n../../escape\nSize = 1\n"))
    }
    @Test func testFormatRoundTrips() async throws {
        let input = try file("中文 file.txt")
        for format in ["7z", "zip", "tar", "gzip", "bzip2", "xz", "wim"] {
            var options = CompressionOptions(); options.format = format
            let archive = root.appendingPathComponent("test." + format)
            XCTAssertTrue(try await run(ArchiveCommands.create(archive: archive, inputs: [input], options: options)).succeeded)
            let listing = try await engine.list(archive: archive)
            XCTAssertEqual(listing.entries.count, 1, format)
            guard let member = listing.entries.first else { throw ArchiveError.invalid("No stream member returned for \(format)") }
            if !["bzip2", "xz"].contains(format) { XCTAssertTrue(listing.entries.contains { $0.path == input.lastPathComponent }, format) }
            XCTAssertTrue(try await run(ArchiveCommands.test(archive: archive)).succeeded)
            let destination = root.appendingPathComponent("out-" + format)
            XCTAssertTrue(try await engine.extract(archive: archive, options: ExtractionOptions(destination: destination), control: OperationControl()).succeeded)
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(member.path)), try Data(contentsOf: input), format)
        }
    }
    @Test func testEncryptedHeaderPasswordAndWrongPasswordNoHang() async throws {
        let input = try file("fixture-pass-秘密.txt"), archive = root.appendingPathComponent("encrypted.7z")
        var options = CompressionOptions(); options.password = "fixture-pass-秘密"; options.encryptHeaders = true
        let command = try ArchiveCommands.create(archive: archive, inputs: [input], options: options)
        XCTAssertFalse(command.redactedDescription.contains(options.password))
        try await run(command)
        let listing = try await engine.list(archive: archive, password: options.password)
        XCTAssertEqual(listing.entries.first?.path, input.lastPathComponent)
        await expectFailure { _ = try await self.engine.list(archive: archive, password: "incorrect-fixture") }
        await expectFailure { _ = try await self.engine.list(archive: archive) }
        var extraction = ExtractionOptions(destination: root.appendingPathComponent("decrypted")); extraction.password = options.password
        _ = try await engine.extract(archive: archive, options: extraction, control: OperationControl())
        XCTAssertEqual(try Data(contentsOf: extraction.destination.appendingPathComponent(input.lastPathComponent)), try Data(contentsOf: input))
    }
    @Test func testLiteralSelectedExtractionDeleteRename() async throws {
        let first = try file("input/-中文 [*].txt", "one"), second = try file("input/other.txt", "two"), at = try file("input/@file.txt", "at")
        let archive = root.appendingPathComponent("-archive space.7z")
        try await run(ArchiveCommands.create(archive: archive, inputs: [first, second, at], options: CompressionOptions()))
        var extraction = ExtractionOptions(destination: root.appendingPathComponent("selected")); extraction.selectedPaths = [first.lastPathComponent, at.lastPathComponent]
        _ = try await engine.extract(archive: archive, options: extraction, control: OperationControl())
        XCTAssertTrue(FileManager.default.fileExists(atPath: extraction.destination.appendingPathComponent(first.lastPathComponent).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: extraction.destination.appendingPathComponent(at.lastPathComponent).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: extraction.destination.appendingPathComponent("other.txt").path))
        try await run(ArchiveCommands.rename(archive: archive, from: first.lastPathComponent, to: "-renamed 中文.txt"))
        try await run(ArchiveCommands.rename(archive: archive, from: at.lastPathComponent, to: "@renamed.txt"))
        XCTAssertTrue(try await engine.list(archive: archive).entries.contains { $0.path == "@renamed.txt" })
        try await run(ArchiveCommands.delete(archive: archive, paths: ["-renamed 中文.txt", "@renamed.txt"]))
        let listing = try await engine.list(archive: archive)
        XCTAssertEqual(listing.entries.map(\.path), ["other.txt"])
    }
    @Test func testSelectedDirectoryIncludesDescendants() async throws {
        let nested = try file("tree/dir/sub/child.txt", "nested")
        _ = try file("tree/other.txt", "other")
        let archive = root.appendingPathComponent("directory.7z")
        try await run(ArchiveCommands.create(archive: archive, inputs: [root.appendingPathComponent("tree")], options: CompressionOptions()))
        var options = ExtractionOptions(destination: root.appendingPathComponent("selected-dir")); options.selectedPaths = ["tree/dir"]
        _ = try await engine.extract(archive: archive, options: options, control: OperationControl())
        XCTAssertEqual(try Data(contentsOf: options.destination.appendingPathComponent("tree/dir/sub/child.txt")), try Data(contentsOf: nested))
        XCTAssertFalse(FileManager.default.fileExists(atPath: options.destination.appendingPathComponent("tree/other.txt").path))
        try await run(ArchiveCommands.delete(archive: archive, paths: ["tree/dir"]))
        XCTAssertFalse(try await engine.list(archive: archive).entries.contains { $0.path.hasPrefix("tree/dir") })
    }
    @Test func testUpdateFreshenAndSynchronize() async throws {
        let input = try file("tree/existing.txt", "old"), archive = root.appendingPathComponent("update.7z"), directory = input.deletingLastPathComponent()
        try await run(ArchiveCommands.create(archive: archive, inputs: [directory], options: CompressionOptions()))
        try Data("changed longer".utf8).write(to: input)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: input.path)
        let addition = try file("tree/new.txt", "new")
        var options = CompressionOptions(); options.updateMode = .freshen
        try await run(ArchiveCommands.create(archive: archive, inputs: [directory], options: options))
        var listing = try await engine.list(archive: archive)
        XCTAssertFalse(listing.entries.contains { $0.path == "tree/new.txt" })
        XCTAssertEqual(listing.entries.first { $0.path == "tree/existing.txt" }?.size, 14)
        options.updateMode = .update
        try await run(ArchiveCommands.create(archive: archive, inputs: [directory], options: options))
        listing = try await engine.list(archive: archive); XCTAssertTrue(listing.entries.contains { $0.path == "tree/new.txt" })
        try FileManager.default.removeItem(at: addition); options.updateMode = .synchronize
        try await run(ArchiveCommands.create(archive: archive, inputs: [directory], options: options))
        listing = try await engine.list(archive: archive); XCTAssertFalse(listing.entries.contains { $0.path == "tree/new.txt" })
    }
    @Test func testOverwriteModes() async throws {
        let input = try file("a.txt", "archive"), archive = root.appendingPathComponent("overwrite.zip")
        var compression = CompressionOptions(); compression.format = "zip"
        try await run(ArchiveCommands.create(archive: archive, inputs: [input], options: compression))
        for mode in OverwriteMode.allCases.filter({ $0 != .ask }) {
            let destination = root.appendingPathComponent(mode.rawValue)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data("existing".utf8).write(to: destination.appendingPathComponent("a.txt"))
            var options = ExtractionOptions(destination: destination); options.overwrite = mode
            _ = try await engine.extract(archive: archive, options: options, control: OperationControl())
            let names = try FileManager.default.contentsOfDirectory(atPath: destination.path)
            let original = try String(contentsOf: destination.appendingPathComponent("a.txt"), encoding: .utf8)
            XCTAssertEqual(original, mode == .skip || mode == .renameExtracted ? "existing" : "archive")
            XCTAssertEqual(names.count, mode == .renameExisting || mode == .renameExtracted ? 2 : 1)
        }
    }
    @Test func testSafetyTraversalAndDestinationLinks() throws {
        let options = ExtractionOptions(destination: root.appendingPathComponent("safe"))
        for path in ["../escape", "/absolute", "C:\\escape", "nested/../../escape", "nested\\..\\escape"] {
            XCTAssertThrowsError(try ExtractionSafety.preflight(listing: ArchiveListing(entries: [ArchiveEntry(path: path)]), options: options))
        }
        XCTAssertThrowsError(try ExtractionSafety.preflight(listing: ArchiveListing(entries: [ArchiveEntry(path: "link", properties: ["Symbolic Link": "outside"])]), options: options))
        try FileManager.default.createDirectory(at: options.destination, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: options.destination.appendingPathComponent("nested"), withDestinationURL: root)
        XCTAssertThrowsError(try ExtractionSafety.preflight(listing: ArchiveListing(entries: [ArchiveEntry(path: "nested/file.txt")]), options: options))
        XCTAssertThrowsError(try ExtractionSafety.preflight(listing: ArchiveListing(entries: [ArchiveEntry(path: "nested")]), options: options))
    }
    @Test func testRealSymlinkArchiveRejectedBeforeWriting() async throws {
        let outside = try file("outside.txt")
        let directory = root.appendingPathComponent("links"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link"), withDestinationURL: outside)
        let archive = root.appendingPathComponent("links.tar")
        try await run(ArchiveCommand(arguments: ["a", "-ttar", "-snl", "--", archive.path, "links"], workingDirectory: root))
        let listing = try await engine.list(archive: archive)
        XCTAssertTrue(listing.entries.contains { $0.properties["Symbolic Link"] != nil })
        let destination = root.appendingPathComponent("blocked")
        await expectFailure { _ = try await self.engine.extract(archive: archive, options: ExtractionOptions(destination: destination), control: OperationControl()) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
    @Test func testSafeTarAndSevenZipLinksRoundTrip() async throws {
        let target = try file("bundle/Versions/A/Headers/header.txt", "contents")
        let bundle = root.appendingPathComponent("bundle")
        try FileManager.default.createSymbolicLink(atPath: bundle.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try FileManager.default.createSymbolicLink(atPath: bundle.appendingPathComponent("Headers").path, withDestinationPath: "Versions/Current/Headers")
        try FileManager.default.createSymbolicLink(atPath: bundle.appendingPathComponent("Versions/A/Headers/local").path, withDestinationPath: "header.txt")
        try FileManager.default.linkItem(at: target, to: bundle.appendingPathComponent("hard.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: bundle.path)
        for format in ["tar", "7z"] {
            let archive = root.appendingPathComponent("safe-links." + format)
            var compression = CompressionOptions(); compression.format = format; compression.storeSymbolicLinks = true; compression.storeHardLinks = format == "tar"
            try await run(ArchiveCommands.create(archive: archive, inputs: [bundle], options: compression))
            let destination = root.appendingPathComponent("links-" + format)
            _ = try await engine.extract(archive: archive, options: ExtractionOptions(destination: destination), control: OperationControl())
            let extracted = destination.appendingPathComponent("bundle")
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: extracted.path)[.posixPermissions] as? NSNumber)?.intValue, 0o750)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: extracted.appendingPathComponent("Headers").path), "Versions/Current/Headers")
            XCTAssertEqual(try String(contentsOf: extracted.appendingPathComponent("Headers/header.txt"), encoding: .utf8), "contents")
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: extracted.appendingPathComponent("Versions/A/Headers/local").path), "header.txt")
            if format == "tar" {
                let first = try FileManager.default.attributesOfItem(atPath: extracted.appendingPathComponent("Versions/A/Headers/header.txt").path)[.systemFileNumber] as? NSNumber
                let second = try FileManager.default.attributesOfItem(atPath: extracted.appendingPathComponent("hard.txt").path)[.systemFileNumber] as? NSNumber
                XCTAssertEqual(first, second)
            }
        }
    }
    @Test func testLinkEscapesCyclesAndSourceAliasesBlockedBeforeWrites() async throws {
        for format in ["tar", "7z"] {
            for (suffix, target) in [("escape", "../../outside"), ("absolute", root.path)] {
                let directory = root.appendingPathComponent("malicious-" + suffix + "-" + format)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("link").path, withDestinationPath: target)
                let archive = root.appendingPathComponent("bad-" + suffix + "." + format)
                try await run(ArchiveCommand(arguments: ["a", "-t" + format, "-snl", "--", archive.path, directory.lastPathComponent], workingDirectory: root))
                let destination = root.appendingPathComponent("reject-" + suffix + "-" + format)
                await expectFailure { _ = try await self.engine.extract(archive: archive, options: ExtractionOptions(destination: destination), control: OperationControl()) }
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            }
        }
        let options = ExtractionOptions(destination: root)
        let archive = try file("protected.7z", "source")
        let sourceLink = ArchiveListing(entries: [ArchiveEntry(path: "alias", properties: ["Symbolic Link": "protected.7z"])])
        XCTAssertThrowsError(try LinkArchiveExtractor.validate(listing: sourceLink, destination: options.destination, protected: [archive], requireTargets: true))
        let cycle = ArchiveListing(entries: [ArchiveEntry(path: "a", properties: ["Symbolic Link": "b"]), ArchiveEntry(path: "b", properties: ["Symbolic Link": "a"])])
        XCTAssertThrowsError(try LinkArchiveExtractor.validate(listing: cycle, destination: root, protected: [], requireTargets: true))
        let ancestor = ArchiveListing(entries: [ArchiveEntry(path: "dir", properties: ["Symbolic Link": "safe"]), ArchiveEntry(path: "dir/child")])
        XCTAssertThrowsError(try LinkArchiveExtractor.validate(listing: ancestor, destination: root, protected: [], requireTargets: true))
    }
    @Test func testNativeTarDotRootAndSafeLink() async throws {
        let directory = root.appendingPathComponent("dot-root")
        _ = try file("dot-root/file.txt", "native tar")
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("link").path, withDestinationPath: "file.txt")
        let archive = root.appendingPathComponent("native.tar")
        let tar = SevenZipEngine(binaryURL: URL(fileURLWithPath: "/usr/bin/tar"))
        _ = try await tar.run(ArchiveCommand(arguments: ["-cf", archive.path, "-C", directory.path, "."]), control: OperationControl())
        let destination = root.appendingPathComponent("dot-out")
        _ = try await engine.extract(archive: archive, options: ExtractionOptions(destination: destination), control: OperationControl())
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("link"), encoding: .utf8), "native tar")
        let dottedAncestor = ArchiveListing(entries: [ArchiveEntry(path: "foo/link", properties: ["Symbolic Link": "../safe"]), ArchiveEntry(path: "foo/./link/child")])
        XCTAssertThrowsError(try LinkArchiveExtractor.validate(listing: dottedAncestor, destination: destination, protected: [], requireTargets: true))
    }
    @Test func testActualSevenZipLinkToSourceArchiveBlocked() async throws {
        let fixture = root.appendingPathComponent("fixtures/tree")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: fixture.appendingPathComponent("alias").path, withDestinationPath: "../source.7z")
        let archive = root.appendingPathComponent("source.7z")
        try await run(ArchiveCommand(arguments: ["a", "-t7z", "-snl", "--", archive.path, "tree"], workingDirectory: fixture.deletingLastPathComponent()))
        let before = try Data(contentsOf: archive)
        await expectFailure { _ = try await self.engine.extract(archive: archive, options: ExtractionOptions(destination: self.root), control: OperationControl()) }
        XCTAssertEqual(try Data(contentsOf: archive), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("tree").path))
    }
    @Test func testExtractionCannotOverwriteSourceArchiveOrHardlink() async throws {
        let input = try file("inputs/source.zip", "would destroy archive")
        let archive = root.appendingPathComponent("source.zip")
        var compression = CompressionOptions(); compression.format = "zip"
        try await run(ArchiveCommands.create(archive: archive, inputs: [input], options: compression))
        let before = try Data(contentsOf: archive)
        var options = ExtractionOptions(destination: root); options.overwrite = .overwrite
        await expectFailure { _ = try await self.engine.extract(archive: archive, options: options, control: OperationControl()) }
        XCTAssertEqual(try Data(contentsOf: archive), before)
        let alias = root.appendingPathComponent("alias.zip")
        try FileManager.default.linkItem(at: archive, to: alias)
        XCTAssertThrowsError(try ExtractionSafety.preflight(listing: ArchiveListing(entries: [ArchiveEntry(path: "alias.zip")]), options: options, protectedURLs: [archive]))
        let volume = try file("source.7z.002", "volume")
        XCTAssertThrowsError(try ExtractionSafety.preflight(listing: ArchiveListing(entries: [ArchiveEntry(path: "source.7z.002")]), options: options, protectedURLs: [archive, volume]))
    }
    @Test func testActualSplitArchiveCannotOverwriteSourceSiblingVolume() async throws {
        let input = root.appendingPathComponent("inputs/source.7z.002")
        try FileManager.default.createDirectory(at: input.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<4096).map { UInt8($0 % 251) }).write(to: input)
        var compression = CompressionOptions(); compression.volumeSize = "100b"
        try await run(ArchiveCommands.create(archive: root.appendingPathComponent("source.7z"), inputs: [input], options: compression))
        let first = root.appendingPathComponent("source.7z.001"), second = root.appendingPathComponent("source.7z.002")
        let before = try Data(contentsOf: second)
        var extraction = ExtractionOptions(destination: root); extraction.overwrite = .overwrite
        await expectFailure { _ = try await self.engine.extract(archive: first, options: extraction, control: OperationControl()) }
        XCTAssertEqual(try Data(contentsOf: second), before)
        XCTAssertTrue(try await run(ArchiveCommands.test(archive: first)).succeeded)
    }
    @Test func testEmptyAndMinusLinkFieldsAreRegularFiles() throws {
        let options = ExtractionOptions(destination: root)
        try ExtractionSafety.preflight(listing: ArchiveListing(entries: [ArchiveEntry(path: "safe.txt", properties: ["Symbolic Link": "", "Hard Link": "-"])]), options: options)
    }
    @Test func testDuplicateRootMappedSelectionAndProtectedSource() async throws {
        let directory = root.appendingPathComponent("fixtures/bundle")
        _ = try file("fixtures/bundle/dir/a.txt", "selected"); _ = try file("fixtures/bundle/b.txt", "excluded")
        let archive = root.appendingPathComponent("duplicate.7z")
        try await run(ArchiveCommands.create(archive: archive, inputs: [directory], options: CompressionOptions()))
        var options = ExtractionOptions(destination: root.appendingPathComponent("Bundle")); options.eliminateDuplicateRoot = true; options.selectedPaths = ["bundle/dir/a.txt"]
        _ = try await engine.extract(archive: archive, options: options, control: OperationControl())
        XCTAssertEqual(try String(contentsOf: options.destination.appendingPathComponent("dir/a.txt"), encoding: .utf8), "selected")
        XCTAssertFalse(FileManager.default.fileExists(atPath: options.destination.appendingPathComponent("bundle").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: options.destination.appendingPathComponent("b.txt").path))
        let dangerous = try file("inputs/protected/source.zip", "replace source")
        let source = root.appendingPathComponent("protected/source.zip")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        var compression = CompressionOptions(); compression.format = "zip"
        try await run(ArchiveCommands.create(archive: source, inputs: [dangerous.deletingLastPathComponent()], options: compression))
        let before = try Data(contentsOf: source)
        var protectedOptions = ExtractionOptions(destination: source.deletingLastPathComponent()); protectedOptions.eliminateDuplicateRoot = true; protectedOptions.overwrite = .overwrite
        await expectFailure { _ = try await self.engine.extract(archive: source, options: protectedOptions, control: OperationControl()) }
        XCTAssertEqual(try Data(contentsOf: source), before)
    }
    @Test func testDuplicateRootUsesAllMembersAndSafeLinks() async throws {
        let directory = root.appendingPathComponent("fixtures/package")
        _ = try file("fixtures/package/file.txt", "payload")
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("link").path, withDestinationPath: "file.txt")
        var compression = CompressionOptions(); compression.storeSymbolicLinks = true
        let archive = root.appendingPathComponent("links-root.7z")
        try await run(ArchiveCommands.create(archive: archive, inputs: [directory], options: compression))
        var options = ExtractionOptions(destination: root.appendingPathComponent("package")); options.eliminateDuplicateRoot = true
        _ = try await engine.extract(archive: archive, options: options, control: OperationControl())
        XCTAssertEqual(try String(contentsOf: options.destination.appendingPathComponent("link"), encoding: .utf8), "payload")
        let outside = try file("fixtures/other.txt", "outside")
        let mixed = root.appendingPathComponent("mixed.7z")
        try await run(ArchiveCommands.create(archive: mixed, inputs: [directory, outside], options: compression))
        let listing = try await engine.list(archive: mixed)
        options.selectedPaths = ["package/file.txt"]
        XCTAssertEqual(try ExtractionLayout(listing: listing, options: options).rootPrefix, nil)
    }
    @Test func testAskOverwriteMixedChoicesAndCancelBeforeWrites() async throws {
        let names = ["a.txt", "b.txt", "c.txt", "d.txt"]
        let inputs = try names.map { try file("ask-input/" + $0, "archive-" + $0) }
        let archive = root.appendingPathComponent("ask.zip")
        var compression = CompressionOptions(); compression.format = "zip"
        try await run(ArchiveCommands.create(archive: archive, inputs: inputs, options: compression))
        let destination = root.appendingPathComponent("ask-out")
        for name in names { _ = try file("ask-out/" + name, "existing-" + name) }
        var options = ExtractionOptions(destination: destination); options.overwrite = .ask
        let answers: [String: ExtractionConflictResolution] = ["a.txt": .init(action: .skip), "b.txt": .init(action: .overwrite), "c.txt": .init(action: .renameExtracted), "d.txt": .init(action: .renameExisting)]
        let recorder = ConflictRecorder(answers: answers)
        _ = try await engine.extract(archive: archive, options: options, control: OperationControl(), resolveConflict: { recorder.answer($0) })
        XCTAssertEqual(recorder.count, 4)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("a.txt"), encoding: .utf8), "existing-a.txt")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("b.txt"), encoding: .utf8), "archive-b.txt")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("c.txt"), encoding: .utf8), "existing-c.txt")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("c_1.txt"), encoding: .utf8), "archive-c.txt")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("d.txt"), encoding: .utf8), "archive-d.txt")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("d_1.txt"), encoding: .utf8), "existing-d.txt")
        let cancelDestination = root.appendingPathComponent("cancel-out")
        for name in names { _ = try file("cancel-out/" + name, "existing-" + name) }
        options.destination = cancelDestination
        let cancel = ConflictRecorder(sequence: [.init(action: .overwrite), .init(action: .cancel)])
        await expectFailure { _ = try await self.engine.extract(archive: archive, options: options, control: OperationControl(), resolveConflict: { cancel.answer($0) }) }
        for name in names { XCTAssertEqual(try String(contentsOf: cancelDestination.appendingPathComponent(name), encoding: .utf8), "existing-" + name) }
        let all = ConflictRecorder(sequence: [.init(action: .skip, applyToAll: true)])
        _ = try await engine.extract(archive: archive, options: options, control: OperationControl(), resolveConflict: { all.answer($0) })
        XCTAssertEqual(all.count, 1)
    }
    @Test func testFlatAskDuplicateNamesRejectBeforeWrites() async throws {
        let first = try file("flat-input/a/same.txt", "a")
        let second = try file("flat-input/b/same.txt", "b")
        let archive = root.appendingPathComponent("flat.zip")
        var compression = CompressionOptions(); compression.format = "zip"
        try await run(ArchiveCommands.create(archive: archive, inputs: [first.deletingLastPathComponent(), second.deletingLastPathComponent()], options: compression))
        var options = ExtractionOptions(destination: root.appendingPathComponent("flat-out")); options.fullPaths = false; options.overwrite = .ask
        let recorder = ConflictRecorder(sequence: [.init(action: .renameExtracted)])
        await expectFailure { _ = try await self.engine.extract(archive: archive, options: options, control: OperationControl(), resolveConflict: { recorder.answer($0) }) }
        XCTAssertEqual(recorder.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: options.destination.path))
        let existing = try file("flat-out/same.txt", "existing")
        await expectFailure { _ = try await self.engine.extract(archive: archive, options: options, control: OperationControl(), resolveConflict: { recorder.answer($0) }) }
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "existing")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: options.destination.path), ["same.txt"])
        // A literal selection of one member has no staging collision and remains supported.
        options.selectedPaths = ["a/same.txt"]
        _ = try await engine.extract(archive: archive, options: options, control: OperationControl(), resolveConflict: { recorder.answer($0) })
        XCTAssertEqual(recorder.count, 1)
        XCTAssertEqual(try String(contentsOf: options.destination.appendingPathComponent("same_1.txt"), encoding: .utf8), "a")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "existing")
    }
    @Test func testStagedDuplicateArchiveRecordsRejectBeforeWrites() async throws {
        let source = try file("duplicate-input/same.txt", "first version")
        let tar = SevenZipEngine(binaryURL: URL(fileURLWithPath: "/usr/bin/tar"))
        let recorder = ConflictRecorder(sequence: [.init(action: .renameExtracted)])
        for (index, names) in [("same.txt", "same.txt"), ("same.txt", "SAME.txt"), ("fóo.txt", "fo\u{301}o.txt")].enumerated() {
            let archive = root.appendingPathComponent("duplicate-records-\(index).tar")
            // Header substitutions let the real TAR contain aliases independently of the host filesystem.
            try Data("first version".utf8).write(to: source)
            _ = try await tar.run(ArchiveCommand(arguments: ["-cf", archive.path, "-s", "|^same.txt$|" + names.0 + "|", "-C", source.deletingLastPathComponent().path, source.lastPathComponent]), control: OperationControl())
            try Data("second version".utf8).write(to: source)
            _ = try await tar.run(ArchiveCommand(arguments: ["-rf", archive.path, "-s", "|^same.txt$|" + names.1 + "|", "-C", source.deletingLastPathComponent().path, source.lastPathComponent]), control: OperationControl())
            XCTAssertEqual(try await engine.list(archive: archive).entries.count, 2)
            for mode in [OverwriteMode.ask, .skip] {
                let outputName = "duplicate-out-\(index)-" + mode.rawValue
                var options = ExtractionOptions(destination: root.appendingPathComponent(outputName))
                options.overwrite = mode; options.eliminateDuplicateRoot = mode == .skip
                let existing = try file(outputName + "/" + names.0, "original")
                await expectFailure { _ = try await self.engine.extract(archive: archive, options: options, control: OperationControl(), resolveConflict: { recorder.answer($0) }) }
                XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "original")
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: options.destination.path), [names.0])
            }
        }
        XCTAssertEqual(recorder.count, 0)
    }
    @Test func testRepeatedSafeLinkExtractionAllPoliciesAndUnsafeLeaves() async throws {
        let directory = root.appendingPathComponent("repeat-input/tree")
        _ = try file("repeat-input/tree/file.txt", "payload")
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("link").path, withDestinationPath: "file.txt")
        var compression = CompressionOptions(); compression.format = "tar"; compression.storeSymbolicLinks = true
        let archive = root.appendingPathComponent("repeat.tar")
        try await run(ArchiveCommands.create(archive: archive, inputs: [directory], options: compression))
        for mode in OverwriteMode.allCases.filter({ $0 != .ask }) {
            var options = ExtractionOptions(destination: root.appendingPathComponent("repeat-" + mode.rawValue))
            _ = try await engine.extract(archive: archive, options: options, control: OperationControl())
            options.overwrite = mode
            _ = try await engine.extract(archive: archive, options: options, control: OperationControl())
            XCTAssertEqual(try String(contentsOf: options.destination.appendingPathComponent("tree/link"), encoding: .utf8), "payload")
        }
        let outside = try file("outside.txt", "outside")
        for mode in OverwriteMode.allCases.filter({ $0 != .ask }) {
            let destination = root.appendingPathComponent("unsafe-" + mode.rawValue)
            _ = try file("unsafe-" + mode.rawValue + "/tree/file.txt", "existing")
            try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("tree/link"), withDestinationURL: outside)
            var options = ExtractionOptions(destination: destination); options.overwrite = mode
            if mode == .skip || mode == .renameExtracted {
                await expectFailure { _ = try await self.engine.extract(archive: archive, options: options, control: OperationControl()) }
                XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("tree/file.txt"), encoding: .utf8), "existing")
            } else {
                _ = try await engine.extract(archive: archive, options: options, control: OperationControl())
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("tree/link").path), "file.txt")
            }
            XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "outside")
        }
    }
    @Test func testRenamedUnsafeLinkCannotFillCaseOrUnicodeAliasTarget() async throws {
        let outside = try file("rename-outside.txt", "outside must stay unreachable")
        for (index, pair) in [("foo", "FOO_1"), ("fóo", "FO\u{301}O_1")].enumerated() {
            let (name, danglingTarget) = pair
            let directory = root.appendingPathComponent("rename-input-\(index)/tree")
            _ = try file("rename-input-\(index)/tree/safe.txt", "safe payload")
            try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent(name).path, withDestinationPath: "safe.txt")
            try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("b").path, withDestinationPath: danglingTarget)
            var compression = CompressionOptions(); compression.storeSymbolicLinks = true
            let archive = root.appendingPathComponent("rename-alias-\(index).7z")
            try await run(ArchiveCommands.create(archive: archive, inputs: [directory], options: compression))
            let destination = root.appendingPathComponent("rename-alias-out-\(index)")
            try FileManager.default.createDirectory(at: destination.appendingPathComponent("tree"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("tree/" + name), withDestinationURL: outside)
            var options = ExtractionOptions(destination: destination); options.overwrite = .renameExisting
            _ = try await engine.extract(archive: archive, options: options, control: OperationControl())
            XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("tree/" + name), encoding: .utf8), "safe payload")
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("tree/b").path), danglingTarget)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("tree/b").path))
            XCTAssertThrowsError(try Data(contentsOf: destination.appendingPathComponent("tree/b")))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("tree/" + name + "_2").path), outside.path)
            XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "outside must stay unreachable")
        }
    }
    @Test func testTypedLinkStorageFormatMatrix() async throws {
        let regular = try file("matrix/file.txt", "same")
        let symbolic = regular.deletingLastPathComponent().appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: symbolic.path, withDestinationPath: "file.txt")
        let hard = regular.deletingLastPathComponent().appendingPathComponent("hard")
        try FileManager.default.linkItem(at: regular, to: hard)
        for format in ["zip", "wim"] {
            var options = CompressionOptions(); options.format = format; options.storeSymbolicLinks = true; options.storeHardLinks = format == "wim"
            let archive = root.appendingPathComponent("matrix." + format)
            try await run(ArchiveCommands.create(archive: archive, inputs: [regular, symbolic, hard], options: options))
            let destination = root.appendingPathComponent("matrix-out-" + format)
            _ = try await engine.extract(archive: archive, options: ExtractionOptions(destination: destination), control: OperationControl())
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("link").path), "file.txt")
            if format == "wim" { XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent("file.txt").path)[.systemFileNumber] as? NSNumber, try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent("hard").path)[.systemFileNumber] as? NSNumber) }
        }
        var invalid = CompressionOptions(); invalid.storeHardLinks = true
        XCTAssertThrowsError(try ArchiveCommands.create(archive: root.appendingPathComponent("invalid.7z"), inputs: [regular], options: invalid))
        invalid = CompressionOptions(); invalid.format = "gzip"; invalid.storeSymbolicLinks = true
        XCTAssertThrowsError(try ArchiveCommands.create(archive: root.appendingPathComponent("invalid.gz"), inputs: [regular], options: invalid))
    }
    @Test func testDeleteSourcesAfterSuccessfulCompressionOnly() async throws {
        // Every source and archive belongs to this test's disposable temporary directory.
        let input = try file("delete-on-success.txt", "retained in archive")
        let archive = root.appendingPathComponent("delete-on-success.7z")
        XCTAssertFalse(try ArchiveCommands.create(archive: archive, inputs: [input], options: CompressionOptions()).arguments.contains("-sdel"))
        var options = CompressionOptions(); options.deleteSourcesAfterCompression = true
        XCTAssertTrue(try await run(ArchiveCommands.create(archive: archive, inputs: [input], options: options)).succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: input.path))
        let destination = root.appendingPathComponent("delete-on-success-out")
        _ = try await engine.extract(archive: archive, options: ExtractionOptions(destination: destination), control: OperationControl())
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent(input.lastPathComponent), encoding: .utf8), "retained in archive")

        let retained = try file("retained-on-failure.txt", "must remain")
        let blocker = try file("output-parent-is-file", "blocker")
        await expectFailure { try await self.run(ArchiveCommands.create(archive: blocker.appendingPathComponent("cannot-create.7z"), inputs: [retained], options: options)) }
        XCTAssertEqual(try String(contentsOf: retained, encoding: .utf8), "must remain")
        XCTAssertEqual(try String(contentsOf: blocker, encoding: .utf8), "blocker")
        XCTAssertThrowsError(try ArchiveCommands.create(archive: retained, inputs: [retained], options: options))
        XCTAssertEqual(try String(contentsOf: retained, encoding: .utf8), "must remain")
    }
    @Test func testInputOutputValidationAndAdvancedSafety() throws {
        let directory = root.appendingPathComponent("input"); _ = try file("input/a.txt")
        XCTAssertThrowsError(try ArchiveCommands.create(archive: directory.appendingPathComponent("recursive.7z"), inputs: [directory], options: CompressionOptions()))
        var options = CompressionOptions(); options.format = "gzip"
        XCTAssertThrowsError(try ArchiveCommands.create(archive: root.appendingPathComponent("bad.gz"), inputs: [directory], options: options))
        options = CompressionOptions(); options.parameters = "-spf"
        XCTAssertThrowsError(try ArchiveCommands.create(archive: root.appendingPathComponent("bad.7z"), inputs: [directory], options: options))
        options.parameters = "-m0=LZMA2 -mtc=on"
        let command = try ArchiveCommands.create(archive: root.appendingPathComponent("good.7z"), inputs: [directory], options: options)
        XCTAssertTrue(command.arguments.contains("-m0=LZMA2")); XCTAssertTrue(command.arguments.contains("--"))
    }
    @Test func testSplitCombineExactBytesAndNoOverwrite() async throws {
        let input = root.appendingPathComponent("binary.dat")
        let data = Data((0..<2_200_003).map { UInt8($0 % 251) }); try data.write(to: input)
        let volumes = try await FileUtilities.split(file: input, destination: root, volumeBytes: 700_000, control: OperationControl())
        XCTAssertEqual(volumes.count, 4)
        let output = root.appendingPathComponent("combined.dat")
        _ = try await FileUtilities.combine(firstVolume: volumes[0], output: output, control: OperationControl())
        XCTAssertEqual(try Data(contentsOf: output), data)
        await expectFailure { _ = try await FileUtilities.combine(firstVolume: volumes[0], output: output, control: OperationControl()) }
        await expectFailure { _ = try await FileUtilities.split(file: input, destination: self.root, volumeBytes: 700_000, control: OperationControl()) }
        XCTAssertEqual(try Data(contentsOf: volumes[0]), data.prefix(700_000))
        try FileManager.default.removeItem(at: volumes[1])
        await expectFailure { _ = try await FileUtilities.combine(firstVolume: volumes[0], output: self.root.appendingPathComponent("gap.dat"), control: OperationControl()) }
    }
    @Test func testSplitCancellationCleansOwnVolumes() async throws {
        let input = root.appendingPathComponent("large.dat"); try Data(repeating: 7, count: 4_000_000).write(to: input)
        let control = OperationControl()
        await expectFailure { _ = try await FileUtilities.split(file: input, destination: self.root, volumeBytes: 500_000, control: control, onProgress: { _ in control.cancel() }) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["large.dat"])
    }
    @Test func testProcessPauseResumeCancellationAndTerminalControl() async throws {
        let control = OperationControl()
        let task = Task { try await self.engine.run(ArchiveCommands.benchmark(threads: 1, dictionary: "16m"), control: control) }
        try await Task.sleep(nanoseconds: 150_000_000); control.pause()
        try await Task.sleep(nanoseconds: 100_000_000); control.resume(); control.cancel()
        await expectFailure { _ = try await task.value }
        await expectFailure { _ = try await self.engine.run(ArchiveCommand(arguments: ["i"]), control: control) }
    }
    @Test func testHashActualEngineAndWarnings() async throws {
        let input = try file("hash.txt", "abc")
        let result = try await run(ArchiveCommands.hash(inputs: [input]))
        XCTAssertTrue(result.output.uppercased().contains("BA7816BF8F01CFEA"))
        for method in ["CRC32", "CRC64", "XXH64", "MD5", "SHA1", "SHA384", "SHA512", "SHA3-256", "BLAKE2sp", "*"] { XCTAssertTrue(try await run(ArchiveCommands.hash(inputs: [input], method: method)).succeeded, method) }
        let warning = try await run(ArchiveCommand(arguments: ["a", "--", root.appendingPathComponent("missing.7z").path, root.appendingPathComponent("does-not-exist").path]))
        XCTAssertTrue(warning.warning); XCTAssertFalse(warning.succeeded)
        await expectFailure { _ = try await self.engine.list(archive: self.root.appendingPathComponent("no-archive.7z")) }
    }
}

private func XCTFail(_ message: String, file: StaticString = #filePath, line: UInt = #line) { Issue.record(Comment(rawValue: message)) }
private func XCTAssertTrue(_ value: Bool, _ message: String = "") { #expect(value, Comment(rawValue: message)) }
private func XCTAssertFalse(_ value: Bool, _ message: String = "") { #expect(!value, Comment(rawValue: message)) }
private func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String = "") { #expect(lhs == rhs, Comment(rawValue: message)) }
private func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T) { do { _ = try expression(); Issue.record("Expected throw") } catch {} }

private final class ConflictRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let answers: [String: ExtractionConflictResolution]
    private let sequence: [ExtractionConflictResolution]
    private var seen = 0
    init(answers: [String: ExtractionConflictResolution] = [:], sequence: [ExtractionConflictResolution] = []) { self.answers = answers; self.sequence = sequence }
    var count: Int { lock.lock(); defer { lock.unlock() }; return seen }
    func answer(_ conflict: ExtractionConflict) -> ExtractionConflictResolution {
        lock.lock(); defer { lock.unlock() }
        let index = seen; seen += 1
        return answers[conflict.destination.lastPathComponent] ?? (sequence.isEmpty ? .init(action: .skip) : sequence[min(index, sequence.count - 1)])
    }
}
