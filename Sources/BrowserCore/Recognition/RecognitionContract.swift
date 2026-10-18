import Foundation

/// Frozen copies of the approved recognition protocol; domain names and codes come from these resources.
enum RecognitionContract {
    static func resource(_ name: String, _ ext: String) throws -> Data {
        guard let url = L10n.resourceBundle.url(forResource: name, withExtension: ext) else {
            throw BrowserFailure.message(L10n.text("缺少 AI 识别协议资源。"))
        }
        return try Data(contentsOf: url)
    }
    static func context() throws -> RecognitionContext {
        try RecognitionContext(protocolData: resource("recognition-format", "json"),
                               dictionaryData: resource("recognition-dictionary", "json"))
    }
    static func prompt() throws -> String {
        String(decoding: try resource("recognition-prompt", "txt"), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func analysis(_ raw: String) throws -> [String: Any] {
        guard !raw.isEmpty, raw.utf8.count <= 65_536 else { throw invalid() }
        let context = try context()
        let fields = context.labeledFields(raw)
        guard context.fields.allSatisfy({ fields[$0.output_field] != nil }),
              !(fields["title"] ?? "").isEmpty, !(fields["description"] ?? "").isEmpty else { throw invalid() }
        var analysis: [String: Any] = ["analysis_id": UUID().uuidString.lowercased(), "raw_response": raw]
        let wrapper: [String: Any] = ["analyses": [analysis]]
        let parsed = try context.decode(JSONSerialization.data(withJSONObject: wrapper))
        var output: [String: Any] = ["title": parsed.title, "description": parsed.description]
        var observed: [[String: String]] = [], seen: Set<String> = []
        for field in context.fields {
            guard let category = field.dictionary,
                  let section = parsed.sections.first(where: { $0.id == field.output_field }) else { continue }
            if field.multiple == true {
                output[field.output_field] = section.tags.map(\.code)
                for tag in section.tags where seen.insert(tag.code).inserted {
                    observed.append(["dictionary": category, "code": tag.code, "name": tag.name])
                }
            } else {
                guard let code = section.tags.first?.code else { throw invalid() }
                output[field.output_field] = code
            }
        }
        analysis["output"] = output; analysis["observed_terms"] = observed
        return analysis
    }
    static func invalid() -> Error { BrowserFailure.message(L10n.text("模型返回内容不完整或格式无效，原结果已保留。")) }
}
