import Foundation
import Security

public struct AIModelConfiguration: Codable, Equatable, Sendable {
    public var baseURL = ""
    public var model = "qwen3.8-flash"
    public var enableThinking = false
    public init() {}
    public static let preferencesKey = "aiModelConfiguration.v1"

    public static func load(defaults: UserDefaults = .standard) throws -> Self {
        guard let data = defaults.data(forKey: preferencesKey) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    public func save(defaults: UserDefaults = .standard) throws {
        _ = try endpoint()
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BrowserFailure.message(L10n.text("请输入模型名称。"))
        }
        defaults.set(try JSONEncoder().encode(self), forKey: Self.preferencesKey)
    }

    public func endpoint() throws -> URL {
        let text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw BrowserFailure.message(L10n.text("服务地址必须是无用户名、查询参数的 HTTPS 地址。"))
        }
        return url.appendingPathComponent("chat/completions")
    }

    public var credentialAccount: String {
        let address = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return ThumbnailCache.digest(address)
    }

    public static func importCSV(_ text: String) throws -> (configuration: Self, apiKey: String) {
        let rows = try CSV.parse(text.replacingOccurrences(of: "\u{FEFF}", with: ""))
        var fields: [String: String] = [:]
        for row in rows where row.count == 2 {
            let name = row[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard fields[name] == nil else { throw BrowserFailure.message(L10n.text("CSV 中存在重复配置项。")) }
            fields[name] = row[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let key = fields["apiKey"], !key.isEmpty, let endpoint = fields["openAiCompatible"] else {
            throw BrowserFailure.message(L10n.text("CSV 缺少 apiKey 或 openAiCompatible 配置。"))
        }
        var configuration = Self(); configuration.baseURL = endpoint
        _ = try configuration.endpoint()
        try AIModelKeychain.validate(key)
        return (configuration, key)
    }
}

/// Credentials are scoped to the configured endpoint, never serialized with preferences or metadata.
public enum AIModelKeychain {
    public static let service = "local.wxj.PhotoBrowser.AI"
    private static func query(_ configuration: AIModelConfiguration) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: configuration.credentialAccount]
    }
    public static func validate(_ key: String) throws {
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw BrowserFailure.message(L10n.text("API Key 不能为空或包含空白字符。"))
        }
    }
    public static func read(_ configuration: AIModelConfiguration) throws -> String? {
        var request = query(configuration)
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data, let key = String(data: bytes, encoding: .utf8) else { throw failure(status) }
        return key
    }
    public static func save(_ key: String, configuration: AIModelConfiguration) throws {
        try validate(key)
        let attributes = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(query(configuration) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(configuration)
            item.merge(attributes) { _, new in new }
            item[kSecAttrLabel as String] = "Photo Browser AI"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    public static func remove(_ configuration: AIModelConfiguration) throws {
        let status = SecItemDelete(query(configuration) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
    private static func failure(_ status: OSStatus) -> Error {
        BrowserFailure.message(L10n.text("无法访问 AI 密钥的钥匙串项目（\(status)）。"))
    }
}
