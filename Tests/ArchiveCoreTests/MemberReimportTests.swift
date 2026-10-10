import Foundation
import Testing
@testable import ArchiveCore

@Suite(.serialized)
struct MemberReimportTests {
    private func fixture() throws -> (URL, SevenZipEngine) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Reimport-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return (root, SevenZipEngine(binaryURL: try SevenZipEngine.locateBinary()))
    }
    private func stream(_ engine: SevenZipEngine, _ archive: URL, _ member: String, password: String = "", root: URL) async throws -> Data {
        let out = root.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: out.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: out) }
        let args = ["x", "-so", "-bso0", "-bse2", "-bsp0", "-spd", "-i!" + member] + (password.isEmpty ? [] : ["-p" + password]) + ["--", archive.path]
        _ = try await engine.executeToFile(ArchiveCommand(arguments: args), to: out, control: OperationControl(), onOutput: { _ in })
        return try Data(contentsOf: out)
    }
    @Test func encryptedAbsoluteChineseReimportPreservesNamesAlgorithmsCommentsAndPermissions() async throws {
        let (root, engine) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("中文 [*] @编辑.txt"), other = root.appendingPathComponent("keep.txt"), edited = root.appendingPathComponent("edited")
        try Data("original".utf8).write(to: input); try Data("untouched".utf8).write(to: other)
        let bytes = Data((0...255).map(UInt8.init)) + Data("中文新内容\0\n".utf8); try bytes.write(to: edited)
        for (format, encryption) in [("7z", "AES256"), ("zip", "AES256"), ("zip", "AES192"), ("zip", "AES128"), ("zip", "ZipCrypto")] {
            let archive = root.appendingPathComponent(encryption + "." + format)
            var options = CompressionOptions(); options.format = format; options.pathMode = .absolute; options.password = "secret123"; options.encryptHeaders = format == "7z"; options.encryptionMethod = encryption
            _ = try await engine.run(ArchiveCommands.create(archive: archive, inputs: [input, other], options: options), control: OperationControl())
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: archive.path)
            if format == "zip" { try await engine.setMemberComment(archive: archive, member: input.path, comment: "中文注释🙂\nsecond"); try await engine.setMemberComment(archive: archive, member: other.path, comment: "保留") }
            let original = try await engine.list(archive: archive, password: options.password)
            let result = try await engine.reimportMember(archive: archive, member: input.path, file: edited, format: format, password: options.password)
            #expect(result.succeeded)
            let updated = try await engine.list(archive: archive, password: options.password)
            #expect(Set(updated.entries.map(\.path)) == Set(original.entries.map(\.path)))
            #expect(try await stream(engine, archive, input.path, password: options.password, root: root) == bytes)
            #expect(try await stream(engine, archive, other.path, password: options.password, root: root) == Data("untouched".utf8))
            #expect((try FileManager.default.attributesOfItem(atPath: archive.path)[.posixPermissions] as? NSNumber)?.intValue == 0o640)
            if format == "zip" {
                #expect(try await engine.memberComment(archive: archive, member: input.path) == "中文注释🙂\nsecond")
                #expect(try await engine.memberComment(archive: archive, member: other.path) == "保留")
                let expected = original.entries.first { $0.path == input.path }!.properties["Method"]!.components(separatedBy: " ").first!
                #expect(updated.entries.first { $0.path == input.path }!.properties["Method"]!.hasPrefix(expected))
            } else { await #expect(throws: (any Error).self) { _ = try await engine.list(archive: archive) } }
        }
    }
    @Test func windowsUNCAndLiteralRelativeMembersReimport() async throws {
        let (root, engine) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source"), edited = root.appendingPathComponent("edited")
        try Data("old".utf8).write(to: input); try Data("new 中文".utf8).write(to: edited)
        for format in ["7z", "zip"] {
            for name in ["C:/Windows/中文 [*].txt", "\\\\Server\\Share\\中文?.txt", "folder/@中文[-]*.txt"] {
                let archive = root.appendingPathComponent(UUID().uuidString + "." + format)
                var options = CompressionOptions(); options.format = format
                _ = try await engine.run(ArchiveCommands.create(archive: archive, inputs: [input], options: options), control: OperationControl())
                _ = try await engine.run(ArchiveCommands.rename(archive: archive, from: "source", to: name), control: OperationControl())
                let raw = try await engine.list(archive: archive).entries.first!.path
                _ = try await engine.reimportMember(archive: archive, member: raw, file: edited, format: format)
                #expect(try await engine.list(archive: archive).entries.map(\.path) == [raw])
                #expect(try await stream(engine, archive, raw, root: root) == Data("new 中文".utf8))
            }
        }
    }
    @Test func relativeTARAndWIMFallbackAndArchiveSymlink() async throws {
        let (root, engine) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let input = folder.appendingPathComponent("中文[*].txt"), edited = root.appendingPathComponent("edited")
        try Data("old".utf8).write(to: input); try Data("new".utf8).write(to: edited)
        for format in ["tar", "wim", "7z"] {
            let archive = root.appendingPathComponent("archive." + format), alias = root.appendingPathComponent("alias." + format)
            var options = CompressionOptions(); options.format = format
            _ = try await engine.run(ArchiveCommands.create(archive: archive, inputs: [folder], options: options), control: OperationControl())
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: archive)
            _ = try await engine.reimportMember(archive: alias, member: "folder/中文[*].txt", file: edited, format: format)
            #expect(try await stream(engine, archive, "folder/中文[*].txt", root: root) == Data("new".utf8))
            #expect((try FileManager.default.attributesOfItem(atPath: alias.path)[.type] as? FileAttributeType) == .typeSymbolicLink)
        }
    }
    @Test func failedReimportsPreserveOriginalArchiveExactly() async throws {
        let (root, engine) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("中文.txt"), edited = root.appendingPathComponent("edited"), archive = root.appendingPathComponent("archive.7z")
        try Data("original".utf8).write(to: input); try Data("new".utf8).write(to: edited)
        var options = CompressionOptions(); options.password = "correct"; options.encryptHeaders = true
        _ = try await engine.run(ArchiveCommands.create(archive: archive, inputs: [input], options: options), control: OperationControl())
        let original = try Data(contentsOf: archive)
        let cancelled = OperationControl(); cancelled.cancel()
        for (member, file, format, password, control) in [("中文.txt", edited, "7z", "wrong", OperationControl()), ("missing", edited, "7z", "correct", OperationControl()), ("中文.txt", edited, "zip", "correct", OperationControl()), ("中文.txt", archive, "7z", "correct", OperationControl()), ("中文.txt", edited, "7z", "correct", cancelled)] {
            await #expect(throws: (any Error).self) { _ = try await engine.reimportMember(archive: archive, member: member, file: file, format: format, password: password, control: control) }
            #expect(try Data(contentsOf: archive) == original)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".7zip-reimport-") })
    }
    @Test func absoluteWIMAndSingleStreamsReimport() async throws {
        let (root, engine) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("中文.txt"), edited = root.appendingPathComponent("edited")
        try Data("old".utf8).write(to: input); let bytes = Data(repeating: 201, count: 100_111); try bytes.write(to: edited)
        for format in ["wim", "gzip", "bzip2", "xz"] {
            let archive = root.appendingPathComponent("中文." + format)
            var options = CompressionOptions(); options.format = format; options.pathMode = .absolute
            _ = try await engine.run(ArchiveCommands.create(archive: archive, inputs: [input], options: options), control: OperationControl())
            let before = try await engine.list(archive: archive), member = before.entries.first { !$0.isDirectory }!.path
            _ = try await engine.reimportMember(archive: archive, member: member, file: edited, format: format)
            #expect(try await engine.list(archive: archive).entries.map(\.path) == before.entries.map(\.path))
            #expect(try await stream(engine, archive, member, root: root) == bytes)
        }
    }
    @Test func absoluteGNUAndPAXTARReimportPreservesUnrelatedRecords() async throws {
        let (root, engine) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let edited = root.appendingPathComponent("edited"); let bytes = Data(repeating: 203, count: 1029) + Data("改写中文".utf8); try bytes.write(to: edited)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
import tarfile,io,pathlib,sys
root=pathlib.Path(sys.argv[1])
names=['/absolute/中文.txt','/'+('长中文目录/'*20)+'文件.txt','C:/Windows/中文[*].txt',r'\\\\Server\\Share\\中文.txt']
for fmt in ['gnu','pax','global']:
 for idx,name in enumerate(names):
  kwargs={'format':tarfile.GNU_FORMAT if fmt=='gnu' else tarfile.PAX_FORMAT}
  if fmt=='global': kwargs['pax_headers']={'mtime':'123.25','comment':'global保留'}
  with tarfile.open(root/(fmt+str(idx)+'.tar'),'w',**kwargs) as t:
   for path,payload in [('before.txt',b'BEFORE'),(name,b'OLD'),('after.txt',b'AFTER')]:
    i=tarfile.TarInfo(path);i.size=len(payload);i.mode=0o640
    if fmt!='gnu' and path==name: i.pax_headers={'path':name,'size':str(len(payload)),'mtime':'123.25','comment':'中文保留'}
    t.addfile(i,io.BytesIO(payload))
""", root.path]
        try process.run(); process.waitUntilExit(); #expect(process.terminationStatus == 0)
        for archive in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where archive.pathExtension == "tar" {
            let before = try await engine.list(archive: archive), member = before.entries.first { $0.path != "before.txt" && $0.path != "after.txt" }!.path
            let source = try Data(contentsOf: archive)
            _ = try await engine.reimportMember(archive: archive, member: member, file: edited, format: "tar")
            #expect(try await engine.list(archive: archive).entries.map(\.path) == before.entries.map(\.path))
            #expect(try await stream(engine, archive, member, root: root) == bytes)
            #expect(try await stream(engine, archive, "before.txt", root: root) == Data("BEFORE".utf8))
            #expect(try await stream(engine, archive, "after.txt", root: root) == Data("AFTER".utf8))
            let result = try Data(contentsOf: archive)
            // Fixed ordinary before/after records retain their original full header,
            // payload and padding. Extended headers of the edited item may resize.
            for name in ["before.txt", "after.txt"] {
                let needle = Data(name.utf8)
                let first = source.range(of: needle)!.lowerBound, next = result.range(of: needle)!.lowerBound
                #expect(source.subdata(in: first..<first + 1024) == result.subdata(in: next..<next + 1024))
            }
        }
    }
    @Test func nativeGNUAndPAXAbsoluteTARReimport() async throws {
        let (root, engine) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent(String(repeating: "中文", count: 25)); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let input = folder.appendingPathComponent("原始.txt"), other = root.appendingPathComponent("keep.txt"), edited = root.appendingPathComponent("edited")
        try Data("old".utf8).write(to: input); try Data("keep".utf8).write(to: other); try Data("new 中文".utf8).write(to: edited)
        for method in ["", "gnu", "pax"] {
            let archive = root.appendingPathComponent("native-" + method + ".tar")
            var options = CompressionOptions(); options.format = "tar"; options.method = method; options.pathMode = .absolute
            _ = try await engine.run(ArchiveCommands.create(archive: archive, inputs: [input, other], options: options), control: OperationControl())
            _ = try await engine.reimportMember(archive: archive, member: input.path, file: edited, format: "tar")
            #expect(try await stream(engine, archive, input.path, root: root) == Data("new 中文".utf8))
            #expect(try await stream(engine, archive, other.path, root: root) == Data("keep".utf8))
        }
    }
    @Test func archiveBasenamesCannotCollideWithPrivateWorkflowFiles() async throws {
        let (root, engine) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source.txt"), edited = root.appendingPathComponent("edited")
        try Data("old".utf8).write(to: input); try Data("new 中文".utf8).write(to: edited)
        for format in ["7z", "zip", "bzip2", "xz"] {
            let folder = root.appendingPathComponent(format); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            for name in ["payload", "proof"] {
                let archive = folder.appendingPathComponent(name)
                let created = archive.appendingPathExtension(format)
                var options = CompressionOptions(); options.format = format
                _ = try await engine.run(ArchiveCommands.create(archive: created, inputs: [input], options: options), control: OperationControl())
                try FileManager.default.moveItem(at: created, to: archive)
                let before = try await engine.list(archive: archive), member = before.entries.first!.path
                _ = try await engine.reimportMember(archive: archive, member: member, file: edited, format: format)
                #expect(try await engine.list(archive: archive).entries.map(\.path) == before.entries.map(\.path))
                #expect(try await stream(engine, archive, member, root: root) == Data("new 中文".utf8))
            }
        }
    }
    @Test func exactArchiveOutputNamesForCreateUpdateRenameAndDelete() async throws {
        let (root, engine) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source.txt"), other = root.appendingPathComponent("keep.txt")
        try Data("old".utf8).write(to: input); try Data("keep".utf8).write(to: other)
        for format in ["7z", "zip"] {
            try Data("old".utf8).write(to: input)
            let folder = root.appendingPathComponent(format); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let archive = folder.appendingPathComponent("noextension")
            var options = CompressionOptions(); options.format = format
            _ = try await engine.run(ArchiveCommands.create(archive: archive, inputs: [input, other], options: options), control: OperationControl())
            #expect(FileManager.default.fileExists(atPath: archive.path))
            #expect(!FileManager.default.fileExists(atPath: archive.appendingPathExtension(format).path))
            try Data("longer new content".utf8).write(to: input)
            options.updateMode = .update
            _ = try await engine.run(ArchiveCommands.create(archive: archive, inputs: [input], options: options), control: OperationControl())
            #expect(try await stream(engine, archive, "source.txt", root: root) == Data("longer new content".utf8))
            _ = try await engine.run(ArchiveCommands.rename(archive: archive, from: "source.txt", to: "中文 renamed.txt"), control: OperationControl())
            #expect(try await engine.list(archive: archive).entries.contains { $0.path == "中文 renamed.txt" })
            _ = try await engine.run(ArchiveCommands.delete(archive: archive, paths: ["中文 renamed.txt"]), control: OperationControl())
            #expect(try await engine.list(archive: archive).entries.map(\.path) == ["keep.txt"])
            #expect(try await stream(engine, archive, "keep.txt", root: root) == Data("keep".utf8))
        }
    }
    @Test func failuresAfterPrivateRenameAndConcurrentInputChangesNeverPublish() async throws {
        let (root, engine) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        func pythonString(_ value: String) throws -> String { let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]; return String(data: try encoder.encode(value), encoding: .utf8)! }
        for scenario in ["engine-failure", "archive-change", "edited-change", "cancel"] {
            let folder = root.appendingPathComponent(scenario); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let archive = folder.appendingPathComponent("archive.7z"), input = folder.appendingPathComponent("中文.txt"), edited = folder.appendingPathComponent("edited")
            try Data("original".utf8).write(to: input); try Data("edited".utf8).write(to: edited)
            _ = try await engine.run(ArchiveCommands.create(archive: archive, inputs: [input], options: CompressionOptions()), control: OperationControl())
            let original = try Data(contentsOf: archive), marker = folder.appendingPathComponent("waiting"), resume = folder.appendingPathComponent("resume"), wrapper = folder.appendingPathComponent("controlled-engine")
            let script = """
            #!/usr/bin/python3
            import os,sys,time,pathlib
            if sys.argv[1]=='u':
                pathlib.Path(\(try pythonString(marker.path))).touch()
                while not pathlib.Path(\(try pythonString(resume.path))).exists(): time.sleep(.01)
                if \(try pythonString(scenario))=='engine-failure': sys.exit(2)
            os.execv(\(try pythonString(engine.binaryURL.path)), [\(try pythonString(engine.binaryURL.path))]+sys.argv[1:])
            """
            try Data(script.utf8).write(to: wrapper); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
            let controlled = SevenZipEngine(binaryURL: wrapper), control = OperationControl()
            let task = Task { try await controlled.reimportMember(archive: archive, member: "中文.txt", file: edited, format: "7z", control: control) }
            var reached = false
            for _ in 0..<500 { if FileManager.default.fileExists(atPath: marker.path) { reached = true; break }; try await Task.sleep(nanoseconds: 10_000_000) }
            guard reached else { control.cancel(); do { _ = try await task.value; Issue.record("Private-copy update did not reach its controlled checkpoint") } catch { Issue.record(Comment(rawValue: "Private-copy checkpoint failed: " + error.localizedDescription)) }; continue }
            let stages = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".7zip-reimport-") }
            #expect(stages.count == 1)
            let privateNames = try await engine.list(archive: stages[0].appendingPathComponent("archive").appendingPathComponent(archive.lastPathComponent)).entries.map(\.path)
            #expect(privateNames.count == 1 && privateNames[0].hasPrefix(".7zip-edit-"))
            var expected = original
            if scenario == "archive-change" { expected.append(Data("external-change".utf8)); try expected.write(to: archive) }
            if scenario == "edited-change" { try Data("external-edited-change".utf8).write(to: edited) }
            if scenario == "cancel" { control.cancel() }
            try Data().write(to: resume)
            await #expect(throws: (any Error).self) { _ = try await task.value }
            #expect(try Data(contentsOf: archive) == expected)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).allSatisfy { !$0.hasPrefix(".7zip-reimport-") })
        }
    }
}
