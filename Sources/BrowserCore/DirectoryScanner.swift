import Foundation

public enum DirectoryScanner {
    public static let rawExtensions: Set<String> = ["arw", "dng", "cr2", "cr3", "nef", "nrw", "raf", "orf", "rw2", "pef", "srw", "raw"]
    public static let renderedExtensions: Set<String> = ["hif", "heic", "heif", "jpg", "jpeg", "png", "tif", "tiff"]

    public static func scan(_ directory: URL) throws -> [PhotoAsset] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        var families: [String: [PhotoFile]] = [:]
        var names: [String: String] = [:]
        for url in urls {
            let ext = url.pathExtension.lowercased()
            let kind: PhotoKind
            if rawExtensions.contains(ext) { kind = .raw }
            else if renderedExtensions.contains(ext) { kind = .rendered }
            else if ext == "xmp" { kind = .sidecar }
            else { continue }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }
            var stem = url.deletingPathExtension().lastPathComponent
            if kind == .sidecar {
                let nested = URL(fileURLWithPath: stem)
                if rawExtensions.union(renderedExtensions).contains(nested.pathExtension.lowercased()) {
                    stem = nested.deletingPathExtension().lastPathComponent
                }
            }
            let id = stem.lowercased()
            names[id] = names[id] ?? stem
            families[id, default: []].append(PhotoFile(url: url, kind: kind, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast))
        }
        return families.compactMap { id, files in
            guard files.contains(where: { $0.kind != .sidecar }) else { return nil }
            return PhotoAsset(id: id, name: names[id]!, files: files.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent })
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
