import Foundation
import CryptoKit

public struct RecognitionTag: Identifiable, Equatable, Sendable {
    public let code: String
    public let name: String
    public var id: String { code }
}

public struct RecognitionSection: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let tags: [RecognitionTag]
}

public struct RecognitionMetadata: Sendable {
    public let title: String
    public let description: String
    public let sections: [RecognitionSection]
    public let rawResponse: String
    public let modelName: String?
    public let failure: String?
}

/// The wire protocol and dictionary remain the authority for field names and codes.
public struct RecognitionContext: Sendable {
    public struct Field: Decodable, Sendable {
        public let name: String
        public let output_field: String
        public let dictionary: String?
        public let multiple: Bool?
    }
    struct Term: Decodable, Sendable { let code: String; let name: String }
    let fields: [Field]
    let terms: [String: [String: String]]
    let missing: String

    public init(protocolData: Data, dictionaryData: Data) throws {
        struct ProtocolFile: Decodable { let fields: [Field]; let missing: String? }
        struct DictionaryFile: Decodable { let dictionaries: [String: [Term]] }
        let wire = try JSONDecoder().decode(ProtocolFile.self, from: protocolData)
        let dictionary = try JSONDecoder().decode(DictionaryFile.self, from: dictionaryData)
        fields = wire.fields; missing = wire.missing ?? "-"
        terms = dictionary.dictionaries.mapValues { entries in
            entries.reduce(into: [:]) { $0[$1.code] = $1.name }
        }
    }

    init(directory: URL) throws {
        try self.init(protocolData: Data(contentsOf: directory.appendingPathComponent("text-format.json")),
                      dictionaryData: Data(contentsOf: directory.appendingPathComponent("dictionary.json")))
    }

    public func decode(_ data: Data) throws -> RecognitionMetadata {
        guard let record = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrowserFailure.message(L10n.text("无法解析 AI 识别结果。"))
        }
        let processing = record["processing"] as? [String: Any] ?? [:]
        if processing["state_code"] as? String == "processing.failed" {
            let message = (processing["last_error"] as? [String: Any])?["message"] as? String
            return RecognitionMetadata(title: "", description: "", sections: [], rawResponse: "", modelName: nil,
                                       failure: message ?? L10n.text("此照片识别失败。"))
        }
        let analyses = record["analyses"] as? [[String: Any]] ?? []
        let current = processing["current_analysis_id"] as? String
        let analysis = current.flatMap { id in analyses.first { $0["analysis_id"] as? String == id } }
            ?? (current == nil && analyses.count == 1 ? analyses.first : nil)
        guard let analysis else { throw BrowserFailure.message(L10n.text("AI 识别结果缺少当前分析记录。")) }
        let raw = analysis["raw_response"] as? String ?? ""
        let rawFields = labeledFields(raw)
        var output = analysis["output"] as? [String: Any] ?? [:]
        if output.isEmpty, let bytes = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] { output = object }
        var dictionary = terms
        for item in analysis["observed_terms"] as? [[String: String]] ?? [] {
            if let category = item["dictionary"], let code = item["code"], let name = item["name"] {
                dictionary[category, default: [:]][code] = name
            }
        }
        var sections: [RecognitionSection] = []
        for field in fields {
            guard let category = field.dictionary else { continue }
            let value: Any? = output[field.output_field] ?? rawFields[field.output_field].map { $0 as Any }
            let values = (value as? [String]) ?? (value as? String).map { [$0] } ?? []
            var seen: Set<String> = [], tags: [RecognitionTag] = []
            let expanded = values.flatMap { value in
                guard dictionary[category]?[value] == nil, field.multiple == true else { return [value] }
                let pieces = RecognitionLabels.split(value, missing: missing)
                return !pieces.isEmpty && pieces.allSatisfy({ dictionary[category]?[$0] != nil }) ? pieces : [value]
            }
            for value in expanded {
                let originalName = dictionary[category]?[value]
                let pieces = field.multiple == true ? RecognitionLabels.split(originalName ?? value, missing: missing) : [originalName ?? value]
                for name in pieces where !name.isEmpty && name != missing {
                    let code: String
                    if pieces.count == 1, originalName == name { code = value }
                    else if let existing = dictionary[category]?.first(where: { $0.value == name })?.key { code = existing }
                    else if field.multiple == true && !name.hasPrefix(category + ".") {
                        code = Self.termCode(dictionary: category, name: name)
                    } else { throw BrowserFailure.message(L10n.text("无法解析 AI 标签：\(name)")) }
                    if seen.insert(code).inserted { tags.append(RecognitionTag(code: code, name: name)) }
                }
            }
            sections.append(RecognitionSection(id: field.output_field, name: field.name, tags: tags))
        }
        let title = (output["title"] as? String) ?? rawFields["title"] ?? ""
        let description = (output["description"] as? String) ?? rawFields["description"] ?? ""
        guard !title.isEmpty || !description.isEmpty || sections.contains(where: { !$0.tags.isEmpty }) else {
            throw BrowserFailure.message(L10n.text("无法解析 AI 识别结果。"))
        }
        return RecognitionMetadata(title: title, description: description, sections: sections, rawResponse: raw,
                                   modelName: (analysis["model"] as? [String: Any])?["name"] as? String, failure: nil)
    }

    public static func termCode(dictionary: String, name: String) -> String {
        let digest = SHA256.hash(data: Data(name.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        return dictionary + ".term." + digest.map { String(format: "%02x", $0) }.joined()
    }

    private func labeledFields(_ raw: String) -> [String: String] {
        var result: [String: String] = [:], current: String?
        for line in raw.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { continue }
            if let colon = line.firstIndex(where: { $0 == ":" || $0 == "：" }) {
                let name = line[..<colon].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*")))
                if let field = fields.first(where: { $0.name == name || $0.output_field == name }) {
                    current = field.output_field
                    result[field.output_field] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    continue
                }
            }
            if let current { result[current, default: ""] += "\n" + line }
        }
        return result.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

/// Tolerates common list separators without splitting prose, bracketed phrases or quoted labels.
public enum RecognitionLabels {
    public static func split(_ value: String, missing: String = "-") -> [String] {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("["), let data = text.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [String] {
            return unique(array.flatMap { split($0, missing: missing) }, missing: missing)
        }
        var labels: [String] = [], buffer = "", brackets: [Character] = [], quote: Character?
        func flush() {
            var label = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            for prefix in ["- ", "* ", "• "] where label.hasPrefix(prefix) { label.removeFirst(prefix.count) }
            if label.count >= 2, let first = label.first, let last = label.last,
               (first == "\"" && last == "\"") || (first == "“" && last == "”") {
                label.removeFirst(); label.removeLast()
            }
            labels.append(label.trimmingCharacters(in: .whitespacesAndNewlines)); buffer = ""
        }
        for character in text {
            if let closing = quote {
                buffer.append(character)
                if character == closing { quote = nil }
                continue
            }
            switch character {
            case "\"": quote = "\""
            case "“": quote = "”"
            case "「": quote = "」"
            case "『": quote = "』"
            case "(": brackets.append(")")
            case "（": brackets.append("）")
            case "[": brackets.append("]")
            case "【": brackets.append("】")
            case "{": brackets.append("}")
            default: if brackets.last == character { brackets.removeLast() }
            }
            if quote == nil && brackets.isEmpty && "|｜,，、;；\n\r\t".contains(character) { flush() }
            else { buffer.append(character) }
        }
        flush()
        return unique(labels, missing: missing)
    }

    private static func unique(_ labels: [String], missing: String) -> [String] {
        var seen: Set<String> = []
        return labels.filter { !$0.isEmpty && $0 != missing && seen.insert($0).inserted }
    }
}
