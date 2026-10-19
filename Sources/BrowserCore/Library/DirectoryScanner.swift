import Foundation

public enum DirectoryScanner {
    public static let rawExtensions: Set<String> = ["arw", "dng", "cr2", "cr3", "nef", "nrw", "raf", "orf", "rw2", "pef", "srw", "raw"]
    public static let renderedExtensions: Set<String> = ["hif", "heic", "heif", "avif", "jpg", "jpeg", "png", "tif", "tiff", "livp"]
    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    public static func scan(_ directory: URL, knownAssets: [PhotoAsset] = []) throws -> [PhotoAsset] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        var hints: [String: (PhotoAsset, PhotoFile)] = [:]
        for asset in knownAssets {
            for file in asset.imageFiles where file.url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path {
                hints[file.url.lastPathComponent] = (asset, file)
            }
        }
        var families: [String: [PhotoFile]] = [:]
        var names: [String: String] = [:]
        for url in urls {
            let ext = url.pathExtension.lowercased()
            let kind: PhotoKind
            var hint: (PhotoAsset, PhotoFile)?
            if rawExtensions.contains(ext) { kind = .raw }
            else if renderedExtensions.contains(ext) { kind = .rendered }
            else if videoExtensions.contains(ext) { kind = .video }
            else if ext == "xmp" { kind = .sidecar }
            else if !["psd", "psb"].contains(ext), let known = hints[url.lastPathComponent] { kind = known.1.kind; hint = known }
            else { continue }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }
            var stem = hint?.0.name ?? url.deletingPathExtension().lastPathComponent
            var id = hint?.0.id ?? (kind == .video ? "video:" + url.lastPathComponent.lowercased() : stem.lowercased())
            if kind == .sidecar {
                let nested = URL(fileURLWithPath: stem)
                if videoExtensions.contains(nested.pathExtension.lowercased()) {
                    id = "video:" + stem.lowercased()
                    stem = nested.deletingPathExtension().lastPathComponent
                } else if rawExtensions.union(renderedExtensions).contains(nested.pathExtension.lowercased()) {
                    stem = nested.deletingPathExtension().lastPathComponent
                    id = stem.lowercased()
                }
            }
            names[id] = names[id] ?? stem
            families[id, default: []].append(PhotoFile(url: url, kind: kind, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast, formatHint: hint?.1.formatHint))
        }
        // A bare XMP belongs to a video only when no photo family or second video makes it ambiguous.
        for (id, files) in families where !id.hasPrefix("video:") && files.allSatisfy({ $0.kind == .sidecar }) {
            let candidates = families.keys.filter { key in
                key.hasPrefix("video:") && families[key]!.contains {
                    $0.kind == .video && $0.url.deletingPathExtension().lastPathComponent.lowercased() == id
                }
            }
            if candidates.count == 1 { families[candidates[0], default: []].append(contentsOf: files) }
        }
        return families.compactMap { id, files in
            guard files.contains(where: { $0.kind != .sidecar }) else { return nil }
            return PhotoAsset(id: id, name: names[id]!, files: files.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent })
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
