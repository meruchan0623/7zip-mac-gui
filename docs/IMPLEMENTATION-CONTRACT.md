# 7zip Mac implementation contract

Native AppKit on macOS 13+, Swift Package Manager, Swift 5 language mode. App name 7zip Mac, bundle ID `local.sevenzip.mac`. Engine 7zz 26.04 compiled from unmodified official source, tag `26.04`, revision `9128b80e3a471108678e2b3ec3c985861c8d7b0f`; original downloaded binary is separately preserved. No shell interpolation of paths/passwords. No telemetry. No default associations changed without an explicit in-app action. Source definitions are authoritative if this implementation overview lags later additions.

## Ownership

- Core worker: `Sources/ArchiveCore/**`, `Tests/ArchiveCoreTests/**`.
- UI worker: `Sources/SevenZipMac/**`, except `SystemIntegration.swift` (integration worker).
- Integration worker: `Sources/SevenZipMac/SystemIntegration.swift`, `FinderExtension/**`, `Resources/**`, `scripts/**`.
- Root: Package.swift, docs, README, review/integration fixes after coordination.

## ArchiveCore API (public; Foundation only)

`ArchiveEntry`: Identifiable, Hashable; `path: String`, `size: UInt64`, `packedSize: UInt64`, `isDirectory: Bool`, `modified: String`, `encrypted: Bool`, `properties: [String:String]`; id = path.

`ArchiveListing`: `entries: [ArchiveEntry]`, `properties: [String:String]`.

`CommandResult`: `output: String`, `exitCode: Int32`, `succeeded: Bool` (0), `warning: Bool` (1).

`ArchiveCommand`: `arguments: [String]`, `workingDirectory: URL?`, `redactedDescription: String`.

`OperationControl`: public init; cancel(), pause(), resume(); process lifecycle synchronized. Cancellation is terminal. Child stdin /dev/null to prevent hangs; passwords passed as a single argument and always redacted in logs/errors.

`SevenZipEngine`: init(binaryURL: URL); static locateBinary() throws -> URL (Bundle resources then SEVENZIP_BINARY env then current-directory 7zz); `run(_ command: ArchiveCommand, control: OperationControl, onOutput: @escaping @Sendable (String) -> Void = { _ in }) async throws -> CommandResult`; `list(archive: URL, password: String? = nil, control: OperationControl = OperationControl()) async throws -> ArchiveListing`. Reject fatal exit >=2, distinguish warning exit 1; list must be complete, so exit 1 fails listing. Public error localizedDescription. Reject unsafe archive paths on extraction including ../, absolute, symlink entries/ancestors unless safely handled. No arbitrary shell invocation.

`CompressionOptions`: public init(); mutable `format: String = "7z"`, `level: Int = 5`, `method: String = ""`, `dictionary: String = ""`, `wordSize: String = ""`, `solid: String = "on"`, `threads: Int = 0`, `volumeSize: String = ""`, `password: String = ""`, `encryptHeaders: Bool = false`, `encryptionMethod: String = "AES256"`, `updateMode: UpdateMode = .add`, `exclusions: [String] = []`, `parameters: String = ""`, `compressShared: Bool = false`.

`UpdateMode: String, CaseIterable`: add, update, freshen, synchronize.

`ExtractionOptions`: public init(destination: URL); mutable `destination: URL`, `fullPaths: Bool = true`, `overwrite: OverwriteMode = .skip`, `password: String = ""`, `selectedPaths: [String] = []`.

`OverwriteMode: String, CaseIterable`: skip, overwrite, renameExtracted, renameExisting.

`ArchiveCommands` public static methods (throw validation errors):
- `create(archive: URL, inputs: [URL], options: CompressionOptions) throws -> ArchiveCommand` (relative names rooted at common parent; reject output inside input directory; validate single-file formats)
- `extract(archive: URL, options: ExtractionOptions) throws -> ArchiveCommand`
- `test(archive: URL, password: String = "") -> ArchiveCommand`
- `delete(archive: URL, paths: [String], password: String = "") throws -> ArchiveCommand`
- `rename(archive: URL, from: String, to: String, password: String = "") throws -> ArchiveCommand`
- `hash(inputs: [URL], method: String = "SHA256") throws -> ArchiveCommand`
- `benchmark(threads: Int = 0, dictionary: String = "") throws -> ArchiveCommand`

`SevenZipEngine.extract(archive: URL, options: ExtractionOptions, control: OperationControl, onOutput: @escaping @Sendable (String)->Void = {_ in}) async throws -> CommandResult`: lists/preflights every entry and destination before writing; UI always uses this instead of raw extract run.

`FileUtilities`: static `split(file: URL, destination: URL, volumeBytes: UInt64, control: OperationControl, onProgress: @escaping @Sendable (Double)->Void = {_ in}) async throws -> [URL]`; `combine(firstVolume: URL, output: URL, control: OperationControl, onProgress: @escaping @Sendable (Double)->Void = {_ in}) async throws -> URL`; no silent overwrites, stream IO, validate gaps, clean own partials on cancel.

## App integration API

`IntegrationAction: String`: open, add, quick7z, quickZip, extract, extractHere, extractFolder, test, hash, email.

`SystemIntegration: NSObject`: `init(handler: @escaping (IntegrationAction, [URL]) -> Void)`, `install()` (Services provider and URL-event handler); `handle(urls: [URL])` (dispatch custom URLs or normal files). UI owns instance strongly. Finder uses `sevenzipmac://<action>?path=<percent-encoded-file-path>` repeated path params. Services uses NSPasteboard file URLs and legacy filenames.

`SystemIntegration.showIntegrationSettings()` static opens relevant macOS settings/help (no automatic toggle); `registerApplication()` static explicit in-app request; `setDefaultArchiveHandler()` static explicit in-app request.

UI AppDelegate forwards application(_:open:) to integration.handle(urls:); create MainWindowController before install. Functionally complete actions from both menu/toolbar and Finder routes, no placeholders. Main UI archive/file list with active pane, sidebar, list/flat views, search, breadcrumbs, progress/cancel/pause, advanced compression/extraction dialogs, editing with explicit archive update, checksums, split/combine, benchmark, history/favorites/settings/help. Confirm destructive archive delete/sync and local trash/move.

Build script creates `build/7zip Mac.app` with engine, manual, license, document types, services, optional Finder extension (ad-hoc signed locally; do not claim production signing/notarization). macOS Finder Services are the supported default integration; Finder Sync optional since Apple scopes it to sync apps. Need registration and real UI acceptance evidence separately.
