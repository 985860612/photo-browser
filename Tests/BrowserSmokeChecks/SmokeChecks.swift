import Foundation
import BrowserCore

@main struct SmokeChecks {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard let directory = args.first else {
                throw BrowserFailure.message("用法：swift run BrowserSmokeChecks <照片目录> [DSC00648 DSC00672 …]")
            }
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            let assets = try DirectoryScanner.scan(root)
            guard !assets.isEmpty else { throw BrowserFailure.message("没有找到照片。") }
            let requested = Set(args.dropFirst().map { $0.lowercased() })
            let subset = requested.isEmpty ? Array(assets.prefix(1)) : assets.filter { requested.contains($0.id) }
            guard requested.isEmpty || subset.count == requested.count else { throw BrowserFailure.message("指定的样本文件未全部匹配。") }
            var previews: [[String: Any]] = []
            for asset in subset {
                var ratios: [Double] = []
                for file in asset.imageFiles {
                    let result = try await ThumbnailCache.shared.image(file, maximum: 520)
                    let cached = try await ThumbnailCache.shared.image(file, maximum: 520)
                    let large = try await ThumbnailCache.shared.image(file, maximum: 2800)
                    let full = try await ThumbnailCache.shared.fullResolution(file)
                    let display = try await ThumbnailCache.shared.displayPhoto(file, hdr: true)
                    guard display.size == full.image.size else { throw BrowserFailure.message("HDR 显示路径改变了图像尺寸或方向：\(file.url.lastPathComponent)") }
                    guard result.image.size == cached.image.size, result.image.size.width > 0, large.image.size.width > 0 else {
                        throw BrowserFailure.message("预览或缓存检查失败：\(file.url.lastPathComponent)")
                    }
                    ratios.append(result.image.size.width / result.image.size.height)
                    guard abs(full.image.size.width / full.image.size.height - result.image.size.width / result.image.size.height) < 0.025,
                          max(full.image.size.width, full.image.size.height) >= max(large.image.size.width, large.image.size.height) else {
                        throw BrowserFailure.message("高清原图方向或尺寸检查失败：\(file.url.lastPathComponent)")
                    }
                    if let width = full.metadata?.width, let height = full.metadata?.height,
                       max(full.image.size.width, full.image.size.height) < Double(max(width, height)) {
                        throw BrowserFailure.message("高清解码返回了缩小预览：\(file.url.lastPathComponent)")
                    }
                    previews.append(["file": file.url.lastPathComponent, "thumbnail": "\(Int(result.image.size.width))×\(Int(result.image.size.height))", "large": "\(Int(large.image.size.width))×\(Int(large.image.size.height))", "full": "\(Int(full.image.size.width))×\(Int(full.image.size.height))", "hdr": display.isHDR, "headroom": display.headroom, "decodeBits": display.bitsPerComponent, "colorSpace": display.colorSpaceName])
                }
                if let first = ratios.first, ratios.contains(where: { abs($0 - first) > 0.025 }) {
                    throw BrowserFailure.message("同名格式的预览方向不一致：\(asset.name)")
                }
            }
            let metadata = try MetadataReader().read(directory: root, assets: subset)
            guard metadata.count == subset.count else { throw BrowserFailure.message("EXIF 信息没有覆盖全部样本。") }
            var summary: [String: Any] = ["captures": assets.count, "imageFiles": assets.reduce(0) { $0 + $1.imageFiles.count }, "sampleCount": subset.count, "previews": previews,
                                           "exif": metadata.mapValues { ["sequence": $0.sequence.map(String.init) ?? "single", "focal": $0.focalLength.map { String($0) } ?? "missing"] }]
            let csv = root.appendingPathComponent("全景素材筛选/全景候选文件清单.csv")
            if FileManager.default.fileExists(atPath: csv.path) {
                let groups = try Grouping.importCSV(Data(contentsOf: csv), assets: assets)
                summary["importedGroups"] = groups.count
                summary["candidateGroups"] = groups.filter { $0.confidence == .candidate }.count
                summary["candidateCaptures"] = groups.filter { $0.confidence == .candidate }.reduce(0) { $0 + $1.assetIDs.count }
                guard Set(groups.flatMap(\.assetIDs)).count == groups.flatMap(\.assetIDs).count else {
                    throw BrowserFailure.message("清单导入后有跨组重复照片。")
                }
            }
            print(String(data: try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
            print("PASS real-directory read-only smoke checks")
        } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }
}
