import AppKit
import FinderSync
import Darwin
import OSLog

@objc(SevenZipFinderSync)
final class SevenZipFinderSync: FIFinderSync {
    private let logger = Logger(subsystem: "local.sevenzip.mac.finder", category: "MenuAction")
    private let actions = [("Open", "open"), ("Add to archive…", "add"), ("Compress to 7z", "quick7z"), ("Compress to ZIP", "quickZip"), ("Extract…", "extract"), ("Extract here", "extractHere"), ("Extract to folder", "extractFolder"), ("Test archive", "test"), ("Checksums…", "hash"), ("Compress and email…", "email")]
    private static let catalog: [String: String] = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Localization/zh-Hans.json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return catalog
    }()
    private func selectedLanguage() -> String {
        // Refresh the containing app's preferences for every new menu, including
        // when this extension process was launched before the language changed.
        let domain = "local.sevenzip.mac" as CFString
        CFPreferencesAppSynchronize(domain)
        let code = CFPreferencesCopyAppValue("uiLanguage" as CFString, domain) as? String ?? "zh-Hans"
        return ["zh-Hans", "zh-Hant", "en"].contains(code) ? code : "zh-Hans"
    }
    private func localized(_ value: String, language: String) -> String {
        if language == "en" { return value }
        let text = Self.catalog[value] ?? value
        return language == "zh-Hant" ? text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text : text
    }
    override init() {
        super.init()
        // Foundation's homeDirectoryForCurrentUser is the extension container
        // under App Sandbox; monitor the actual user's Finder folders instead.
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir }.map { URL(fileURLWithPath: String(cString: $0), isDirectory: true) }
        var roots: Set<URL> = [URL(fileURLWithPath: "/Volumes", isDirectory: true)]
        if let home { roots.insert(home) }
        FIFinderSyncController.default().directoryURLs = roots
    }
    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let language = selectedLanguage()
        let menu = NSMenu(title: "7zip")
        let root = NSMenuItem(title: "7zip", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "7zip")
        for (index, entry) in actions.enumerated() {
            let (title, _) = entry
            let item = NSMenuItem(title: localized(title, language: language), action: #selector(performAction(_:)), keyEquivalent: "")
            // Finder reconstructs these items across XPC. Use the supported
            // integer tag, not representedObject, to identify the action.
            item.target = self; item.tag = index + 1; submenu.addItem(item)
        }
        root.submenu = submenu; menu.addItem(root); return menu
    }
    @objc private func performAction(_ sender: NSMenuItem) {
        guard (1...actions.count).contains(sender.tag) else {
            logger.error("Rejected menu action: invalid tag \(sender.tag, privacy: .public)")
            return
        }
        let action = actions[sender.tag - 1].1
        // Finder only guarantees this context inside menu(for:) and its action
        // callbacks. Read it synchronously, before handing off to the app.
        let controller = FIFinderSyncController.default()
        let selection = controller.selectedItemURLs() ?? []
        let selected = selection.isEmpty ? controller.targetedURL().map { [$0] } ?? [] : selection
        let files = selected.filter { $0.isFileURL }
        guard !files.isEmpty else {
            logger.error("Cannot dispatch \(action, privacy: .public): no Finder file context; selection count \(selection.count, privacy: .public)")
            return
        }
        var parts = URLComponents(); parts.scheme = "sevenzipmac"; parts.host = action
        parts.queryItems = files.map { URLQueryItem(name: "path", value: $0.path) }
        guard let url = parts.url else {
            logger.error("Cannot encode \(action, privacy: .public) route for \(files.count, privacy: .public) files")
            return
        }
        // Log only action/count/result; selected paths may contain private data.
        if NSWorkspace.shared.open(url) {
            logger.notice("Dispatched \(action, privacy: .public) for \(files.count, privacy: .public) files (tag \(sender.tag, privacy: .public))")
        } else {
            logger.error("Launch Services refused \(action, privacy: .public) route for \(files.count, privacy: .public) files")
        }
    }
}
