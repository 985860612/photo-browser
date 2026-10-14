import Foundation

/// Keeps translated templates separate from user-provided names and paths.
public struct LocalizedMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    public let key: String
    public let arguments: [String]

    public init(stringLiteral value: String) {
        key = value
        arguments = []
    }

    public init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []

        public init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity)
            arguments.reserveCapacity(interpolationCount)
        }

        public mutating func appendLiteral(_ literal: String) { key += literal }

        public mutating func appendInterpolation<T>(_ value: T) {
            key += "%@"
            arguments.append(String(describing: value))
        }
    }
}

public enum L10n {
    public static let resourceBundle: Bundle = {
        // The app keeps package resources in Contents/Resources; swift run uses Bundle.module.
        if let url = Bundle.main.url(forResource: "PhotoBrowser_BrowserCore", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()
    public static let language = Bundle.preferredLocalizations(from: ["en", "zh-Hans"], forPreferences: Locale.preferredLanguages).first ?? "en"
    private static let translationBundle: Bundle = {
        let folder = resourceBundle.localizations.first { $0.lowercased() == language.lowercased() } ?? language
        guard let url = resourceBundle.url(forResource: folder, withExtension: "lproj"),
              let bundle = Bundle(url: url) else { return resourceBundle }
        return bundle
    }()

    public static func text(_ message: LocalizedMessage) -> String {
        let format = lookup(message.key)
        guard !message.arguments.isEmpty else { return format }
        return String(format: format, locale: Locale.current, arguments: message.arguments.map { $0 as NSString })
    }

    /// Unknown values are preserved, including user-written group descriptions.
    public static func lookup(_ key: String) -> String {
        translationBundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
}
