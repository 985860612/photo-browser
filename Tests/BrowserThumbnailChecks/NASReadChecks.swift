import Foundation
import BrowserCore

/// Opt-in real-share regression: fresh caches force all three browsing paths to overlap.
/// swift run -c release -Xswiftc -enable-testing BrowserThumbnailChecks --nas-read-check <directory> <JPEG names...>
extension ThumbnailChecks {
    private struct NASRequest: Sendable {
        let file: PhotoFile
        let kind: Int
    }
    private struct NASSample: Sendable {
        let file: String
        let kind: String
        let milliseconds: Double
        let width: Int?
        let height: Int?
    }

    static func nasReadChecks(_ arguments: [String]) async throws {
        guard arguments.count >= 2 else {
            throw BrowserFailure.message("Usage: --nas-read-check <directory> <JPEG names...>")
        }
        let root = URL(fileURLWithPath: arguments[0], isDirectory: true)
        let files = try arguments.dropFirst().map { name -> PhotoFile in
            guard URL(fileURLWithPath: name).lastPathComponent == name,
                  ["jpg", "jpeg"].contains(URL(fileURLWithPath: name).pathExtension.lowercased()) else {
                throw BrowserFailure.message("Expected a JPEG filename: \(name)")
            }
            let url = root.appendingPathComponent(name)
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize,
                  size <= NetworkPhotoReader.maximumBufferedBytes, let modified = values.contentModificationDate else {
                throw BrowserFailure.message("Expected a regular JPEG of at most 32 MiB: \(name)")
            }
            return PhotoFile(url: url, kind: .rendered, size: Int64(size), modified: modified)
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("NASReadChecks-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let started = ProcessInfo.processInfo.systemUptime
        var samples: [NASSample] = []
        for round in 0..<2 {
            let thumbnails = ThumbnailCache(directory: temp.appendingPathComponent("round-\(round)"))
            let display = DisplayPhotoCache()
            let requests = files.flatMap { file in (0..<3).map { NASRequest(file: file, kind: $0) } }
            let current = try await withThrowingTaskGroup(of: NASSample.self) { group in
                var next = 0, results: [NASSample] = []
                func enqueue() {
                    guard next < requests.count else { return }
                    let request = requests[next]; next += 1
                    group.addTask {
                        let begin = ProcessInfo.processInfo.systemUptime
                        let metadata: PhotoMetadata?
                        let kind: String
                        switch request.kind {
                        case 0:
                            kind = "display"
                            let photo = try await display.image(request.file, hdr: true, maximum: 2800)
                            guard photo.size.width > 0, photo.size.height > 0 else {
                                throw BrowserFailure.message("Empty display image")
                            }
                            metadata = photo.metadata
                        case 1:
                            kind = "thumbnail"
                            let preview = try await thumbnails.image(request.file, maximum: 520)
                            guard preview.image.size.width > 0, preview.image.size.height > 0 else {
                                throw BrowserFailure.message("Empty thumbnail")
                            }
                            metadata = preview.metadata
                        default:
                            kind = "metadata"
                            metadata = try await thumbnails.sourceMetadata(request.file)
                        }
                        guard let width = metadata?.width, let height = metadata?.height, width > 0, height > 0 else {
                            throw BrowserFailure.message("Missing original dimensions: \(request.file.url.lastPathComponent)")
                        }
                        return NASSample(file: request.file.url.lastPathComponent, kind: kind,
                                         milliseconds: (ProcessInfo.processInfo.systemUptime - begin) * 1000,
                                         width: width, height: height)
                    }
                }
                for _ in 0..<min(4, requests.count) { enqueue() }
                while let result = try await group.next() {
                    let record: [String: Any] = ["round": round, "file": result.file, "kind": result.kind,
                                               "milliseconds": result.milliseconds]
                    print(String(data: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), encoding: .utf8)!)
                    fflush(stdout)
                    results.append(result); enqueue()
                }
                return results
            }
            for file in files {
                let values = current.filter { $0.file == file.url.lastPathComponent }
                guard values.count == 3, Set(values.compactMap(\.width)).count == 1,
                      Set(values.compactMap(\.height)).count == 1 else {
                    throw BrowserFailure.message("Preview and EXIF dimensions disagree: \(file.url.lastPathComponent)")
                }
            }
            samples += current
        }
        let durations = samples.map(\.milliseconds).sorted()
        let summary: [String: Any] = ["requests": samples.count, "maximum_ms": durations.last ?? 0,
                                      "p50_ms": durations[durations.count / 2],
                                      "p95_ms": durations[Int(Double(durations.count - 1) * 0.95)],
                                      "over_2_seconds": durations.filter { $0 >= 2000 }.count,
                                      "elapsed_seconds": ProcessInfo.processInfo.systemUptime - started]
        print(String(data: try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]), encoding: .utf8)!)
        guard durations.allSatisfy({ $0 < 2000 }) else {
            throw BrowserFailure.message("NAS preview regression: one or more requests took at least 2 seconds")
        }
        print("PASS concurrent NAS display, thumbnail and EXIF reads with fresh caches")
    }
}
