import Foundation

public enum LauncherMode: String, CaseIterable, Codable, Sendable {
    case search, cursor, codex

    public var title: String {
        switch self {
        case .search: return "Search"
        case .cursor: return "New Cursor chat"
        case .codex: return "New Codex chat"
        }
    }

    public var source: ChatSource? {
        switch self {
        case .search: return nil
        case .cursor: return .cursor
        case .codex: return .codex
        }
    }
}

public struct LauncherSettings: Codable, Equatable, Sendable {
    public private(set) var shortcutModes: [LauncherMode] = [.search, .cursor, .codex]
    public var defaultMode: LauncherMode = .search
    public var cursorPrefix = "/poteto_mode"
    public var codexPrefix = "/poteto_mode"
    public var showModelDefaults = true

    public init() {}

    public mutating func assign(_ mode: LauncherMode, toSlot slot: Int) {
        guard shortcutModes.indices.contains(slot), let previous = shortcutModes.firstIndex(of: mode) else { return }
        shortcutModes.swapAt(slot, previous)
    }

    public func mode(forSlot slot: Int) -> LauncherMode? {
        shortcutModes.indices.contains(slot) ? shortcutModes[slot] : nil
    }

    public func shortcut(for mode: LauncherMode) -> String {
        "⌘\((shortcutModes.firstIndex(of: mode) ?? 0) + 1)"
    }

    public func prefix(for mode: LauncherMode) -> String {
        switch mode {
        case .search: return ""
        case .cursor: return cursorPrefix
        case .codex: return codexPrefix
        }
    }

    public func prompt(for mode: LauncherMode, draft: String) -> String {
        [prefix(for: mode), draft]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    public static func load(from defaults: UserDefaults) -> LauncherSettings {
        guard let data = defaults.data(forKey: "launcherSettings"),
              let settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return settings
    }

    public func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: "launcherSettings") }
    }

    private enum CodingKeys: String, CodingKey {
        case shortcutModes, defaultMode, cursorPrefix, codexPrefix, showModelDefaults
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let order = try values.decodeIfPresent([LauncherMode].self, forKey: .shortcutModes) ?? LauncherMode.allCases
        shortcutModes = order.count == LauncherMode.allCases.count && Set(order) == Set(LauncherMode.allCases) ? order : LauncherMode.allCases
        defaultMode = try values.decodeIfPresent(LauncherMode.self, forKey: .defaultMode) ?? .search
        cursorPrefix = try values.decodeIfPresent(String.self, forKey: .cursorPrefix) ?? "/poteto_mode"
        codexPrefix = try values.decodeIfPresent(String.self, forKey: .codexPrefix) ?? "/poteto_mode"
        showModelDefaults = try values.decodeIfPresent(Bool.self, forKey: .showModelDefaults) ?? true
    }
}

public enum NewChatError: LocalizedError {
    case searchMode, invalidURL, cursorPromptTooLong

    public var errorDescription: String? {
        switch self {
        case .searchMode: return "Select Cursor or Codex to start a new chat."
        case .invalidURL: return "The prompt could not be prepared. Your draft is still here."
        case .cursorPromptTooLong: return "This prompt is too long for a Cursor link. Shorten it or copy the preview into Cursor."
        }
    }
}

public struct NewChatRequest: Sendable {
    public let mode: LauncherMode
    public let prompt: String

    public init(mode: LauncherMode, prompt: String) {
        self.mode = mode
        self.prompt = prompt
    }

    public func deepLink() throws -> URL {
        var components = URLComponents()
        switch mode {
        case .search: throw NewChatError.searchMode
        case .cursor:
            components.scheme = "cursor"
            components.host = "anysphere.cursor-deeplink"
            components.path = "/prompt"
            let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            guard let cursorPrompt = prompt.addingPercentEncoding(withAllowedCharacters: unreserved) else { throw NewChatError.invalidURL }
            // Cursor decodes the URI query before its prompt handler decodes the parameter.
            components.queryItems = [URLQueryItem(name: "text", value: cursorPrompt)]
        case .codex:
            components.scheme = "codex"
            components.host = "threads"
            components.path = "/new"
            components.queryItems = [URLQueryItem(name: "prompt", value: prompt)]
        }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw NewChatError.invalidURL }
        if mode == .cursor && url.absoluteString.count > 10_000 { throw NewChatError.cursorPromptTooLong }
        return url
    }
}
