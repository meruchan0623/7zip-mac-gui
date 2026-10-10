import Foundation
import ArchiveCore

/// Explicit English message keys are shared by the application and Finder extension.
/// File paths, engine output and command switches are never localized.
enum Localization {
    static let didChange = Notification.Name("SevenZipLanguageDidChange")
    static let supportedLanguages = ["zh-Hans", "zh-Hant", "en"]
    static var language: String {
        let value = UserDefaults.standard.string(forKey: "uiLanguage") ?? "zh-Hans"
        return supportedLanguages.contains(value) ? value : "zh-Hans"
    }
    static func setLanguage(_ code: String) {
        guard supportedLanguages.contains(code) else { return }
        UserDefaults.standard.set(code, forKey: "uiLanguage")
        // Make the new selection visible to the sandboxed Finder extension.
        CFPreferencesAppSynchronize("local.sevenzip.mac" as CFString)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
    private static let catalog: [String: String] = {
        let development = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Localization")
        let directories = [Bundle.main.resourceURL?.appendingPathComponent("Localization"), development].compactMap { $0 }
        for directory in directories {
            if let data = try? Data(contentsOf: directory.appendingPathComponent("zh-Hans.json")), let value = try? JSONDecoder().decode([String: String].self, from: data) { return value }
        }
        return [:]
    }()
    private static let templates: [(NSRegularExpression, String)] = catalog.sorted { $0.key.count > $1.key.count }.compactMap { key, value in
        guard key.contains("%@") else { return nil }
        let pattern = "^" + key.components(separatedBy: "%@").map(NSRegularExpression.escapedPattern(for:)).joined(separator: "([\\s\\S]*?)") + "$"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        return (expression, value)
    }
    private static func localizedTemplate(_ value: String, language: String) -> String {
        language == "zh-Hant" ? value.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? value : value
    }
    static func text(_ input: String) -> String {
        let selectedLanguage = language
        if selectedLanguage == "en" {
            // Branding applies only to registered static message keys. A path
            // or unknown diagnostic containing the old app name stays intact.
            return catalog[input] != nil ? input.replacingOccurrences(of: "SevenZip Mac", with: "7zip Mac") : input
        }
        if let value = catalog[input] { return localizedTemplate(value, language: selectedLanguage) }
        for (regex, template) in templates {
            guard let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) else { continue }
            // Convert only static translated pieces, before inserting raw paths,
            // filenames and diagnostics. Dynamic values must never be converted.
            let pieces = localizedTemplate(template, language: selectedLanguage).components(separatedBy: "%@")
            guard pieces.count == match.numberOfRanges else { continue }
            var result = pieces[0]
            for index in 1..<pieces.count {
                guard let range = Range(match.range(at: index), in: input) else { continue }
                result += String(input[range]) + pieces[index]
            }
            return result
        }
        return input
    }
    static func translate(error: Error) -> String {
        if let archive = error as? ArchiveError {
            switch archive {
            case .failed(let code, let log): return LF("7-Zip exited with code %@.", String(code)) + "\n" + log
            case .cancelled: return L("Operation cancelled.")
            case .invalid(let value), .io(let value): return L(value)
            }
        }
        return L(error.localizedDescription)
    }
}
func L(_ text: String) -> String { Localization.text(text) }
func LF(_ template: String, _ arguments: CVarArg...) -> String {
    String(format: L(template), locale: Locale(identifier: Localization.language), arguments: arguments)
}
