import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    var id: String { rawValue }
    var displayName: String { self == .english ? "English" : "简体中文" }
}

extension Notification.Name {
    static let studioLanguageChanged = Notification.Name("studio.language.changed")
}

enum I18n {
    /// Used by previews and tests; never persists a user's language preference.
    static var overrideLanguage: AppLanguage?
    static func resolveLanguage(_ storedValue: String?) -> AppLanguage {
        AppLanguage(rawValue: storedValue ?? "") ?? .english
    }
    static var language: AppLanguage {
        overrideLanguage ?? resolveLanguage(UserDefaults.standard.string(forKey: "studio.language"))
    }

    static func select(_ language: AppLanguage, persist: Bool = true) {
        if persist {
            overrideLanguage = nil
            UserDefaults.standard.set(language.rawValue, forKey: "studio.language")
        } else { overrideLanguage = language }
        NotificationCenter.default.post(name: .studioLanguageChanged, object: nil)
    }

    static let catalogs: [String: [String: String]] = {
        let directory = ProcessInfo.processInfo.environment["STUDIO_RESOURCES"].map { URL(fileURLWithPath: $0) } ?? Bundle.main.resourceURL!
        var result: [String: [String: String]] = [:]
        for language in AppLanguage.allCases {
            let url = directory.appendingPathComponent("Locales/\(language.rawValue).json")
            if let data = try? Data(contentsOf: url), let values = try? JSONDecoder().decode([String: String].self, from: data) {
                result[language.rawValue] = values
            }
        }
        return result
    }()

    private struct Pattern {
        var regex: NSRegularExpression
        var translation: String
        var indexes: [Int]
    }

    private static let dynamicPatterns: [Pattern] = {
        let token = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)
        return (catalogs[AppLanguage.simplifiedChinese.rawValue] ?? [:]).sorted { $0.key < $1.key }.compactMap { key, translation in
            let source = key as NSString
            let matches = token.matches(in: key, range: NSRange(location: 0, length: source.length))
            guard !matches.isEmpty else { return nil }
            var cursor = 0, pattern = "^", indexes: [Int] = []
            for match in matches {
                pattern += NSRegularExpression.escapedPattern(for: source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))) + "(.*?)"
                indexes.append(Int(source.substring(with: match.range(at: 1)))!)
                cursor = NSMaxRange(match.range)
            }
            pattern += NSRegularExpression.escapedPattern(for: source.substring(from: cursor)) + "$"
            return Pattern(regex: try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]), translation: translation, indexes: indexes)
        }
    }()

    static func translate(_ key: String, arguments: [Any] = []) -> String {
        if language == .english { return format(key, arguments: arguments) }
        if let translated = catalogs[language.rawValue]?[key] { return format(translated, arguments: arguments) }
        // The Python adapter returns canonical English messages. Match only cataloged
        // templates to localize formatted status/error text without translating user data.
        if arguments.isEmpty {
            let value = key as NSString
            for pattern in dynamicPatterns {
                guard let match = pattern.regex.firstMatch(in: key, range: NSRange(location: 0, length: value.length)) else { continue }
                var arguments: [Int: String] = [:]
                for (i, index) in pattern.indexes.enumerated() {
                    arguments[index] = value.substring(with: match.range(at: i + 1))
                }
                return substitute(pattern.translation, values: arguments)
            }
        }
        return format(key, arguments: arguments)
    }

    private static func format(_ template: String, arguments: [Any]) -> String {
        substitute(template, values: Dictionary(uniqueKeysWithValues: arguments.enumerated().map { ($0.offset, String(describing: $0.element)) }))
    }

    private static func substitute(_ template: String, values: [Int: String]) -> String {
        let token = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)
        let source = template as NSString
        var result = template
        // Replace tokens from the original template only; values may contain braces.
        for match in token.matches(in: template, range: NSRange(location: 0, length: source.length)).reversed() {
            if let index = Int(source.substring(with: match.range(at: 1))), let value = values[index], let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: value)
            }
        }
        return result
    }
}

func L(_ key: String, _ arguments: Any...) -> String { I18n.translate(key, arguments: arguments) }
