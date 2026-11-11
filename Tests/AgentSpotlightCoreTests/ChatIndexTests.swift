import XCTest
@testable import AgentSpotlightCore

final class FixtureProvider: ChatProvider {
    let source: ChatSource
    var chats: [SourceChat]
    var bodies: [String: String]
    var failDiscovery = false
    var complete = true
    var discoveryComplete: Bool { complete }
    var discoveryWarning: String? { complete ? nil : "Partial fixture history" }
    init(source: ChatSource = .codex, chats: [SourceChat], bodies: [String: String]) { self.source = source; self.chats = chats; self.bodies = bodies }
    func discover() throws -> [SourceChat] {
        if failDiscovery { throw SQLiteError(description: "Fixture source unavailable") }
        return chats
    }
    func body(for chat: SourceChat) throws -> String? { bodies[chat.record.identity.externalID] }
}

final class ChatIndexTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func chat(_ id: String, title: String = "Untitled", secondsAgo: Double = 0, active: Bool = false, archived: Bool = false, subagent: Bool = false, source: ChatSource = .codex, revision: String = "1") -> SourceChat {
        SourceChat(record: ChatRecord(identity: ChatID(source: source, externalID: id), title: title, projectPath: "/Projects/nebula", updatedAt: Date().addingTimeInterval(-secondsAgo), archived: archived, subagent: subagent, activity: active ? .detected : .idle, revision: revision))
    }
    func testBodySearchPrefixPunctuationAndProject() async throws {
        let index = try ChatIndex(url: directory.appendingPathComponent("index.sqlite"))
        let provider = FixtureProvider(chats: [chat("one", title: "Database repair"), chat("two", title: "Other work")], bodies: ["one": "The strawberry migration preserved every customer", "two": "A separate unrelated message"])
        await index.refresh(providers: [provider])
        let recents = try await index.search(SearchQuery())
        XCTAssertEqual(recents.first(where: { $0.id == "codex:one" })?.preview, "The strawberry migration preserved every customer")
        await index.refresh(providers: [provider])
        let refreshed = try await index.search(SearchQuery())
        XCTAssertEqual(refreshed.first(where: { $0.id == "codex:one" })?.preview, "The strawberry migration preserved every customer")
        let body = try await index.search(SearchQuery(text: "straw mig"))
        XCTAssertEqual(body.map(\.id), ["codex:one"])
        let escaped = try await index.search(SearchQuery(text: "\"strawberry\" OR (migration)"))
        XCTAssertEqual(escaped.map(\.id), [])
        let punctuation = try await index.search(SearchQuery(text: "*** \" : ()"))
        XCTAssertEqual(punctuation.map(\.id), [])
        let project = try await index.search(SearchQuery(text: "nebula"))
        XCTAssertEqual(Set(project.map(\.id)), Set(["codex:one", "codex:two"]))
    }
    func testActivityThenRecencyAndFilters() async throws {
        let index = try ChatIndex(url: directory.appendingPathComponent("index.sqlite"))
        let codex = FixtureProvider(chats: [chat("recent", secondsAgo: 1), chat("active", secondsAgo: 40, active: true), chat("archived", secondsAgo: 20, archived: true), chat("child", secondsAgo: 0, subagent: true), chat("stale", secondsAgo: 900, active: true)], bodies: ["recent": "", "active": "", "archived": "", "child": "", "stale": ""])
        let cursor = FixtureProvider(source: .cursor, chats: [chat("recent", secondsAgo: 30, source: .cursor)], bodies: ["recent": ""])
        await index.refresh(providers: [codex, cursor])
        let all = try await index.search(SearchQuery())
        XCTAssertEqual(all.map(\.id), ["codex:active", "codex:recent", "codex:archived", "cursor:recent", "codex:stale"])
        let filtered = try await index.search(SearchQuery(source: .codex, includeArchived: false))
        XCTAssertEqual(filtered.map(\.id), ["codex:active", "codex:recent", "codex:stale"])
        let children = try await index.search(SearchQuery(includeSubagents: true))
        XCTAssertEqual(children.map(\.id), ["codex:active", "codex:child", "codex:recent", "codex:archived", "cursor:recent", "codex:stale"])
    }
    func testIncrementalRefreshPruningAndPersistence() async throws {
        let url = directory.appendingPathComponent("index.sqlite")
        let index = try ChatIndex(url: url)
        let provider = FixtureProvider(chats: [chat("one", title: "First"), chat("two", title: "Second")], bodies: ["one": "originalword", "two": "removedword"])
        await index.refresh(providers: [provider])
        provider.chats = [chat("one", title: "Renamed", revision: "2")]
        provider.bodies = ["one": "replacementword"]
        await index.refresh(providers: [provider])
        let original = try await index.search(SearchQuery(text: "originalword"))
        XCTAssertEqual(original.count, 0)
        let removed = try await index.search(SearchQuery(text: "removedword"))
        XCTAssertEqual(removed.count, 0)
        let reopened = try ChatIndex(url: url)
        let persisted = try await reopened.search(SearchQuery(text: "replacementword"))
        XCTAssertEqual(persisted.map(\.title), ["Renamed"])
        let renamed = try await index.search(SearchQuery(text: "renamed"))
        XCTAssertEqual(renamed.map(\.id), ["codex:one"])
    }
    func testSourceFailureKeepsGoodHistoryAndMissingBodyRetries() async throws {
        let index = try ChatIndex(url: directory.appendingPathComponent("index.sqlite"))
        let provider = FixtureProvider(chats: [chat("one")], bodies: ["one": "durableword"])
        await index.refresh(providers: [provider])
        provider.failDiscovery = true
        await index.refresh(providers: [provider])
        let kept = try await index.search(SearchQuery(text: "durableword"))
        XCTAssertEqual(kept.map(\.id), ["codex:one"])
        provider.failDiscovery = false
        provider.chats = [chat("one", revision: "2")]
        provider.bodies = [:]
        await index.refresh(providers: [provider])
        let missing = await index.currentStatus()
        XCTAssertEqual(missing.unavailable, 1)
        let durable = try await index.search(SearchQuery(text: "durableword"))
        XCTAssertEqual(durable.map(\.id), ["codex:one"])
        provider.bodies = ["one": "recoveredword"]
        await index.refresh(providers: [provider])
        let recovered = try await index.search(SearchQuery(text: "recoveredword"))
        XCTAssertEqual(recovered.map(\.id), ["codex:one"])
    }
    func testPartialEnumerationPreservesChatsAndReportsCoverage() async throws {
        let index = try ChatIndex(url: directory.appendingPathComponent("index.sqlite"))
        let provider = FixtureProvider(chats: [chat("one"), chat("two")], bodies: ["one": "firstword", "two": "secondword"])
        await index.refresh(providers: [provider])
        provider.chats = [chat("one")]
        provider.complete = false
        await index.refresh(providers: [provider])
        let retained = try await index.search(SearchQuery(text: "secondword"))
        XCTAssertEqual(retained.map(\.id), ["codex:two"])
        let status = await index.currentStatus()
        XCTAssertEqual(status.providers.first?.error, "Partial fixture history")
        provider.complete = true
        await index.refresh(providers: [provider])
        let pruned = try await index.search(SearchQuery(text: "secondword"))
        XCTAssertEqual(pruned.map(\.id), [])
    }
    func testDeepLinksKeepAppIdentityAndEscapeIDs() {
        XCTAssertEqual(chat("abc", source: .codex).record.deepLink?.absoluteString, "codex://threads/abc")
        XCTAssertEqual(chat("abc &/123", source: .cursor).record.deepLink?.absoluteString, "cursor://anysphere.cursor-deeplink/agent?id=abc%20%26/123")
    }
}
