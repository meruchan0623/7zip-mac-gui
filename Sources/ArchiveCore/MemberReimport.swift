import Foundation
import CryptoKit
import Darwin

extension SevenZipEngine {
    /// Update one regular member without exposing archive names as filesystem paths.
    /// The caller must hold the shared archive mutation reservation for this workflow.
    /// All engine writes and validation occur on a private, same-volume copy; publication
    /// replaces the resolved archive target atomically only after both inputs are rechecked.
    public func reimportMember(archive: URL, member: String, file: URL, format: String, password: String = "", control: OperationControl = OperationControl()) async throws -> CommandResult {
        let manager = FileManager.default
        try control.checkpoint()
        _ = try ArchiveCommands.remappedArchivePath(member)
        let target = archive.standardizedFileURL.resolvingSymlinksInPath()
        let original = try ReimportFingerprint.capture(target, control: control)
        let edited = try ReimportFingerprint.capture(file, control: control)
        guard original.identity != edited.identity else { throw ArchiveError.invalid("The edited file cannot be the source archive or its hard link.") }
        let listing = try await list(archive: target, password: password, control: control)
        let type = (listing.properties["Type"] ?? "").lowercased()
        guard type == format.lowercased(), ["7z", "zip", "tar", "wim", "gzip", "bzip2", "xz"].contains(type) else { throw ArchiveError.invalid("This archive format cannot safely reimport an edited member.") }
        let matches = listing.entries.filter { $0.path == member }
        guard Set(listing.entries.map(\.path)).count == listing.entries.count else { throw ArchiveError.invalid("Archive editing requires unique member names.") }
        guard matches.count == 1, let entry = matches.first, !entry.isDirectory,
              !LinkArchiveExtractor.isSymbolic(entry), !LinkArchiveExtractor.isHard(entry), entry.properties["Anti"] != "+" else {
            throw ArchiveError.invalid("Choose one unique regular archive member to edit.")
        }
        guard !entry.encrypted || !password.isEmpty else { throw ArchiveError.invalid("The encrypted member requires its password before editing.") }
        var encryptedHeaders = false
        if type == "7z", !password.isEmpty {
            do { _ = try await list(archive: target, control: control) }
            catch { try control.checkpoint(); encryptedHeaders = true }
        }
        let stage = target.deletingLastPathComponent().appendingPathComponent(".7zip-reimport-" + UUID().uuidString)
        try manager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: stage) }
        // Nameless bzip2/xz members derive their display name from this basename.
        // Keep this user-controlled basename in its own directory so archives named
        // payload/proof cannot collide with the workflow's staging or verification files.
        let archiveDirectory = stage.appendingPathComponent("archive")
        try manager.createDirectory(at: archiveDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let privateArchive = archiveDirectory.appendingPathComponent(target.lastPathComponent)
        try manager.copyItem(at: target, to: privateArchive)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateArchive.path)
        let payload = stage.appendingPathComponent("payload")
        try manager.createDirectory(at: payload, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let usesRename = ["7z", "zip", "wim"].contains(type)
        let rewritesTAR = type == "tar" && (try? ArchiveCommands.validateMember(member)) == nil
        let rebuildsStream = ["bzip2", "xz"].contains(type)
        if rebuildsStream, listing.entries.count != 1 { throw ArchiveError.invalid("Stream editing requires exactly one archive member.") }
        let placeholder = ".7zip-edit-" + UUID().uuidString
        let inputName: String
        if usesRename { inputName = placeholder }
        else if rewritesTAR { inputName = placeholder }
        else { try ArchiveCommands.validateMember(member); inputName = member }
        let input = payload.appendingPathComponent(inputName)
        try manager.createDirectory(at: input.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.copyItem(at: file, to: input)
        guard try ReimportFingerprint.capture(input, control: control).digest == edited.digest else { throw ArchiveError.invalid("The edited file changed while its private copy was being prepared.") }
        var output = ""
        func checked(_ command: ArchiveCommand) async throws {
            // Update commands otherwise append the format extension to valid archives
            // without a filename extension, including the fresh bzip2/xz private output.
            var arguments = command.arguments
            if ["a", "u", "rn"].contains(arguments.first ?? ""), !arguments.contains("-sae") { arguments.insert("-sae", at: 1) }
            let result = try await run(ArchiveCommand(arguments: arguments, workingDirectory: command.workingDirectory), control: control)
            guard result.succeeded else { throw ArchiveError.failed(result.exitCode, result.output) }
            output += result.output
        }
        let comments = type == "zip" ? try Dictionary(uniqueKeysWithValues: listing.entries.map { ($0.path, try ZipMemberComments.read(archive: target, listing: listing, member: $0.path)) }) : [:]
        if usesRename { try await checked(ArchiveCommands.rename(archive: privateArchive, from: member, to: placeholder, password: password)) }
        var args = [rebuildsStream ? "a" : "u", "-y", "-t" + type, "-spd", "-bso1", "-bse2", "-bsp0", "-sccUTF-8"]
        if !rebuildsStream { args.append("-up1q1r2x2y2z2w2") }
        if entry.encrypted || encryptedHeaders { args.append("-p" + password) }
        if type == "7z", !password.isEmpty { args.append(encryptedHeaders ? "-mhe=on" : "-mhe=off") }
        if type == "zip", entry.encrypted {
            let method = entry.properties["Method"] ?? ""
            let encryption: String
            if method.contains("AES-256") { encryption = "AES256" }
            else if method.contains("AES-192") { encryption = "AES192" }
            else if method.contains("AES-128") { encryption = "AES128" }
            else if method.contains("ZipCrypto") { encryption = "ZipCrypto" }
            else { throw ArchiveError.invalid("The ZIP encryption method cannot be preserved safely.") }
            args.append("-mem=" + encryption)
        }
        // Exact include plus disabled wildcards prevents @, -, and glob names becoming
        // list files or selecting neighbouring members. No original absolute disk path is used.
        args += ["-i!" + inputName, "--", privateArchive.path]
        if rebuildsStream { try manager.removeItem(at: privateArchive) }
        if rewritesTAR { try TarMemberReimport.rewrite(archive: privateArchive, member: member, input: input, control: control) }
        else { try await checked(ArchiveCommand(arguments: args, workingDirectory: payload)) }
        if usesRename { try await checked(ArchiveCommands.rename(archive: privateArchive, from: placeholder, to: member, password: password)) }
        var updated = try await list(archive: privateArchive, password: password, control: control)
        guard updated.entries.count == listing.entries.count, Set(updated.entries.map(\.path)) == Set(listing.entries.map(\.path)),
              let replacement = updated.entries.first(where: { $0.path == member }), replacement.encrypted == entry.encrypted else {
            throw ArchiveError.invalid("The updated archive changed member names or encryption; original archive was preserved.")
        }
        for previous in listing.entries where previous.path != member {
            guard let current = updated.entries.first(where: { $0.path == previous.path }), current.isDirectory == previous.isDirectory, current.size == previous.size,
                  current.encrypted == previous.encrypted, current.properties["CRC"] == previous.properties["CRC"] else {
                throw ArchiveError.invalid("An unrelated archive member changed during editing; original archive was preserved.")
            }
        }
        for (path, comment) in comments {
            if try ZipMemberComments.read(archive: privateArchive, listing: updated, member: path) != comment {
                try await setMemberComment(archive: privateArchive, member: path, comment: comment, control: control)
                updated = try await list(archive: privateArchive, password: password, control: control)
            }
        }
        try await checked(ArchiveCommands.test(archive: privateArchive, password: password))
        let proof = stage.appendingPathComponent("proof")
        guard manager.createFile(atPath: proof.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ArchiveError.io("Cannot create a private edit verification file.") }
        let stream = ["x", "-so", "-bso0", "-bse2", "-bsp0", "-spd", "-i!" + member] + (password.isEmpty ? [] : ["-p" + password]) + ["--", privateArchive.path]
        let verification = try await executeToFile(ArchiveCommand(arguments: stream), to: proof, control: control, onOutput: { _ in })
        guard verification.succeeded, try ReimportFingerprint.capture(proof, control: control).digest == edited.digest else {
            throw ArchiveError.invalid("Edited member verification failed; original archive was preserved.")
        }
        if encryptedHeaders {
            do { _ = try await list(archive: privateArchive, control: control); throw ArchiveError.invalid("Archive header encryption was lost during editing.") }
            catch let error as ArchiveError { if case .invalid = error { throw error }; try control.checkpoint() }
        }
        guard archive.standardizedFileURL.resolvingSymlinksInPath() == target,
              try ReimportFingerprint.capture(target, control: control) == original,
              try ReimportFingerprint.capture(file, control: control) == edited else {
            throw ArchiveError.invalid("The archive or edited file changed during verification; original archive was preserved.")
        }
        guard copyfile(target.path, privateArchive.path, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else { throw ArchiveError.io("Cannot preserve archive metadata during editing.") }
        try control.checkpoint()
        guard Darwin.rename(privateArchive.path, target.path) == 0 else { throw ArchiveError.io("Cannot publish the verified archive edit.") }
        return CommandResult(output: output, exitCode: 0)
    }
}

private struct ReimportFingerprint: Equatable {
    let identity: String
    let size: UInt64
    let modified: Date
    let digest: Data
    static func capture(_ url: URL, control: OperationControl) throws -> Self {
        let manager = FileManager.default
        let before = try manager.attributesOfItem(atPath: url.path)
        guard before[.type] as? FileAttributeType == .typeRegular else { throw ArchiveError.invalid("Archive editing requires regular files.") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while true { try control.checkpoint(); let chunk = try handle.read(upToCount: 1_048_576) ?? Data(); if chunk.isEmpty { break }; hash.update(data: chunk) }
        let after = try manager.attributesOfItem(atPath: url.path)
        for key in [FileAttributeKey.systemNumber, .systemFileNumber, .size, .modificationDate] {
            guard String(describing: before[key]) == String(describing: after[key]) else { throw ArchiveError.invalid("A file changed while archive editing was reading it.") }
        }
        return Self(identity: "\(before[.systemNumber]!) : \(before[.systemFileNumber]!)", size: (before[.size] as! NSNumber).uint64Value, modified: before[.modificationDate] as! Date, digest: Data(hash.finalize()))
    }
}
