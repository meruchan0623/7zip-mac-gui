import Foundation

public enum ArchiveCommands {
    /// Unix symbolic-link payloads are supported by the bundled 26.04 engine in these formats.
    public static let symbolicLinkFormats = ["7z", "zip", "tar", "wim"]
    public static let hardLinkFormats = ["tar", "wim"]
    public static func supportsMemoryLimit(format: String) -> Bool { ["7z", "zip", "gzip", "bzip2", "xz"].contains(format.lowercased()) }
    public static func timePrecisions(format: String, method: String = "") -> [ArchiveTimePrecision] {
        switch format.lowercased() {
        case "7z", "wim": return [.automatic, .windows100ns]
        case "zip": return [.automatic, .windows100ns, .unixSeconds, .dosTwoSeconds]
        case "tar": return [.automatic, .windows100ns, .unixSeconds, .nanoseconds, .seconds, .milliseconds, .microseconds, .hundredNanoseconds, .exactNanoseconds]
        case "gzip": return [.automatic, .unixSeconds]
        default: return [.automatic]
        }
    }
    public static func supportsTimestamp(_ kind: String, format: String, method: String = "", precision: ArchiveTimePrecision = .automatic) -> Bool {
        switch format.lowercased() {
        case "7z", "wim": return true
        case "zip": return kind == "m" || precision == .automatic || precision == .windows100ns
        case "tar": return kind == "m" || (kind == "a" && ["pax", "posix"].contains(method.lowercased()))
        case "gzip": return kind == "m"
        default: return false
        }
    }
    private static let formats = ["7z", "zip", "tar", "gzip", "bzip2", "xz", "wim"]
    private static func base(_ operation: String) -> [String] {
        // The GUI's chosen URL is exact, including valid names without an extension.
        // Otherwise update commands append .7z/.zip and readback uses the wrong file.
        [operation, "-y", "-bso1", "-bse2", "-bsp1", "-sccUTF-8", "-spd"] + (["a", "u", "d", "rn"].contains(operation) ? ["-sae"] : [])
    }
    private static func password(_ value: String) -> [String] { value.isEmpty ? [] : ["-p" + value] }
    public static func create(archive: URL, inputs: [URL], options: CompressionOptions) throws -> ArchiveCommand {
        guard !inputs.isEmpty else { throw ArchiveError.invalid("Choose at least one input.") }
        guard formats.contains(options.format.lowercased()) else { throw ArchiveError.invalid("Unsupported creation format: \(options.format)") }
        guard (0...9).contains(options.level), options.threads >= 0 else { throw ArchiveError.invalid("Compression level must be 0–9 and threads cannot be negative.") }
        if options.storeSymbolicLinks && !symbolicLinkFormats.contains(options.format.lowercased()) { throw ArchiveError.invalid("This format cannot preserve symbolic links.") }
        if options.storeHardLinks && !hardLinkFormats.contains(options.format.lowercased()) { throw ArchiveError.invalid("Hard-link preservation is supported only by TAR and WIM.") }
        let files = inputs.map { $0.standardizedFileURL }
        for input in files {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: input.path, isDirectory: &directory) else { throw ArchiveError.invalid("Input does not exist: \(input.path)") }
            let output = archive.standardizedFileURL.resolvingSymlinksInPath().path
            let path = input.resolvingSymlinksInPath().path
            if output == path || (directory.boolValue && output.hasPrefix(path + "/")) { throw ArchiveError.invalid("The output archive cannot be inside an input directory or replace an input.") }
            if ["gzip", "bzip2", "xz"].contains(options.format.lowercased()) && (files.count != 1 || directory.boolValue) { throw ArchiveError.invalid("This format requires exactly one regular input file.") }
        }
        var parent = files[0].deletingLastPathComponent()
        while files.contains(where: { !$0.path.hasPrefix(parent.path == "/" ? "/" : parent.path + "/") }) { parent.deleteLastPathComponent() }
        var args = base(options.updateMode == .add ? "a" : "u") + ["-t" + options.format.lowercased(), "-mx=\(options.level)"]
        switch options.updateMode {
        case .add, .update: break
        case .freshen: args.append("-up1q1r0x1y2z1w2")
        case .synchronize: args.append("-up1q0r2x1y2z1w2")
        }
        let format = options.format.lowercased()
        if !options.method.isEmpty { args.append((format == "7z" ? "-m0=" : "-mm=") + options.method) }
        if !options.dictionary.isEmpty { try validateSize(options.dictionary); args.append((format == "7z" ? "-m0d=" : "-md=") + options.dictionary) }
        if !options.wordSize.isEmpty { guard Int(options.wordSize) != nil else { throw ArchiveError.invalid("Word size must be a number.") }; args.append((format == "7z" ? "-m0fb=" : "-mfb=") + options.wordSize) }
        if format == "7z" { args.append("-ms=" + options.solid) }
        if options.threads > 0 { args.append("-mmt=\(options.threads)") }
        if !options.volumeSize.isEmpty { try validateSize(options.volumeSize); args.append("-v" + options.volumeSize) }
        if !options.password.isEmpty {
            guard ["7z", "zip"].contains(format) else { throw ArchiveError.invalid("Password encryption is supported for 7z and ZIP creation.") }
            args += password(options.password)
            if format == "zip", !options.password.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7f }) { throw ArchiveError.invalid("The official ZIP encryption handler supports ASCII passwords only. Use 7z for a Unicode password.") }
            if format == "zip" { guard ["AES256", "AES192", "AES128", "ZipCrypto"].contains(options.encryptionMethod) else { throw ArchiveError.invalid("Invalid ZIP encryption method.") }; args.append("-mem=" + options.encryptionMethod) }
            if format == "7z" { args.append(options.encryptHeaders ? "-mhe=on" : "-mhe=off") }
        } else if options.encryptHeaders { throw ArchiveError.invalid("Header encryption requires a password.") }
        guard timePrecisions(format: format, method: options.method).contains(options.timePrecision) else { throw ArchiveError.invalid("This archive format does not support the selected time precision.") }
        if options.timePrecision != .automatic { args.append("-mtp=\(options.timePrecision.rawValue)") }
        for (kind, storage) in [("m", options.modificationTime), ("c", options.creationTime), ("a", options.accessTime)] {
            if storage != .automatic {
                guard supportsTimestamp(kind, format: format, method: options.method, precision: options.timePrecision) else { throw ArchiveError.invalid("This format, method, and precision cannot store the selected timestamp.") }
                args.append("-mt" + kind + "=" + (storage == .store ? "on" : "off"))
            }
        }
        if options.setArchiveTimeToLatest { args.append("-stl") }
        if !options.memoryLimit.isEmpty {
            guard supportsMemoryLimit(format: format) else { throw ArchiveError.invalid("This archive format does not expose a compression memory budget.") }
            let budget = options.memoryLimit.lowercased()
            if budget.hasPrefix("p") {
                guard let percent = Int(budget.dropFirst()), (1...100).contains(percent) else { throw ArchiveError.invalid("Memory percentage must be p1 through p100.") }
            } else {
                guard budget.range(of: "^[1-9][0-9]*[bkmgt]$", options: .regularExpression) != nil else { throw ArchiveError.invalid("Memory budget must be a percentage (p60) or positive size (512m).") }
            }
            args.append("-mmemuse=" + budget)
        }
        switch options.pathMode { case .relative: break; case .full: args.append("-spf2"); case .absolute: args.append("-spf") }
        if options.compressShared { args.append("-ssw") }
        if options.storeSymbolicLinks { args.append("-snl") }
        if options.storeHardLinks { args.append("-snh") }
        if options.preserveAccessTime { args.append("-ssp") }
        if options.deleteSourcesAfterCompression { args.append("-sdel") }
        for exclusion in options.exclusions { try validateText(exclusion); args.append("-xr!" + exclusion) }
        for parameter in try tokenize(options.parameters) {
            // Method switches are allowed; IO, path handling, list files, and stdin switches are controlled by the app.
            guard parameter.hasPrefix("-m"), !parameter.contains("\0") else { throw ArchiveError.invalid("Advanced parameters accept compression method switches (-m…) only.") }
            args.append(parameter)
        }
        args += ["--", archive.standardizedFileURL.path]
        args += options.pathMode == .relative ? files.map { "./" + String($0.path.dropFirst(parent.path == "/" ? 1 : parent.path.count + 1)) } : files.map(\.path)
        return ArchiveCommand(arguments: args, workingDirectory: parent)
    }
    public static func extract(archive: URL, options: ExtractionOptions) throws -> ArchiveCommand {
        for path in options.selectedPaths { if options.remapAbsolutePaths { _ = try remappedArchivePath(path) } else { try validateMember(path) } }
        let overwrite: String
        switch options.overwrite { case .skip: overwrite = "-aos"; case .overwrite: overwrite = "-aoa"; case .renameExtracted: overwrite = "-aou"; case .renameExisting: overwrite = "-aot"; case .ask: throw ArchiveError.invalid("Ask overwrite requires SevenZipEngine.extract with a conflict resolver.") }
        var args = base(options.fullPaths ? "x" : "e") + [overwrite, "-spod", "-o" + options.destination.standardizedFileURL.path] + password(options.password) + options.openMode.arguments
        if options.eliminateDuplicateRoot && options.fullPaths { args.append("-spe") }
        // Explicit include switches preserve leading @, -, and wildcard characters as literal member names.
        args += options.selectedPaths.map { "-i!" + $0 }
        args += ["--", archive.standardizedFileURL.path]
        return ArchiveCommand(arguments: args)
    }
    public static func test(archive: URL, password: String = "", openMode: ArchiveOpenMode = .automatic) -> ArchiveCommand { ArchiveCommand(arguments: base("t") + self.password(password) + openMode.arguments + ["--", archive.standardizedFileURL.path]) }
    public static func delete(archive: URL, paths: [String], password: String = "") throws -> ArchiveCommand {
        guard !paths.isEmpty else { throw ArchiveError.invalid("Choose members to delete.") }
        for path in paths { _ = try remappedArchivePath(path) }
        return ArchiveCommand(arguments: base("d") + self.password(password) + paths.map { "-i!" + $0 } + ["--", archive.standardizedFileURL.path])
    }
    public static func rename(archive: URL, from: String, to: String, password: String = "") throws -> ArchiveCommand {
        _ = try remappedArchivePath(from); _ = try remappedArchivePath(to)
        return ArchiveCommand(arguments: base("rn") + self.password(password) + ["--", archive.standardizedFileURL.path, from, to])
    }
    public static func hash(inputs: [URL], method: String = "SHA256") throws -> ArchiveCommand {
        guard !inputs.isEmpty, ["CRC32", "CRC64", "XXH64", "MD5", "SHA1", "SHA256", "SHA384", "SHA512", "SHA3-256", "BLAKE2sp", "*"].contains(method) else { throw ArchiveError.invalid("Choose inputs and a supported hash method.") }
        return ArchiveCommand(arguments: base("h") + ["-scrc" + method, "--"] + inputs.map { $0.standardizedFileURL.path })
    }
    public static func benchmark(threads: Int = 0, dictionary: String = "") throws -> ArchiveCommand {
        guard threads >= 0 else { throw ArchiveError.invalid("Threads cannot be negative.") }
        var args = base("b")
        if threads > 0 { args.append("-mmt=\(threads)") }
        if !dictionary.isEmpty { try validateSize(dictionary); args.append("-md=" + dictionary) }
        return ArchiveCommand(arguments: args)
    }
    /// Only names are remapped; selectors passed to 7zz always retain the original literal name.
    public static func remappedArchivePath(_ original: String) throws -> String {
        try validateText(original)
        var path = original.replacingOccurrences(of: "\\", with: "/")
        if path.hasPrefix("//") { path = "UNC/" + path.drop(while: { $0 == "/" }) }
        else if path.count >= 3, path[path.index(after: path.startIndex)] == ":", path[path.index(path.startIndex, offsetBy: 2)] == "/", path.first!.isASCII, path.first!.isLetter { path = String(path.first!) + "/" + path.dropFirst(3) }
        else { path = String(path.drop(while: { $0 == "/" })) }
        while path.hasSuffix("/") { path.removeLast() }
        try validateMember(path)
        return path
    }
    static func validateMember(_ path: String) throws {
        try validateText(path)
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !normalized.hasPrefix("/"), !normalized.hasPrefix("~"), !parts.contains(".."), !parts.contains(""), !path.contains(":"), normalized != "." else { throw ArchiveError.invalid("Unsafe archive path: \(path)") }
    }
    private static func validateText(_ text: String) throws { guard !text.isEmpty, !text.contains("\0"), !text.contains("\n"), !text.contains("\r") else { throw ArchiveError.invalid("Empty names and control characters are not supported.") } }
    private static func validateSize(_ size: String) throws {
        guard size.range(of: "^[1-9][0-9]*[bBkKmMgG]?$", options: .regularExpression) != nil else { throw ArchiveError.invalid("Size must be positive, optionally followed by B, K, M, or G.") }
    }
    private static func tokenize(_ text: String) throws -> [String] {
        var values: [String] = [], value = "", quote: Character?, escaped = false
        for character in text {
            if escaped { value.append(character); escaped = false }
            else if character == "\\" { escaped = true }
            else if let current = quote { if character == current { quote = nil } else { value.append(character) } }
            else if character == "\"" || character == "'" { quote = character }
            else if character.isWhitespace { if !value.isEmpty { values.append(value); value = "" } }
            else { value.append(character) }
        }
        guard quote == nil, !escaped else { throw ArchiveError.invalid("Unterminated quote in advanced parameters.") }
        if !value.isEmpty { values.append(value) }
        return values
    }
}
