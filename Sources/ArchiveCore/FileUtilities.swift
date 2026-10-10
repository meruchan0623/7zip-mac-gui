import Foundation
import Darwin

public enum FileUtilities {
    private static let chunk = 1024 * 1024
    public static func split(file: URL, destination: URL, volumeBytes: UInt64, control: OperationControl, onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [URL] {
        try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .userInitiated) {
                guard volumeBytes > 0 else { throw ArchiveError.invalid("Volume size must be greater than zero.") }
                let size = try regularFileSize(file)
                guard size > 0 else { throw ArchiveError.invalid("Cannot split an empty file.") }
                try control.checkpoint()
                let directory = destination.resolvingSymlinksInPath()
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw ArchiveError.invalid("Split destination must be an existing directory.") }
                let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
                var outputs: [URL] = [], done: UInt64 = 0, index = 1
                do {
                    while done < size {
                        try control.checkpoint()
                        let url = directory.appendingPathComponent(file.lastPathComponent + String(format: ".%03d", index))
                        let output = try exclusiveFile(url); outputs.append(url)
                        do {
                            var remaining = min(volumeBytes, size - done)
                            while remaining > 0 {
                                try control.checkpoint()
                                guard let data = try input.read(upToCount: Int(min(UInt64(chunk), remaining))), !data.isEmpty else { throw ArchiveError.io("Input changed or became unreadable during split.") }
                                try output.write(contentsOf: data); done += UInt64(data.count); remaining -= UInt64(data.count)
                                onProgress(Double(done) / Double(size))
                            }
                            try output.synchronize(); try output.close()
                        } catch { try? output.close(); throw error }
                        index += 1
                    }
                    if let extra = try input.read(upToCount: 1), !extra.isEmpty { throw ArchiveError.io("Input grew during split.") }
                    try control.checkpoint(); return outputs
                } catch { for url in outputs { try? FileManager.default.removeItem(at: url) }; throw error }
            }.value
        }, onCancel: { control.cancel() })
    }
    public static func combine(firstVolume: URL, output: URL, control: OperationControl, onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .userInitiated) {
                try control.checkpoint()
                let ext = firstVolume.pathExtension
                guard ext.count >= 3, Int(ext) == 1 else { throw ArchiveError.invalid("Choose the first numbered volume (.001).") }
                let directory = firstVolume.deletingLastPathComponent(), prefix = firstVolume.deletingPathExtension().lastPathComponent + "."
                let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                var volumes: [Int: URL] = [:]
                for child in children where child.lastPathComponent.hasPrefix(prefix) {
                    let suffix = String(child.lastPathComponent.dropFirst(prefix.count))
                    guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber), let number = Int(suffix) else { continue }
                    guard number > 0, volumes[number] == nil else { throw ArchiveError.invalid("Ambiguous numbered volumes.") }
                    volumes[number] = child
                }
                guard let maximum = volumes.keys.max(), maximum == volumes.count, volumes[1]?.standardizedFileURL == firstVolume.standardizedFileURL else { throw ArchiveError.invalid("A numbered volume is missing.") }
                var sizes: [UInt64] = [], total: UInt64 = 0
                for index in 1...maximum {
                    let size = try regularFileSize(volumes[index]!)
                    guard size > 0 else { throw ArchiveError.invalid("A volume is empty.") }
                    let (sum, overflow) = total.addingReportingOverflow(size)
                    guard !overflow else { throw ArchiveError.invalid("Combined file is too large.") }
                    total = sum; sizes.append(size)
                }
                guard sizes.dropLast().allSatisfy({ $0 == sizes[0] }), sizes.last! <= sizes[0] else { throw ArchiveError.invalid("Volume sizes indicate a missing or truncated volume.") }
                let temp = output.deletingLastPathComponent().appendingPathComponent(".sevenzip-combine-" + UUID().uuidString)
                let target = try exclusiveFile(temp)
                defer { try? target.close(); try? FileManager.default.removeItem(at: temp) }
                var done: UInt64 = 0
                for index in 1...maximum {
                    try control.checkpoint()
                    let source = try FileHandle(forReadingFrom: volumes[index]!)
                    do {
                        var read: UInt64 = 0
                        while let data = try source.read(upToCount: chunk), !data.isEmpty {
                            try control.checkpoint(); read += UInt64(data.count)
                            guard read <= sizes[index - 1] else { throw ArchiveError.io("A volume changed during combine.") }
                            try target.write(contentsOf: data); done += UInt64(data.count); onProgress(Double(done) / Double(total))
                        }
                        guard read == sizes[index - 1] else { throw ArchiveError.io("A volume changed during combine.") }
                        try source.close()
                    } catch { try? source.close(); throw error }
                }
                try target.synchronize(); try target.close(); try control.checkpoint()
                // link() atomically publishes without replacing any file, including a dangling symlink.
                guard Darwin.link(temp.path, output.path) == 0 else { throw ArchiveError.io("Cannot publish combined file (destination may already exist): \(String(cString: strerror(errno)))") }
                try? FileManager.default.removeItem(at: temp)
                return output
            }.value
        }, onCancel: { control.cancel() })
    }
    private static func exclusiveFile(_ url: URL) throws -> FileHandle {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw ArchiveError.io("Cannot create \(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    private static func regularFileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular, let size = attributes[.size] as? NSNumber else { throw ArchiveError.invalid("Choose a regular file: \(url.lastPathComponent)") }
        return size.uint64Value
    }
}
