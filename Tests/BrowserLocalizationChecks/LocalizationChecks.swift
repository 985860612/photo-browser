import Foundation
import BrowserCore

@main struct BrowserLocalizationChecks {
    static func main() throws {
        let arguments = CommandLine.arguments
        let expected = arguments.first { $0.hasPrefix("--expected-language=") }?.split(separator: "=", maxSplits: 1).last.map(String.init) ?? "en"
        let chinese = expected.lowercased().hasPrefix("zh")
        try require(L10n.language.lowercased() == expected.lowercased(), "Expected \(expected), selected \(L10n.language)")
        if let root = arguments.first(where: { $0.hasPrefix("--resource-root=") })?.split(separator: "=", maxSplits: 1).last {
            try require(L10n.resourceBundle.bundlePath.hasPrefix(String(root) + "/"), "Resources came from the build directory instead of the app")
            try require(Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String == (chinese ? "照片浏览器" : "Photo Browser"), "The bundled app display name did not translate")
        }

        let english = try table("en"), simplified = try table("zh-Hans")
        try require(english.count >= 250 && english.keys.sorted() == simplified.keys.sorted(), "Language catalogs have missing entries")
        for (key, translation) in english {
            try require(!translation.isEmpty, "Empty English translation: \(key)")
            try require(key.components(separatedBy: "%@").count == translation.components(separatedBy: "%@").count, "Format placeholder mismatch: \(key)")
            let count = key.components(separatedBy: "%@").count - 1
            if count > 0 {
                let rendered = String(format: translation, arguments: (0..<count).map { "value-\($0)" as NSString })
                try require(!rendered.contains("%@"), "Unresolved placeholder: \(key)")
                for index in 0..<count { try require(rendered.contains("value-\(index)"), "Missing argument: \(key)") }
            }
        }
        try require(L10n.text("照片浏览器") == (chinese ? "照片浏览器" : "Photo Browser"), "App title did not translate")
        try require(L10n.text("打开照片目录…") == (chinese ? "打开照片目录…" : "Open Photo Folder…"), "Menu did not translate")
        try require(L10n.text("检查更新…") == (chinese ? "检查更新…" : "Check for Updates…"), "Update menu did not translate")
        try require(L10n.text("发现新版本：\("0.4.12")") == (chinese ? "发现新版本：0.4.12" : "New version available: 0.4.12"), "Update version did not translate")
        try require(L10n.text("在地图中打开") == (chinese ? "在地图中打开" : "Open in Maps") &&
                    L10n.text("纬度") == (chinese ? "纬度" : "Latitude"), "GPS fields and map action did not translate")
        try require(L10n.text("未识别时优先使用") == (chinese ? "未识别时优先使用" : "Use When Unrecognized") &&
                    L10n.text("照片标记") == (chinese ? "照片标记" : "Photo Metadata") &&
                    L10n.text("使用默认设置") == (chinese ? "使用默认设置" : "Default Setting"), "Coordinate-system setting and provenance did not translate")
        try require(L10n.text("100% 像素") == (chinese ? "100% 像素" : "100% Pixels"), "A literal percent sign was changed")
        try require(L10n.text("\(1) 张已选") == (chinese ? "1 张已选" : "Selected: 1"), "Single selection count did not translate")
        try require(L10n.text("\(1259) 张照片 · \(2518) 个图像文件 · \(14) 个分组") == (chinese ? "1259 张照片 · 2518 个图像文件 · 14 个分组" : "Photos: 1259 · Image files: 2518 · Groups: 14"), "Status counts did not translate")
        let name = "水库 \"lake\" %s %@ 🌅"
        let renamed = L10n.text("分组已重命名为“\(name)”")
        try require(renamed == (chinese ? "分组已重命名为“\(name)”" : "Group renamed to “\(name)”"), "A user's group name was interpreted as a format string")
        let file = "/Volumes/照片库/DSC00001.HIF"
        try require(L10n.text("\(4) 路") == (chinese ? "4 路" : "4 workers"), "Decode worker count did not translate")
        try require(L10n.text("永久删除 \(2) 个项目？") == (chinese ? "永久删除 2 个项目？" : "Permanently delete 2 items?"), "Permanent deletion count did not translate")
        let deletion = L10n.text("将永久删除 \(3) 个文件，包括对应照片、视频及配套文件，无法撤销。\n目录：\(file)")
        try require(deletion == (chinese ? "将永久删除 3 个文件，包括对应照片、视频及配套文件，无法撤销。\n目录：\(file)"
                                 : "Permanently delete 3 files, including paired photo/video formats and companion files? This cannot be undone.\nFolder: \(file)"),
                    "Permanent deletion confirmation count and path did not translate")
        let failure = BrowserFailure.message(L10n.text("文件不存在：\(file)"))
        try require(failure.localizedDescription == (chinese ? "文件不存在：\(file)" : "File not found: \(file)"), "An error or its path did not translate correctly")
        try require(L10n.lookup(GroupConfidence.candidate.rawValue) == (chinese ? "全景候选" : "Panorama candidate"), "Legacy group state did not translate")
        try require(L10n.lookup("自定义判断依据 🌅") == "自定义判断依据 🌅", "A custom description was changed")
        let legacy = Data(#"{"id":"old-group","name":"全景组 26","assetIDs":["dsc00001"],"confidence":"全景候选","reason":"自定义判断依据"}"#.utf8)
        let decoded = try JSONDecoder().decode(PhotoGroup.self, from: legacy)
        try require(decoded.name == "全景组 26" && decoded.confidence == .candidate && decoded.reason == "自定义判断依据", "Legacy groups could not be read unchanged")
        print("PASS \(expected): \(english.count) catalog entries, menu/status/error interpolation, literal percent signs, Unicode names and paths, legacy groups; resources: \(L10n.resourceBundle.bundlePath)")
    }

    private static func table(_ language: String) throws -> [String: String] {
        let folder = L10n.resourceBundle.localizations.first { $0.lowercased() == language.lowercased() } ?? language
        guard let url = L10n.resourceBundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: folder),
              let values = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String] else {
            throw Failure("Missing language catalog: \(language)")
        }
        return values
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message) }
    }
    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
