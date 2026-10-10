import Foundation
import ArchiveCore

struct FileTransferOutcome { var completed: [URL] = []; var skipped: [URL] = []; var outputs: [String: URL] = [:] }
/// Implements folder merging and leaf conflicts without following destination links.
/// Completed files remain if a later item fails or the operation is cancelled.
final class FileTransferExecutor {
    let inputs: [URL]
    let destination: URL
    let move: Bool
    let preserveLinkGraph: Bool
    let control: OperationControl
    let decide: ExtractionConflictResolver
    let report: @Sendable (String) -> Void
    var all: ExtractionConflictAction?
    var outcome = FileTransferOutcome()
    init(inputs: [URL], destination: URL, move: Bool, preserveLinkGraph: Bool = false, control: OperationControl, decide: @escaping ExtractionConflictResolver, report: @escaping @Sendable (String) -> Void) {
        self.inputs = inputs; self.destination = destination; self.move = move; self.preserveLinkGraph = preserveLinkGraph; self.control = control; self.decide = decide; self.report = report
    }
    func run() async throws -> FileTransferOutcome {
        try FileTransferPlan.validate(inputs:inputs,destination:destination,allowConflicts:true)
        for input in inputs { try await transfer(input,to:destination.appendingPathComponent(input.lastPathComponent)) }
        try cancelled()
        if preserveLinkGraph && outcome.skipped.isEmpty { try rewriteTransferredLinks(inputs:inputs,mapping:outcome.outputs) }
        try cancelled()
        return outcome
    }
    func cancelled() throws { try control.checkpoint() }
    func exists(_ url: URL) -> Bool { (try? FileManager.default.attributesOfItem(atPath:url.path)) != nil }
    func available(_ requested: URL) -> URL {
        let parent = requested.deletingLastPathComponent(), ext = requested.pathExtension, stem = requested.deletingPathExtension().lastPathComponent
        let keys = Set(((try? FileManager.default.contentsOfDirectory(atPath:parent.path)) ?? []).map { $0.precomposedStringWithCanonicalMapping.lowercased() })
        var n = 1
        while true {
            let name = stem + "_" + String(n) + (ext.isEmpty ? "" : "." + ext); let value = parent.appendingPathComponent(name)
            if !keys.contains(name.precomposedStringWithCanonicalMapping.lowercased()),!exists(value),!SHA256Manifest.wouldReplaceInput(output:value,inputs:inputs) { return value }; n += 1
        }
    }
    func transfer(_ source: URL, to requested: URL) async throws {
        try cancelled(); let manager = FileManager.default
        var target = requested
        let sourceValues = try source.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        let targetValues = try? target.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        if sourceValues.isDirectory == true,sourceValues.isSymbolicLink != true,targetValues?.isDirectory == true,targetValues?.isSymbolicLink != true {
            for child in try manager.contentsOfDirectory(at:source,includingPropertiesForKeys:nil) { try await transfer(child,to:target.appendingPathComponent(child.lastPathComponent)) }
            if move,(try manager.contentsOfDirectory(atPath:source.path)).isEmpty { try manager.removeItem(at:source) }
            outcome.outputs[source.path] = target
            return
        }
        if exists(target) {
            guard !SHA256Manifest.wouldReplaceInput(output:target,inputs:inputs) else { throw UIError(message:"A destination aliases a selected source. The source was retained.") }
            let action: ExtractionConflictAction
            if let all { action = all }
            else { let choice = await decide(ExtractionConflict(archivePath:source.path,destination:target,isDirectory:sourceValues.isDirectory == true)); action = choice.action; if choice.applyToAll { all = action } }
            try cancelled()
            switch action {
            case .cancel: throw ArchiveError.cancelled
            case .skip: outcome.skipped.append(source); report("Skipped: " + source.path + "\n"); return
            case .renameExtracted: target = available(target)
            case .renameExisting: try manager.moveItem(at:target,to:available(target))
            case .overwrite: try manager.trashItem(at:target,resultingItemURL:nil)
            }
        }
        try cancelled()
        if move { try manager.moveItem(at:source,to:target) }
        else { try manager.copyItem(at:source,to:target); try verifyTransferredItem(source,target) }
        outcome.outputs[source.path] = target
        outcome.completed.append(target); report(target.path + "\n")
    }
}
