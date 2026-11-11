import Foundation

public actor ChatIndex {
    private let db: SQLite
    private var status = IndexStatus()

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Agent Spotlight/search.sqlite")
    }

    public init(url: URL = ChatIndex.defaultURL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        db = try SQLite(url: url, readOnly: false)
        try db.execute("PRAGMA journal_mode=WAL")
        try db.execute("PRAGMA synchronous=NORMAL")
        try db.execute("CREATE TABLE IF NOT EXISTS chats (id TEXT PRIMARY KEY, source TEXT NOT NULL, external_id TEXT NOT NULL, title TEXT NOT NULL, project TEXT NOT NULL, updated REAL NOT NULL, archived INTEGER NOT NULL, subagent INTEGER NOT NULL, activity INTEGER NOT NULL, preview TEXT NOT NULL, revision TEXT NOT NULL DEFAULT '', indexed INTEGER NOT NULL DEFAULT 0)")
        try db.execute("CREATE INDEX IF NOT EXISTS chats_recency ON chats(activity DESC, updated DESC)")
        try db.execute("CREATE VIRTUAL TABLE IF NOT EXISTS chats_fts USING fts5(id UNINDEXED, title, project, body, tokenize='unicode61 remove_diacritics 2', prefix='2 3')")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func currentStatus() -> IndexStatus { status }

    public func refresh(providers: [any ChatProvider]) async {
        guard !status.refreshing else { return }
        status.refreshing = true
        status.providers = providers.map { ProviderStatus(source: $0.source) }
        defer { status.refreshing = false }
        var work: [(any ChatProvider, [SourceChat])] = []
        for provider in providers {
            do {
                let chats = try provider.discover().sorted { $0.record.updatedAt > $1.record.updatedAt }
                try seed(chats, source: provider.source, prune: provider.discoveryComplete)
                if let warning = provider.discoveryWarning { setError(provider.source, warning) }
                updateStatus(provider.source, discovered: chats.count)
                work.append((provider, chats))
            } catch {
                setError(provider.source, "\(provider.source.displayName): \(error)")
            }
            await Task.yield()
        }
        let ordered = work.flatMap { provider, chats in chats.map { (provider, $0) } }.sorted { lhs, rhs in
            if lhs.1.record.activity.rawValue != rhs.1.record.activity.rawValue { return lhs.1.record.activity.rawValue > rhs.1.record.activity.rawValue }
            return lhs.1.record.updatedAt > rhs.1.record.updatedAt
        }
        for (provider, chat) in ordered {
            if Task.isCancelled { break }
            do {
                let previous = try db.query("SELECT revision,indexed FROM chats WHERE id=?", [.text(chat.record.id)]).first
                if previous?["revision"]?.string != chat.record.revision || previous?["indexed"]?.int != 1 {
                    if let body = try provider.body(for: chat) {
                        try replaceText(chat.record, body: body)
                        try db.execute("UPDATE chats SET revision=?,indexed=1 WHERE id=?", [.text(chat.record.revision), .text(chat.record.id)])
                    } else {
                        markUnavailable(provider.source)
                    }
                }
            } catch {
                markUnavailable(provider.source)
                setError(provider.source, "Some \(provider.source.displayName) messages could not be read. \(error)")
            }
            updateIndexed(provider.source)
            await Task.yield()
        }
    }

    public func search(_ query: SearchQuery) throws -> [ChatRecord] {
        var conditions: [String] = []
        var values: [SQLValue] = []
        let expression = query.ftsExpression
        if expression == nil && !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        if let source = query.source { conditions.append("c.source=?"); values.append(.text(source.rawValue)) }
        if !query.includeArchived { conditions.append("c.archived=0") }
        if !query.includeSubagents { conditions.append("c.subagent=0") }
        if let expression { conditions.append("chats_fts MATCH ?"); values.append(.text(expression)) }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let snippet = expression == nil ? "c.preview" : "snippet(chats_fts,3,'','','…',24)"
        let join = expression == nil ? "" : "JOIN chats_fts ON chats_fts.rowid=c.rowid"
        values.append(.real(Date().addingTimeInterval(-600).timeIntervalSince1970))
        values.append(.integer(Int64(min(max(query.limit, 1), 200))))
        let rows = try db.query("SELECT c.*, \(snippet) AS excerpt FROM chats c \(join) \(whereClause) ORDER BY CASE WHEN c.activity=1 AND c.updated>? THEN 1 ELSE 0 END DESC,c.updated DESC,c.id ASC LIMIT ?", values)
        return rows.compactMap { row in
            guard let source = ChatSource(rawValue: row["source"]?.string ?? "") else { return nil }
            let updated = Date(timeIntervalSince1970: row["updated"]?.double ?? 0)
            let fresh = Date().timeIntervalSince(updated) < 600
            return ChatRecord(identity: ChatID(source: source, externalID: row["external_id"]?.string ?? ""), title: row["title"]?.string ?? "Untitled chat", projectPath: row["project"]?.string ?? "", updatedAt: updated, archived: row["archived"]?.int == 1, subagent: row["subagent"]?.int == 1, activity: fresh && row["activity"]?.int == 1 ? .detected : .idle, preview: row["excerpt"]?.string ?? "", revision: row["revision"]?.string ?? "")
        }
    }

    private func seed(_ chats: [SourceChat], source: ChatSource, prune: Bool) throws {
        try db.execute("BEGIN IMMEDIATE")
        do {
            let existing = try db.query("SELECT id,title,project FROM chats WHERE source=?", [.text(source.rawValue)])
            let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0["id"]!.string, $0) })
            let live = Set(chats.map { $0.record.id })
            for item in chats {
                let record = item.record
                let values: [SQLValue] = [.text(record.id), .text(source.rawValue), .text(record.identity.externalID), .text(record.title), .text(record.projectPath), .real(record.updatedAt.timeIntervalSince1970), .integer(record.archived ? 1 : 0), .integer(record.subagent ? 1 : 0), .integer(Int64(record.activity.rawValue)), .text(record.preview)]
                try db.execute("INSERT INTO chats(id,source,external_id,title,project,updated,archived,subagent,activity,preview) VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,project=excluded.project,updated=excluded.updated,archived=excluded.archived,subagent=excluded.subagent,activity=excluded.activity,preview=CASE WHEN excluded.preview<>'' THEN excluded.preview ELSE chats.preview END", values)
                if byID[record.id] == nil {
                    try db.execute("INSERT INTO chats_fts(rowid,id,title,project,body) VALUES((SELECT rowid FROM chats WHERE id=?),?,?,?,?)", [.text(record.id), .text(record.id), .text(record.title), .text(record.projectPath), .text(record.preview)])
                } else if byID[record.id]?["title"]?.string != record.title || byID[record.id]?["project"]?.string != record.projectPath {
                    try db.execute("UPDATE chats_fts SET title=?,project=? WHERE rowid=(SELECT rowid FROM chats WHERE id=?)", [.text(record.title), .text(record.projectPath), .text(record.id)])
                }
            }
            for row in existing where prune && !live.contains(row["id"]!.string) {
                try db.execute("DELETE FROM chats_fts WHERE rowid=(SELECT rowid FROM chats WHERE id=?)", [.text(row["id"]!.string)])
                try db.execute("DELETE FROM chats WHERE id=?", [.text(row["id"]!.string)])
            }
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    private func replaceText(_ record: ChatRecord, body: String) throws {
        if record.preview.isEmpty {
            let excerpt = body.split(whereSeparator: \.isWhitespace).prefix(35).joined(separator: " ")
            try db.execute("UPDATE chats SET preview=? WHERE id=?", [.text(String(excerpt.prefix(240))), .text(record.id)])
        }
        try db.execute("UPDATE chats_fts SET title=?,project=?,body=? WHERE rowid=(SELECT rowid FROM chats WHERE id=?)", [.text(record.title), .text(record.projectPath), .text(body), .text(record.id)])
    }
    private func updateStatus(_ source: ChatSource, discovered: Int) {
        guard let index = status.providers.firstIndex(where: { $0.source == source }) else { return }
        let cached = (try? db.query("SELECT count(*) AS n FROM chats WHERE source=?", [.text(source.rawValue)]).first?["n"]?.int) ?? discovered
        status.providers[index].discovered = max(discovered, cached)
        updateIndexed(source)
    }
    private func updateIndexed(_ source: ChatSource) {
        guard let index = status.providers.firstIndex(where: { $0.source == source }) else { return }
        status.providers[index].indexed = (try? db.query("SELECT count(*) AS n FROM chats WHERE source=? AND indexed=1", [.text(source.rawValue)]).first?["n"]?.int) ?? 0
    }
    private func markUnavailable(_ source: ChatSource) {
        guard let index = status.providers.firstIndex(where: { $0.source == source }) else { return }
        status.providers[index].unavailable += 1
    }
    private func setError(_ source: ChatSource, _ message: String) {
        guard let index = status.providers.firstIndex(where: { $0.source == source }) else { return }
        status.providers[index].error = message
    }
}
