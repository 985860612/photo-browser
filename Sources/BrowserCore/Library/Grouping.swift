import Foundation

public enum Grouping {
    /// Metadata provides candidates only; the user reviews the actual image overlap.
    public static func candidates(_ assets: [PhotoAsset]) -> [PhotoGroup] {
        let sorted = assets.filter { !$0.isVideo }.sorted {
            let left = $0.metadata?.captured ?? .distantFuture
            let right = $1.metadata?.captured ?? .distantFuture
            return left == right ? $0.name < $1.name : left < right
        }
        var runs: [[PhotoAsset]] = []
        var current: [PhotoAsset] = []
        for asset in sorted {
            var joins = false
            if let previous = current.last, let a = previous.metadata, let b = asset.metadata,
               let ta = a.captured, let tb = b.captured, let fa = a.focalLength, let fb = b.focalLength {
                let gap = tb.timeIntervalSince(ta)
                if abs(fa - fb) < 0.01, gap >= 0 {
                    if let sa = a.sequence, let sb = b.sequence {
                        joins = gap <= 8 && sb > sa
                    } else if a.sequence == nil && b.sequence == nil {
                        joins = gap <= 5
                    }
                }
            }
            if !joins && !current.isEmpty {
                runs.append(current); current = []
            }
            current.append(asset)
        }
        if !current.isEmpty { runs.append(current) }
        return runs.filter { $0.count >= 3 }.enumerated().map { index, run in
            let burst = run.allSatisfy { $0.metadata?.sequence != nil }
            return PhotoGroup(name: L10n.text("候选组 \(index + 1)"), assetIDs: run.map(\.id), confidence: .review,
                              reason: burst ? L10n.text("连续连拍、焦距一致；请查看画面是否横向移动并重叠") : L10n.text("短时间连续单拍、焦距一致；可能只是重复构图"))
        }
    }

    public static func importCSV(_ data: Data, assets: [PhotoAsset]) throws -> [PhotoGroup] {
        guard var text = String(data: data, encoding: .utf8) else { throw BrowserFailure.message(L10n.text("清单不是 UTF-8 编码。")) }
        if text.first == "\u{feff}" { text.removeFirst() }
        let rows = try CSV.parse(text)
        guard let header = rows.first, let gi = header.firstIndex(of: "组号"), let fi = header.firstIndex(of: "文件名") else {
            throw BrowserFailure.message(L10n.text("清单需要“组号”和“文件名”两列。"))
        }
        let ci = header.firstIndex(of: "分类"), ri = header.firstIndex(of: "判断依据")
        let byFilename = Dictionary(assets.flatMap { a in a.files.map { ($0.url.lastPathComponent, a.id) } }, uniquingKeysWith: { a, _ in a })
        var result: [PhotoGroup] = []
        var locations: [String: Int] = [:]
        for row in rows.dropFirst() where row.count > max(gi, fi) {
            guard let assetID = byFilename[row[fi]] else { continue }
            let number = row[gi]
            if locations[number] == nil {
                let category = ci.flatMap { $0 < row.count ? row[$0] : nil } ?? "待确认"
                let reason = ri.flatMap { $0 < row.count ? row[$0] : nil } ?? L10n.text("导入已有清单")
                locations[number] = result.count
                result.append(PhotoGroup(id: "import-\(number)", name: L10n.text("全景组 \(number)"), assetIDs: [], confidence: GroupConfidence(rawValue: category) ?? .review, reason: reason))
            }
            let index = locations[number]!
            if !result[index].assetIDs.contains(assetID) { result[index].assetIDs.append(assetID) }
        }
        guard !result.isEmpty else { throw BrowserFailure.message(L10n.text("清单中的文件没有匹配到当前目录。")) }
        return result
    }

    public static func split(_ group: PhotoGroup, at assetID: String) throws -> [PhotoGroup] {
        guard let index = group.assetIDs.firstIndex(of: assetID), index > 0 else {
            throw BrowserFailure.message(L10n.text("请选择组内第二张或之后的照片作为新组起点。"))
        }
        return [PhotoGroup(name: group.name + " A", assetIDs: Array(group.assetIDs[..<index])),
                PhotoGroup(name: group.name + " B", assetIDs: Array(group.assetIDs[index...]))]
    }
}

public enum CSV {
    public static func parse(_ text: String) throws -> [[String]] {
        let chars = Array(text)
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false, i = 0
        while i < chars.count {
            let char = chars[i]
            if char == "\"" {
                if quoted && i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                else { quoted.toggle() }
            } else if char == "," && !quoted { row.append(field); field = "" }
            else if (char == "\n" || char == "\r\n" || char == "\r") && !quoted {
                row.append(field); if row.contains(where: { !$0.isEmpty }) { rows.append(row) }; row = []; field = ""
            } else { field.append(char) }
            i += 1
        }
        guard !quoted else { throw BrowserFailure.message(L10n.text("CSV 的引号未闭合。")) }
        row.append(field); if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return rows
    }
}
