import Foundation

private func jsonObject(_ text: String) -> [String: Any]? {
    guard let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
    return value as? [String: Any]
}

private func timestamp(_ value: Double) -> Date {
    Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value)
}

private func string(_ row: [String: SQLValue], _ key: String) -> String { row[key]?.string ?? "" }
private func number(_ row: [String: SQLValue], _ key: String) -> Double { row[key]?.double ?? 0 }
private func bool(_ row: [String: SQLValue], _ key: String) -> Bool { row[key]?.int == 1 }
private func fresh(_ date: Date, now: Date) -> Bool { now.timeIntervalSince(date) >= -60 && now.timeIntervalSince(date) < 300 }

private func fileRevision(_ path: String) -> String {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return "missing" }
    let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    let date = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    return "\(size):\(date)"
}

private func readLines(_ url: URL, visit: (String) throws -> Void) throws {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var pending = Data()
    while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
        pending.append(chunk)
        while let end = pending.firstIndex(of: 10) {
            let line = String(decoding: pending[..<end], as: UTF8.self)
            try visit(line)
            pending.removeSubrange(...end)
        }
    }
    if !pending.isEmpty { try visit(String(decoding: pending, as: UTF8.self)) }
}

public final class CodexProvider: ChatProvider {
    public let source = ChatSource.codex
    private let paths: SourcePaths
    private let appRunning: Bool
    private let now: Date
    private var history: SQLite?
    private var historyColumns = Set<String>()
    private var paginatedIDs = Set<String>()
    public init(paths: SourcePaths = SourcePaths(), appRunning: Bool = false, now: Date = Date()) {
        self.paths = paths; self.appRunning = appRunning; self.now = now
    }
    public func discover() throws -> [SourceChat] {
        let files = try FileManager.default.contentsOfDirectory(at: paths.codexRoot, includingPropertiesForKeys: nil)
        let candidates = files.filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }.sorted {
            let left = Int($0.deletingPathExtension().lastPathComponent.dropFirst(6)) ?? 0
            let right = Int($1.deletingPathExtension().lastPathComponent.dropFirst(6)) ?? 0
            return left > right
        }
        guard let url = candidates.first else { throw SQLiteError(description: "Codex history is not installed at \(paths.codexRoot.path)") }
        let metadata = try SQLite(url: url)
        let columns = try metadata.columns("threads")
        guard columns.contains("id"), columns.contains("title") else { throw SQLiteError(description: "Unsupported Codex threads schema") }
        let order = columns.contains("updated_at_ms") ? "COALESCE(updated_at_ms,updated_at * 1000)" : (columns.contains("updated_at") ? "updated_at" : "id")
        let rows = try metadata.query("SELECT * FROM threads ORDER BY \(order) DESC")
        paginatedIDs = Set(rows.filter { string($0, "history_mode") == "paginated" }.map { string($0, "id") })
        let historyURL = paths.codexRoot.appendingPathComponent("thread_history_1.sqlite")
        history = try? SQLite(url: historyURL)
        historyColumns = (try? history?.columns("thread_items")) ?? []
        var revisions: [String: String] = [:]
        var turns: [String: [String: SQLValue]] = [:]
        if let history, historyColumns.contains("item_type") {
            let updated = historyColumns.contains("updated_at_ordinal") ? "MAX(updated_at_ordinal)" : "0"
            let items = try history.query("SELECT thread_id, COUNT(*) AS count, MAX(rollout_ordinal) AS ordinal, \(updated) AS revision FROM thread_items WHERE item_type IN ('userMessage','agentMessage') GROUP BY thread_id")
            for item in items { revisions[string(item, "thread_id")] = "\(string(item, "count")):\(string(item, "ordinal")):\(string(item, "revision"))" }
            if (try? history.columns("thread_turns").contains("status")) == true {
                for turn in try history.query("SELECT * FROM thread_turns ORDER BY rollout_ordinal DESC") where turns[string(turn, "thread_id")] == nil { turns[string(turn, "thread_id")] = turn }
            }
        }
        return rows.compactMap { row in
            let id = string(row, "id")
            guard !id.isEmpty else { return nil }
            let sourceText = string(row, "source")
            let subagent = string(row, "thread_source") == "subagent" || sourceText.contains("\"subagent\"")
            let updateValue = max(number(row, "updated_at_ms"), number(row, "recency_at_ms"))
            let updated = updateValue > 0 ? Date(timeIntervalSince1970: updateValue / 1000) : timestamp(number(row, "updated_at"))
            let rollout = string(row, "rollout_path")
            let preview = string(row, "preview").isEmpty ? string(row, "first_user_message") : string(row, "preview")
            let displayName = string(row, "name").trimmingCharacters(in: .whitespacesAndNewlines)
            let rawTitle = displayName.isEmpty ? string(row, "title").trimmingCharacters(in: .whitespacesAndNewlines) : displayName
            var active = false
            if let turn = turns[id] {
                active = string(turn, "status") == "inProgress" && fresh(updated, now: now)
            } else if !rollout.isEmpty, fresh(updated, now: now) {
                active = legacyActive(rollout)
            }
            let revision = "\(string(row, "updated_at")):\(updateValue):\(revisions[id] ?? fileRevision(rollout))"
            let record = ChatRecord(identity: ChatID(source: .codex, externalID: id), title: rawTitle.isEmpty ? "Untitled Codex chat" : rawTitle, projectPath: string(row, "cwd"), updatedAt: updated, archived: bool(row, "archived"), subagent: subagent, activity: appRunning && active ? .detected : .idle, preview: preview, revision: revision)
            return SourceChat(record: record, locator: rollout)
        }
    }
    public func body(for chat: SourceChat) throws -> String? {
        if let history, historyColumns.contains("item_type") {
            let rows = try history.query("SELECT item_type,item_json FROM thread_items WHERE thread_id=? AND item_type IN ('userMessage','agentMessage') ORDER BY rollout_ordinal", [.text(chat.record.identity.externalID)])
            if !rows.isEmpty {
                return try rows.map { row -> String in
                    guard let item = jsonObject(string(row, "item_json")) else { throw SQLiteError(description: "Unreadable Codex message JSON") }
                    if string(row, "item_type") == "agentMessage" { return item["text"] as? String ?? "" }
                    return (item["content"] as? [[String: Any]])?.compactMap { block -> String? in
                        guard block["type"] as? String == "text" || block["type"] as? String == "input_text" else { return nil }
                        return block["text"] as? String
                    }.joined(separator: "\n") ?? ""
                }.joined(separator: "\n")
            }
            if paginatedIDs.contains(chat.record.identity.externalID) { return "" }
        }
        guard !chat.locator.isEmpty, FileManager.default.fileExists(atPath: chat.locator) else { return nil }
        var messages: [String] = []
        try readLines(URL(fileURLWithPath: chat.locator)) { line in
            guard let envelope = jsonObject(line), envelope["type"] as? String == "response_item", let payload = envelope["payload"] as? [String: Any], payload["type"] as? String == "message", let role = payload["role"] as? String, role == "user" || role == "assistant", let content = payload["content"] as? [[String: Any]] else { return }
            let text = content.compactMap { block -> String? in
                guard let kind = block["type"] as? String, ["input_text", "output_text", "text"].contains(kind) else { return nil }
                return block["text"] as? String
            }.joined(separator: "\n")
            if !text.isEmpty { messages.append(text) }
        }
        return messages.joined(separator: "\n")
    }
    private func legacyActive(_ path: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return false }
        try? handle.seek(toOffset: size > 131072 ? size - 131072 : 0)
        guard let data = try? handle.readToEnd() else { return false }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
            guard let item = jsonObject(String(line)), item["type"] as? String == "event_msg", let payload = item["payload"] as? [String: Any], let kind = payload["type"] as? String else { continue }
            if ["task_started", "task_complete", "turn_aborted"].contains(kind) { return kind == "task_started" }
        }
        return false
    }
}

public final class CursorProvider: ChatProvider {
    public let source = ChatSource.cursor
    public private(set) var discoveryComplete = true
    public private(set) var discoveryWarning: String?
    private let paths: SourcePaths
    private let appRunning: Bool
    private let now: Date
    private var state: SQLite?
    private var search: SQLite?
    private var searchRows: [String: [String: SQLValue]] = [:]
    public init(paths: SourcePaths = SourcePaths(), appRunning: Bool = false, now: Date = Date()) {
        self.paths = paths; self.appRunning = appRunning; self.now = now
    }
    public func discover() throws -> [SourceChat] {
        discoveryComplete = true
        discoveryWarning = nil
        state = nil
        search = nil
        searchRows = [:]
        var warnings: [String] = []
        var searchEnumerated = false
        var headersEnumerated = false
        var headers: [[String: SQLValue]] = []
        do {
            let database = try SQLite(url: paths.cursorRoot.appendingPathComponent("conversation-search.db"))
            search = database
            let columns = try database.columns("conversations")
            let required: Set<String> = ["id", "fts_rowid", "source", "updated_at", "title"]
            guard required.isSubset(of: columns) else { throw SQLiteError(description: "Unsupported conversations schema") }
            let rows = try database.query("SELECT * FROM conversations ORDER BY CASE WHEN source='local' THEN 0 ELSE 1 END, updated_at DESC")
            for row in rows where searchRows[string(row, "id")] == nil { searchRows[string(row, "id")] = row }
            searchEnumerated = true
        } catch {
            warnings.append("Cursor search database unavailable: \(error)")
        }
        do {
            let database = try SQLite(url: paths.cursorRoot.appendingPathComponent("state.vscdb"))
            state = database
            let columns = try database.columns("composerHeaders")
            let required: Set<String> = ["composerId", "lastUpdatedAt", "value"]
            guard required.isSubset(of: columns) else { throw SQLiteError(description: "Unsupported composerHeaders schema") }
            headers = try database.query("SELECT * FROM composerHeaders ORDER BY lastUpdatedAt DESC")
            headersEnumerated = true
        } catch {
            warnings.append("Cursor chat headers unavailable: \(error)")
        }
        discoveryComplete = headersEnumerated && searchEnumerated
        discoveryWarning = warnings.isEmpty ? nil : warnings.joined(separator: "; ")
        guard headersEnumerated || searchEnumerated else {
            throw SQLiteError(description: discoveryWarning ?? "Cursor history is unavailable")
        }
        var workspacePaths: [String: String] = [:]
        if let state, let row = try? state.query("SELECT value FROM ItemTable WHERE key='workspaceMetadata.entries'").first, let object = jsonObject(string(row, "value")) {
            for (id, entry) in object {
                if let entry = entry as? [String: Any] { workspacePaths[id] = entry["displayPath"] as? String ?? entry["folderUri"] as? String }
            }
        }
        var result: [String: SourceChat] = [:]
        for row in headers {
            let id = string(row, "composerId")
            guard !id.isEmpty else { continue }
            let object = jsonObject(string(row, "value")) ?? [:]
            let fts = searchRows[id]
            let name = object["name"] as? String ?? fts.map { string($0, "title") } ?? ""
            let updated = Date(timeIntervalSince1970: max(number(row, "lastUpdatedAt"), fts.map { number($0, "updated_at") } ?? 0) / 1000)
            let workspace = object["workspaceIdentifier"] as? [String: Any]
            let uri = workspace?["uri"] as? [String: Any]
            let project = uri?["fsPath"] as? String ?? uri?["path"] as? String ?? workspacePaths[string(row, "workspaceId")] ?? ""
            let unfinished = (object["unfinishedRunAt"] as? NSNumber)?.doubleValue ?? 0
            let active = appRunning && unfinished > 0 && fresh(updated, now: now)
            let revision = [string(row, "lastUpdatedAt"), string(row, "checkpointAt"), fts.map { string($0, "root_fingerprint") } ?? "", fts.map { string($0, "cache_fingerprint") } ?? ""].joined(separator: ":")
            let record = ChatRecord(identity: ChatID(source: .cursor, externalID: id), title: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Cursor chat" : name, projectPath: project, updatedAt: updated, archived: bool(row, "isArchived"), subagent: bool(row, "isSubagent"), activity: active ? .detected : .idle, revision: revision)
            result[id] = SourceChat(record: record, locator: id)
        }
        for (id, row) in searchRows where result[id] == nil {
            let name = string(row, "title")
            let revision = [string(row, "updated_at"), string(row, "root_fingerprint"), string(row, "cache_fingerprint")].joined(separator: ":")
            let record = ChatRecord(identity: ChatID(source: .cursor, externalID: id), title: name.isEmpty ? "Untitled Cursor chat" : name, updatedAt: Date(timeIntervalSince1970: number(row, "updated_at") / 1000), archived: bool(row, "is_archived"), subagent: id.hasPrefix("task-"), revision: revision)
            result[id] = SourceChat(record: record, locator: id)
        }
        return result.values.sorted { $0.record.updatedAt > $1.record.updatedAt }
    }
    public func body(for chat: SourceChat) throws -> String? {
        let id = chat.record.identity.externalID
        if let row = searchRows[id], let search, let rowID = row["fts_rowid"] {
            if let body = try search.query("SELECT body FROM conversation_fts WHERE rowid=?", [rowID]).first?["body"] { return body.string }
        }
        guard let state, let composerRow = try state.query("SELECT value FROM cursorDiskKV WHERE key=?", [.text("composerData:" + id)]).first, let composer = jsonObject(string(composerRow, "value")) else { return nil }
        var bubbles = composer["fullConversationHeadersOnly"] as? [[String: Any]] ?? []
        if bubbles.isEmpty, let conversation = composer["conversation"] as? [[String: Any]] { bubbles = conversation }
        var messages: [String] = []
        var missing = false
        for header in bubbles {
            let type = (header["type"] as? NSNumber)?.intValue
            guard type == nil || type == 1 || type == 2 else { continue }
            var bubble = header
            if header["text"] == nil, let bubbleID = header["bubbleId"] as? String {
                if let row = try state.query("SELECT value FROM cursorDiskKV WHERE key=?", [.text("bubbleId:" + id + ":" + bubbleID)]).first, let value = jsonObject(string(row, "value")) { bubble = value }
                else { missing = true; continue }
            }
            let bubbleType = (bubble["type"] as? NSNumber)?.intValue
            guard bubbleType == nil || bubbleType == 1 || bubbleType == 2 else { continue }
            if let text = bubble["text"] as? String, !text.isEmpty { messages.append(text) }
        }
        return missing ? nil : messages.joined(separator: "\n")
    }
}
