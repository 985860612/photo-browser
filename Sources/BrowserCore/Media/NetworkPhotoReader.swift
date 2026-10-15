import Foundation
import ImageIO

/// Buffer small network JPEGs once; large files and other codecs retain ImageIO's URL reader.
public enum NetworkPhotoReader {
    public static let maximumBufferedBytes = 32 * 1024 * 1024
    private static let lock = NSLock()
    private static var volumes: [String: Bool] = [:]

    public static func open(_ file: PhotoFile, buffered: Bool? = nil,
                            check: () throws -> Void = {}) throws -> CGImageSource? {
        try check()
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        let jpeg = ["jpg", "jpeg"].contains(file.url.pathExtension.lowercased())
        if jpeg, file.size <= maximumBufferedBytes, buffered ?? isNetwork(file.url) {
            let input = try FileHandle(forReadingFrom: file.url)
            defer { try? input.close() }
            var bytes = Data()
            while true {
                try check()
                guard let chunk = try input.read(upToCount: min(256 * 1024, maximumBufferedBytes + 1 - bytes.count)), !chunk.isEmpty else { break }
                bytes.append(chunk)
                if bytes.count > maximumBufferedBytes {
                    // A file growing since the directory snapshot still cannot create an unbounded buffer.
                    try check(); return CGImageSourceCreateWithURL(file.url as CFURL, options)
                }
            }
            try check(); return CGImageSourceCreateWithData(bytes as CFData, options)
        }
        return CGImageSourceCreateWithURL(file.url as CFURL, options)
    }

    private static func isNetwork(_ url: URL) -> Bool {
        let parts = url.pathComponents
        let root = parts.count > 2 && parts[1] == "Volumes" ? "/Volumes/" + parts[2] : "/"
        lock.lock(); let cached = volumes[root]; lock.unlock()
        if let cached { return cached }
        let remote = (try? URL(fileURLWithPath: root).resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == false
        lock.lock(); volumes[root] = remote; lock.unlock()
        return remote
    }
}
