import XCTest
@testable import AgentSpotlightCore

final class ProviderTests: XCTestCase {
    private var root: URL!
    private var paths: SourcePaths!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let codex = root.appendingPathComponent("codex")
        let cursor = root.appendingPathComponent("cursor")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cursor, withIntermediateDirectories: true)
        paths = SourcePaths(codexRoot: codex, cursorRoot: cursor)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func object(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: .sortedKeys), as: UTF8.self) }
    private func codexDatabase() throws -> SQLite {
        let db = try SQLite(url: paths.codexRoot.appendingPathComponent("state_5.sqlite"), readOnly: false)
        try db.execute("CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,cwd TEXT,updated_at INTEGER,updated_at_ms INTEGER,archived INTEGER,source TEXT,thread_source TEXT,history_mode TEXT,rollout_path TEXT)")
        return db
    }
    private func codexThread(_ db: SQLite, id: String = "chat", history: String = "paginated", path: String = "", source: String = "user", now: Int64 = 2000) throws {
        try db.execute("INSERT INTO threads VALUES(?,?,?,?,?,?,?,?,?,?)", [.text(id), .text("Recovery plan"), .text("/work/project"), .integer(now), .integer(now * 1000), .integer(0), .text("vscode"), .text(source), .text(history), .text(path)])
    }
    private func codexHistory() throws -> SQLite {
        let db = try SQLite(url: paths.codexRoot.appendingPathComponent("thread_history_1.sqlite"), readOnly: false)
        try db.execute("CREATE TABLE thread_items(thread_id TEXT,item_type TEXT,item_json TEXT,rollout_ordinal INTEGER,updated_at_ordinal INTEGER)")
        try db.execute("CREATE TABLE thread_turns(thread_id TEXT,status TEXT,rollout_ordinal INTEGER,started_at INTEGER,completed_at INTEGER)")
        return db
    }
    func testCodexReadsOnlyConversationMessagesAndPreservesSource() throws {
        let metadata = try codexDatabase(); try codexThread(metadata)
        let history = try codexHistory()
        try history.execute("INSERT INTO thread_items VALUES('chat','userMessage',?,1,1)", [.text(try object(["content": [["type": "text", "text": "Find the woodland route"], ["type": "image", "text": "hidden image"]]]))])
        try history.execute("INSERT INTO thread_items VALUES('chat','agentMessage',?,2,2)", [.text(try object(["text": "Use the riverside trail"]))])
        try history.execute("INSERT INTO thread_items VALUES('chat','reasoning',?,3,3)", [.text(try object(["text": "private reasoning"]))])
        let metadataBefore = try Data(contentsOf: paths.codexRoot.appendingPathComponent("state_5.sqlite"))
        let historyBefore = try Data(contentsOf: paths.codexRoot.appendingPathComponent("thread_history_1.sqlite"))
        let provider = CodexProvider(paths: paths)
        let records = try provider.discover()
        XCTAssertEqual(records.map { $0.record.title }, ["Recovery plan"])
        XCTAssertEqual(try provider.body(for: XCTUnwrap(records.first)), "Find the woodland route\nUse the riverside trail")
        XCTAssertEqual(try Data(contentsOf: paths.codexRoot.appendingPathComponent("state_5.sqlite")), metadataBefore)
        XCTAssertEqual(try Data(contentsOf: paths.codexRoot.appendingPathComponent("thread_history_1.sqlite")), historyBefore)
    }
    func testCodexPrefersGUINameAndFallsBackForBlankName() throws {
        let metadata = try codexDatabase()
        try codexThread(metadata, id: "named")
        try codexThread(metadata, id: "blank")
        try metadata.execute("ALTER TABLE threads ADD COLUMN name TEXT")
        try metadata.execute("UPDATE threads SET name=? WHERE id='named'", [.text("  Visible GUI title\n")])
        try metadata.execute("UPDATE threads SET name=? WHERE id='blank'", [.text(" \n ")])
        let chats = try CodexProvider(paths: paths).discover()
        XCTAssertEqual(chats.first { $0.record.identity.externalID == "named" }?.record.title, "Visible GUI title")
        XCTAssertEqual(chats.first { $0.record.identity.externalID == "blank" }?.record.title, "Recovery plan")
    }
    func testCodexMessageRevisionChangesWithoutMetadataChange() throws {
        let metadata = try codexDatabase(); try codexThread(metadata)
        let history = try codexHistory()
        try history.execute("INSERT INTO thread_items VALUES('chat','agentMessage','{\"text\":\"First\"}',1,1)")
        let provider = CodexProvider(paths: paths)
        let before = try XCTUnwrap(provider.discover().first)
        try history.execute("UPDATE thread_items SET item_json='{\"text\":\"Revised\"}',updated_at_ordinal=2")
        let after = try XCTUnwrap(provider.discover().first)
        XCTAssertNotEqual(before.record.revision, after.record.revision)
        XCTAssertEqual(try provider.body(for: after), "Revised")
    }
    func testCodexActivityRequiresFreshTurnAndRunningApp() throws {
        let metadata = try codexDatabase(); try codexThread(metadata)
        let history = try codexHistory()
        try history.execute("INSERT INTO thread_turns VALUES('chat','inProgress',1,2000,NULL)")
        XCTAssertEqual(try CodexProvider(paths: paths, appRunning: true, now: Date(timeIntervalSince1970: 2001)).discover().first?.record.activity, .detected)
        XCTAssertEqual(try CodexProvider(paths: paths, appRunning: false, now: Date(timeIntervalSince1970: 2001)).discover().first?.record.activity, .idle)
        XCTAssertEqual(try CodexProvider(paths: paths, appRunning: true, now: Date(timeIntervalSince1970: 3000)).discover().first?.record.activity, .idle)
        try history.execute("INSERT INTO thread_turns VALUES('chat','completed',2,2000,2001)")
        XCTAssertEqual(try CodexProvider(paths: paths, appRunning: true, now: Date(timeIntervalSince1970: 2001)).discover().first?.record.activity, .idle)
    }
    func testCodexLegacySchemaAndStreamingMessages() throws {
        let db = try SQLite(url: paths.codexRoot.appendingPathComponent("state_1.sqlite"), readOnly: false)
        try db.execute("CREATE TABLE threads(id TEXT,title TEXT,updated_at INTEGER,rollout_path TEXT,source TEXT)")
        let rollout = paths.codexRoot.appendingPathComponent("rollout.jsonl")
        let envelopes: [[String: Any]] = [
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Legacy question"]]]],
            ["type": "response_item", "payload": ["type": "message", "role": "developer", "content": [["type": "input_text", "text": "Hidden instructions"]]]],
            ["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Legacy answer"]]]]
        ]
        try envelopes.map { try object($0) }.joined(separator: "\n").write(to: rollout, atomically: true, encoding: .utf8)
        try db.execute("INSERT INTO threads VALUES('old','Old chat',100,?,'vscode')", [.text(rollout.path)])
        let provider = CodexProvider(paths: paths)
        XCTAssertEqual(try provider.body(for: XCTUnwrap(provider.discover().first)), "Legacy question\nLegacy answer")
    }
    func testEmptyPaginatedCodexChatIsCompleteAndMalformedMessageFails() throws {
        let metadata = try codexDatabase(); try codexThread(metadata)
        let history = try codexHistory()
        let provider = CodexProvider(paths: paths)
        let chat = try XCTUnwrap(provider.discover().first)
        XCTAssertEqual(try provider.body(for: chat), "")
        try history.execute("INSERT INTO thread_items VALUES('chat','agentMessage','broken',1,1)")
        XCTAssertThrowsError(try provider.body(for: chat))
    }
    func testUnsupportedPaginatedHistoryFallsBackWithoutDeclaringEmpty() throws {
        let metadata = try codexDatabase()
        let rollout = paths.codexRoot.appendingPathComponent("fallback.jsonl")
        let message = try object(["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Preserved fallback conversation"]]]])
        try message.write(to: rollout, atomically: true, encoding: .utf8)
        try codexThread(metadata, id: "fallback", path: rollout.path)
        try codexThread(metadata, id: "unavailable")
        let history = try SQLite(url: paths.codexRoot.appendingPathComponent("thread_history_1.sqlite"), readOnly: false)
        try history.execute("CREATE TABLE thread_items(thread_id TEXT,item_json TEXT)")
        let provider = CodexProvider(paths: paths)
        let chats = try provider.discover()
        XCTAssertEqual(try provider.body(for: XCTUnwrap(chats.first { $0.record.identity.externalID == "fallback" })), "Preserved fallback conversation")
        XCTAssertNil(try provider.body(for: XCTUnwrap(chats.first { $0.record.identity.externalID == "unavailable" })))
    }
    private func cursorState() throws -> SQLite {
        let db = try SQLite(url: paths.cursorRoot.appendingPathComponent("state.vscdb"), readOnly: false)
        try db.execute("CREATE TABLE composerHeaders(composerId TEXT PRIMARY KEY,workspaceId TEXT,lastUpdatedAt INTEGER,createdAt INTEGER,isArchived INTEGER,isSubagent INTEGER,checkpointAt INTEGER,value TEXT)")
        try db.execute("CREATE TABLE cursorDiskKV(key TEXT PRIMARY KEY,value BLOB)")
        try db.execute("CREATE TABLE ItemTable(key TEXT PRIMARY KEY,value TEXT)")
        return db
    }
    private func cursorHeader(_ db: SQLite, id: String, name: String = "Cursor chat", subagent: Bool = false) throws {
        let value = try object(["name": name, "workspaceIdentifier": ["uri": ["fsPath": "/work/cursor"]]])
        try db.execute("INSERT INTO composerHeaders VALUES(?, 'workspace',2000000,1000000,0,?,1,?)", [.text(id), .integer(subagent ? 1 : 0), .text(value)])
    }
    private func cursorSearch() throws -> SQLite {
        let db = try SQLite(url: paths.cursorRoot.appendingPathComponent("conversation-search.db"), readOnly: false)
        try db.execute("CREATE TABLE conversations(fts_rowid INTEGER PRIMARY KEY,source TEXT,scope TEXT,id TEXT,title TEXT,updated_at INTEGER,is_archived INTEGER,root_fingerprint TEXT,cache_fingerprint TEXT)")
        try db.execute("CREATE VIRTUAL TABLE conversation_fts USING fts5(title,body,branches)")
        return db
    }
    func testCursorReadsFTSAndDeduplicatesCloudCopy() throws {
        let state = try cursorState(); try cursorHeader(state, id: "shared", name: "Local title")
        let search = try cursorSearch()
        try search.execute("INSERT INTO conversations VALUES(1,'cloud-cache','cloud','shared','Cloud title',3000000,1,NULL,'cache')")
        try search.execute("INSERT INTO conversations VALUES(2,'local','','shared','Local title',2000000,0,'root',NULL)")
        try search.execute("INSERT INTO conversation_fts(rowid,title,body,branches) VALUES(1,'Cloud title','Cloud duplicate','')")
        try search.execute("INSERT INTO conversation_fts(rowid,title,body,branches) VALUES(2,'Local title','Local conversation body','')")
        let sourceURL = paths.cursorRoot.appendingPathComponent("state.vscdb")
        let before = try Data(contentsOf: sourceURL)
        let provider = CursorProvider(paths: paths)
        let chats = try provider.discover()
        XCTAssertEqual(chats.map { $0.record.title }, ["Local title"])
        XCTAssertEqual(chats.first?.record.projectPath, "/work/cursor")
        XCTAssertEqual(try provider.body(for: XCTUnwrap(chats.first)), "Local conversation body")
        XCTAssertEqual(try Data(contentsOf: sourceURL), before)
    }
    func testCursorBackfillsUnindexedBubblesAndRejectsToolMessages() throws {
        let state = try cursorState(); try cursorHeader(state, id: "unindexed")
        let composer = try object(["fullConversationHeadersOnly": [["bubbleId": "human", "type": 1], ["bubbleId": "agent", "type": 2], ["bubbleId": "tool", "type": 3]]])
        try state.execute("INSERT INTO cursorDiskKV VALUES('composerData:unindexed',?)", [.text(composer)])
        try state.execute("INSERT INTO cursorDiskKV VALUES('bubbleId:unindexed:human',?)", [.text(try object(["type": 1, "text": "Human request"]))])
        try state.execute("INSERT INTO cursorDiskKV VALUES('bubbleId:unindexed:agent',?)", [.text(try object(["type": 2, "text": "Agent response"]))])
        let provider = CursorProvider(paths: paths)
        XCTAssertEqual(try provider.body(for: XCTUnwrap(provider.discover().first)), "Human request\nAgent response")
    }
    func testCursorSeparatesEmptyChatFromUnavailableHistory() throws {
        let state = try cursorState()
        try cursorHeader(state, id: "empty")
        try cursorHeader(state, id: "missing")
        try state.execute("INSERT INTO cursorDiskKV VALUES('composerData:empty','{}')")
        let provider = CursorProvider(paths: paths)
        let chats = try provider.discover()
        XCTAssertEqual(try provider.body(for: XCTUnwrap(chats.first { $0.record.identity.externalID == "empty" })), "")
        XCTAssertNil(try provider.body(for: XCTUnwrap(chats.first { $0.record.identity.externalID == "missing" })))
    }
    func testCursorReturnsFTSWithIncompleteDiscoveryWhenStateIsUnsupported() throws {
        let state = try SQLite(url: paths.cursorRoot.appendingPathComponent("state.vscdb"), readOnly: false)
        try state.execute("CREATE TABLE unsupported(value TEXT)")
        let search = try cursorSearch()
        try search.execute("INSERT INTO conversations VALUES(1,'local','','partial','Visible cached chat',2000000,0,'root',NULL)")
        try search.execute("INSERT INTO conversation_fts(rowid,title,body,branches) VALUES(1,'Visible cached chat','Accessible cached text','')")
        let provider = CursorProvider(paths: paths)
        let chats = try provider.discover()
        XCTAssertEqual(chats.map { $0.record.title }, ["Visible cached chat"])
        XCTAssertEqual(try provider.body(for: XCTUnwrap(chats.first)), "Accessible cached text")
        XCTAssertFalse(provider.discoveryComplete)
        XCTAssertEqual(provider.discoveryWarning, "Cursor chat headers unavailable: Unsupported composerHeaders schema")
    }
    func testCursorReturnsFTSWithWarningWhenStateIsCorrupt() throws {
        try "not a SQLite database".write(to: paths.cursorRoot.appendingPathComponent("state.vscdb"), atomically: true, encoding: .utf8)
        let search = try cursorSearch()
        try search.execute("INSERT INTO conversations VALUES(1,'cloud-cache','cloud','cloud-chat','Cloud cached chat',2000000,0,NULL,'cache')")
        try search.execute("INSERT INTO conversation_fts(rowid,title,body,branches) VALUES(1,'Cloud cached chat','Cloud cached text','')")
        let provider = CursorProvider(paths: paths)
        let chats = try provider.discover()
        XCTAssertEqual(chats.map { $0.record.title }, ["Cloud cached chat"])
        XCTAssertFalse(provider.discoveryComplete)
        XCTAssertTrue(try XCTUnwrap(provider.discoveryWarning).contains("Cursor chat headers unavailable:"))
    }
    func testCursorUnsupportedSourcesThrowInsteadOfEmptySuccess() throws {
        let state = try SQLite(url: paths.cursorRoot.appendingPathComponent("state.vscdb"), readOnly: false)
        try state.execute("CREATE TABLE unsupported(value TEXT)")
        let search = try SQLite(url: paths.cursorRoot.appendingPathComponent("conversation-search.db"), readOnly: false)
        try search.execute("CREATE TABLE unsupported(value TEXT)")
        let provider = CursorProvider(paths: paths)
        XCTAssertThrowsError(try provider.discover())
        XCTAssertFalse(provider.discoveryComplete)
        XCTAssertEqual(provider.discoveryWarning, "Cursor search database unavailable: Unsupported conversations schema; Cursor chat headers unavailable: Unsupported composerHeaders schema")
    }
    func testCursorSupportedEmptySourcesCompleteAndResetWarning() throws {
        let provider = CursorProvider(paths: paths)
        XCTAssertThrowsError(try provider.discover())
        XCTAssertFalse(provider.discoveryComplete)
        _ = try cursorState()
        _ = try cursorSearch()
        XCTAssertEqual(try provider.discover().count, 0)
        XCTAssertTrue(provider.discoveryComplete)
        XCTAssertNil(provider.discoveryWarning)
    }
    func testCursorHeaderOnlyDiscoveryKeepsCachedRowsWhenSearchIsMissing() throws {
        let state = try cursorState()
        try cursorHeader(state, id: "header-only")
        let provider = CursorProvider(paths: paths)
        XCTAssertEqual(try provider.discover().map { $0.record.identity.externalID }, ["header-only"])
        XCTAssertFalse(provider.discoveryComplete)
        XCTAssertTrue(try XCTUnwrap(provider.discoveryWarning).contains("Cursor search database unavailable:"))
    }
    func testMissingSourcesFailWithoutCreatingDatabases() throws {
        XCTAssertThrowsError(try CodexProvider(paths: paths).discover())
        XCTAssertThrowsError(try CursorProvider(paths: paths).discover())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.codexRoot.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.cursorRoot.path), [])
    }
}
