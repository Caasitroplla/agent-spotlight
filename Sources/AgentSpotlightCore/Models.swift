import Foundation

public enum ChatSource: String, CaseIterable, Codable, Sendable {
    case codex, cursor
    public var displayName: String { rawValue.capitalized }
}

public struct ChatID: Hashable, Codable, Sendable {
    public let source: ChatSource
    public let externalID: String
    public var key: String { source.rawValue + ":" + externalID }
    public init(source: ChatSource, externalID: String) { self.source = source; self.externalID = externalID }
}

public enum ChatActivity: Int, Codable, Sendable {
    case idle = 0, detected = 1
}

public struct ChatRecord: Identifiable, Sendable {
    public var identity: ChatID
    public var id: String { identity.key }
    public var title: String
    public var projectPath: String
    public var updatedAt: Date
    public var archived: Bool
    public var subagent: Bool
    public var activity: ChatActivity
    public var preview: String
    public var revision: String
    public init(identity: ChatID, title: String, projectPath: String = "", updatedAt: Date, archived: Bool = false, subagent: Bool = false, activity: ChatActivity = .idle, preview: String = "", revision: String = "") {
        self.identity = identity; self.title = title; self.projectPath = projectPath; self.updatedAt = updatedAt; self.archived = archived; self.subagent = subagent; self.activity = activity; self.preview = preview; self.revision = revision
    }
    public var deepLink: URL? {
        switch identity.source {
        case .codex:
            var components = URLComponents(); components.scheme = "codex"; components.host = "threads"; components.path = "/" + identity.externalID
            return components.url
        case .cursor:
            var components = URLComponents(); components.scheme = "cursor"; components.host = "anysphere.cursor-deeplink"; components.path = "/agent"; components.queryItems = [URLQueryItem(name: "id", value: identity.externalID)]
            return components.url
        }
    }
}

public struct SearchQuery: Sendable {
    public var text: String
    public var source: ChatSource?
    public var includeArchived: Bool
    public var includeSubagents: Bool
    public var limit: Int
    public init(text: String = "", source: ChatSource? = nil, includeArchived: Bool = true, includeSubagents: Bool = false, limit: Int = 80) {
        self.text = text; self.source = source; self.includeArchived = includeArchived; self.includeSubagents = includeSubagents; self.limit = limit
    }
    public var ftsExpression: String? {
        let words = text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }.joined(separator: " AND ")
    }
}

public struct ProviderStatus: Sendable {
    public var source: ChatSource
    public var discovered: Int
    public var indexed: Int
    public var unavailable: Int
    public var error: String?
    public init(source: ChatSource, discovered: Int = 0, indexed: Int = 0, unavailable: Int = 0, error: String? = nil) {
        self.source = source; self.discovered = discovered; self.indexed = indexed; self.unavailable = unavailable; self.error = error
    }
}

public struct IndexStatus: Sendable {
    public var refreshing = false
    public var providers: [ProviderStatus] = []
    public var indexed: Int { providers.reduce(0) { $0 + $1.indexed } }
    public var discovered: Int { providers.reduce(0) { $0 + $1.discovered } }
    public var unavailable: Int { providers.reduce(0) { $0 + $1.unavailable } }
    public init() {}
}

public struct SourcePaths: Sendable {
    public var codexRoot: URL
    public var cursorRoot: URL
    public init(codexRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"), cursorRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage")) { self.codexRoot = codexRoot; self.cursorRoot = cursorRoot }
}

public struct SourceChat: Sendable {
    public var record: ChatRecord
    public var locator: String
    public var bodyHint: String?
    public init(record: ChatRecord, locator: String = "", bodyHint: String? = nil) { self.record = record; self.locator = locator; self.bodyHint = bodyHint }
}

public protocol ChatProvider {
    var source: ChatSource { get }
    var discoveryComplete: Bool { get }
    var discoveryWarning: String? { get }
    func discover() throws -> [SourceChat]
    func body(for chat: SourceChat) throws -> String?
}

public extension ChatProvider {
    var discoveryComplete: Bool { true }
    var discoveryWarning: String? { nil }
}
