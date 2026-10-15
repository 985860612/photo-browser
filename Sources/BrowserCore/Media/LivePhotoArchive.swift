import Foundation

/// Reads selected ZIP members through the system unzip tool; never extracts archive paths.
enum LivePhotoArchive {
    struct Members { let photo: String; let movie: String? }
    static func members(_ url: URL, check: () throws -> Void) throws -> Members {
        let listing = try run(["-Z1", url.path], limit: 1024 * 1024, check: check)
        guard let text = String(data: listing, encoding: .utf8) else { throw invalid(url) }
        let names = text.split(whereSeparator: \.isNewline).map(String.init).filter { name in
            !name.hasPrefix("/") && !name.hasPrefix("-") && !name.contains("\0") &&
            !name.split(separator: "/").contains("..") && !name.hasPrefix("__MACOSX/")
        }
        let photos = names.filter { DirectoryScanner.renderedExtensions.subtracting(["livp"]).contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
        let movies = names.filter { DirectoryScanner.videoExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
        guard !photos.isEmpty else { throw invalid(url) }
        let paired = photos.filter { photo in movies.contains { URL(fileURLWithPath: $0).deletingPathExtension().path == URL(fileURLWithPath: photo).deletingPathExtension().path } }
        let candidates = paired.isEmpty ? photos : paired
        guard candidates.count == 1 else { throw invalid(url) }
        let photo = candidates[0]
        let movie = movies.first { URL(fileURLWithPath: $0).deletingPathExtension().path == URL(fileURLWithPath: photo).deletingPathExtension().path }
            ?? (movies.count == 1 ? movies.first : nil)
        return Members(photo: photo, movie: movie)
    }

    static func extract(_ url: URL, member: String, to output: URL, limit: Int, check: () throws -> Void) throws {
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let pattern = member.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "?", with: "\\?").replacingOccurrences(of: "*", with: "\\*")
        _ = try run(["-p", url.path, pattern], limit: limit, check: check) { try handle.write(contentsOf: $0) }
    }

    private static func run(_ arguments: [String], limit: Int, check: () throws -> Void,
                            consume: ((Data) throws -> Void)? = nil) throws -> Data {
        try check()
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit(); try? pipe.fileHandleForReading.close() }
        var result = Data(), total = 0
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try check(); total += chunk.count
            guard total <= limit else { throw BrowserFailure.message(L10n.text("LIVP 内容超过缓存容量限制。")) }
            if let consume { try consume(chunk) } else { result.append(chunk) }
        }
        process.waitUntilExit(); try check()
        guard process.terminationStatus == 0, total > 0 else {
            throw BrowserFailure.message(L10n.text("无法读取 LIVP 文件，文件可能损坏或格式不受支持。"))
        }
        return result
    }
    private static func invalid(_ url: URL) -> Error {
        BrowserFailure.message(L10n.text("LIVP 中没有唯一可用的照片：\(url.lastPathComponent)"))
    }
}
