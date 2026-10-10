import AppKit
import UniformTypeIdentifiers
import CoreServices

public enum IntegrationAction: String, CaseIterable {
    case open, add, quick7z, quickZip, extract, extractHere, extractFolder, test, hash, email
}

final class SystemIntegration: NSObject {
    private let handler: (IntegrationAction, [URL]) -> Void
    init(handler: @escaping (IntegrationAction, [URL]) -> Void) { self.handler = handler; super.init() }

    func install() {
        NSApp.servicesProvider = self
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(receiveURL(_:reply:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        NSUpdateDynamicServices()
    }

    func handle(urls: [URL]) {
        let files = urls.filter { $0.isFileURL }.map { $0.standardizedFileURL }
        if !files.isEmpty { dispatch(.open, files) }
        for url in urls where !url.isFileURL {
            guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.scheme?.lowercased() == "sevenzipmac",
                  let name = parts.host, let action = IntegrationAction(rawValue: name),
                  parts.user == nil, parts.password == nil, parts.port == nil,
                  parts.path.isEmpty || parts.path == "/", parts.fragment == nil,
                  let query = parts.queryItems, !query.isEmpty,
                  query.allSatisfy({ $0.name == "path" && $0.value?.hasPrefix("/") == true && $0.value?.contains("\0") == false }) else { continue }
            dispatch(action, query.compactMap { $0.value.map { URL(fileURLWithPath: $0).standardizedFileURL } })
        }
    }

    @objc private func receiveURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        if let value = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue, let url = URL(string: value) { handle(urls: [url]) }
    }

    // NSMessage in Info.plist resolves to this three-argument Services selector.
    @objc func performAction(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let action = userData.flatMap(IntegrationAction.init(rawValue:)) else { error.pointee = L("Unknown SevenZip action") as NSString; return }
        var urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if urls.isEmpty, let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            urls = paths.filter { $0.hasPrefix("/") && !$0.contains("\0") }.map { URL(fileURLWithPath: $0) }
        }
        guard !urls.isEmpty else { error.pointee = L("Select one or more files in Finder.") as NSString; return }
        dispatch(action, urls)
    }

    private func dispatch(_ action: IntegrationAction, _ urls: [URL]) {
        let unique = Array(NSOrderedSet(array: urls.filter { $0.isFileURL }.map { $0.standardizedFileURL })) as? [URL] ?? []
        guard !unique.isEmpty else { return }
        DispatchQueue.main.async { [self] in NSApp.activate(ignoringOtherApps: true); handler(action, unique) }
    }

    static func showIntegrationSettings() {
        let alert = NSAlert()
        alert.messageText = L("Finder integration")
        alert.informativeText = L("Finder → right-click selected files → Services → 7zip. Services can be configured in Keyboard Shortcuts. The optional Finder extension adds a 7zip submenu; macOS controls whether the extension can load.")
        alert.addButton(withTitle: L("Enable Finder Submenu")); alert.addButton(withTitle: L("Services Settings")); alert.addButton(withTitle: L("Close"))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn { enableFinderExtension() }
        else if response == .alertSecondButtonReturn, let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts") { NSWorkspace.shared.open(url) }
    }

    static func enableFinderExtension() {
        let extensionURL = Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/SevenZipFinder.appex")
        guard FileManager.default.fileExists(atPath:extensionURL.path) else {
            let report = NSAlert(); report.messageText = L("Finder extension is not included in this build"); report.informativeText = L("Finder Services remain available."); report.runModal(); return
        }
        let bundleURL = Bundle.main.bundleURL
        Task {
            let message = await Task.detached { () -> String in
                LSRegisterURL(bundleURL as CFURL, true)
                do {
                    for arguments in [["-a",extensionURL.path],["-e","use","-i","local.sevenzip.mac.finder"]] {
                        let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath:"/usr/bin/pluginkit"); process.arguments = arguments
                        process.standardOutput = pipe; process.standardError = pipe; process.standardInput = FileHandle.nullDevice
                        try process.run(); let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                        guard process.terminationStatus == 0 else { return "macOS did not enable the extension: " + (String(data:output,encoding:.utf8) ?? "Unknown error") }
                    }
                    return "The enable request was accepted. Open a Finder folder and check its right-click menu for 7zip. If macOS does not load the extension, use the 7zip actions under Services."
                } catch { return error.localizedDescription }
            }.value
            await MainActor.run { let report = NSAlert(); report.messageText = L("Finder integration"); report.informativeText = L(message); report.runModal() }
        }
    }

    static func registerApplication() {
        let status = LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        NSUpdateDynamicServices()
        if status != noErr { let alert = NSAlert(); alert.messageText = L("Registration failed (\(status))"); alert.runModal() }
    }

    static func setDefaultArchiveHandler() {
        let alert = NSAlert(); alert.messageText = L("Use 7zip Mac for archive files?")
        alert.informativeText = L("This changes the default opener for supported archive types in your account.")
        alert.addButton(withTitle: L("Use 7zip Mac")); alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn, let bundleID = Bundle.main.bundleIdentifier else { return }
        let extensions = ["7z", "zip", "rar", "tar", "gz", "bz2", "xz", "lzma", "zst", "cab", "iso", "wim", "arj", "cpio", "rpm", "deb", "dmg"]
        var failures: [String] = []
        for ext in extensions {
            if let type = UTType(filenameExtension: ext), LSSetDefaultRoleHandlerForContentType(type.identifier as CFString, .viewer, bundleID as CFString) != noErr { failures.append(ext) }
        }
        if !failures.isEmpty { let report = NSAlert(); report.messageText = L("Some associations could not be changed"); report.informativeText = failures.joined(separator: ", "); report.runModal() }
    }
}
