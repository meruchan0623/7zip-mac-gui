import AppKit

@main
struct IntegrationCheck {
    static func main() {
        _ = NSApplication.shared
        var received: [(IntegrationAction, [URL])] = []
        let integration = SystemIntegration { received.append(($0, $1)) }
        func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
        let paths = ["/tmp/中文 空格 & # %.txt", "/tmp/another.txt"]
        var route = URLComponents(); route.scheme = "sevenzipmac"; route.host = "quickZip"
        route.queryItems = paths.map { URLQueryItem(name: "path", value: $0) }
        integration.handle(urls: [route.url!]); drain()
        precondition(received.count == 1 && received[0].0 == .quickZip && received[0].1.map(\.path) == paths)
        for value in ["sevenzipmac://unknown?path=/tmp/x", "sevenzipmac://open?path=relative", "sevenzipmac://open?path=/tmp/x&other=bad", "sevenzipmac://open?path=/tmp/x#frag", "sevenzipmac://user@open?path=/tmp/x", "https://open?path=/tmp/x", "sevenzipmac://open?path=%00"] {
            integration.handle(urls: [URL(string: value)!])
        }
        drain(); precondition(received.count == 1)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects(paths.map { NSURL(fileURLWithPath: $0) })
        var error: NSString?
        integration.performAction(pasteboard, userData: "add", error: &error); drain()
        precondition(error == nil && received.last!.0 == .add && received.last!.1.map(\.path) == paths)
        pasteboard.clearContents()
        pasteboard.setPropertyList(paths, forType: .init("NSFilenamesPboardType"))
        integration.performAction(pasteboard, userData: "extractHere", error: &error); drain()
        precondition(error == nil && received.last!.0 == .extractHere && received.last!.1.map(\.path) == paths)
        pasteboard.clearContents()
        integration.performAction(pasteboard, userData: "test", error: &error)
        precondition(error != nil)
        precondition(integration.responds(to: NSSelectorFromString("performAction:userData:error:")))
        print("PASS: Unicode multi-file URL routing; malformed routes rejected; file URL and legacy Services pasteboards; Objective-C selector")
    }
}

// This standalone routing check does not construct localized UI. Production
// provides L from Localization.swift, which has its own catalog checks.
func L(_ value: String) -> String { value.replacingOccurrences(of:"SevenZip Mac",with:"7zip Mac") }
