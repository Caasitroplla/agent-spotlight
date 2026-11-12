import Foundation
import XCTest
@testable import AgentSpotlightCore

final class RunLocationsTests: XCTestCase {
    func testSavedPreferenceWinsOverDraftHint() {
        let cloud = Data(#"{"type":"new","environment":{"id":"cloud-project"}}"#.utf8)
        for (raw, title) in [("cloud", "Cloud"), ("local", "Local"), ("new-worktree", "Local worktree"), ("shared-pool", "Remote machines"), ("remote-control", "Remote control")] {
            XCTAssertEqual(AppRunLocation.fromCursor(preference: raw, draftTarget: cloud).title, title)
        }
        XCTAssertEqual(AppRunLocation.fromCursor(preference: #""local""#, draftTarget: cloud).title, "Local")
        XCTAssertEqual(AppRunLocation.fromCursor(preference: "future-value", draftTarget: cloud), .unavailable)
    }

    func testLastUsedSeparatesCloudLocalRemoteAndUnknownDrafts() {
        let cases = [
            (#"{"type":"new","environment":{"id":"repo","usePrivateWorker":false}}"#, "Last used · Cloud draft"),
            (#"{"type":"new","environment":{"id":"repo","usePrivateWorker":true}}"#, "Last used · Remote draft"),
            (#"{"type":"existing","environment":{"id":"folder","uri":{"scheme":"file","path":"/project"}}}"#, "Last used · Local draft"),
            (#"{"type":"existing","environment":{"id":"ssh","uri":{"scheme":"vscode-remote"}}}"#, "Last used · Remote draft"),
            (#"{"type":"existing","environment":{"id":"unrecognized"}}"#, "Last used · check Cursor"),
            ("{}", "Last used · check Cursor"),
            ("broken", "Last used · check Cursor")
        ]
        for (json, title) in cases {
            XCTAssertEqual(AppRunLocation.fromCursor(preference: nil, draftTarget: Data(json.utf8)).title, title)
        }
    }

    func testReaderUsesOnlyEmptyDraftTargetAndRefreshesPreferenceReadOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.vscdb")
        do {
            let db = try SQLite(url: url, readOnly: false)
            try db.execute("CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)")
            try db.execute("CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT)")
            try db.execute("INSERT INTO cursorDiskKV VALUES (?, ?)", [
                .text("composerData:empty-state-draft"),
                .text(#"{"text":"Not used for location","draftTarget":{"type":"new","environment":{"id":"cloud"}}}"#)
            ])
        }
        let reader = ModelDefaultsReader(paths: SourcePaths(codexRoot: root, cursorRoot: root))
        let before = try Data(contentsOf: url)
        let defaults = await reader.readRunLocations()
        XCTAssertEqual(defaults[.codex], .codexLocal)
        XCTAssertEqual(defaults[.cursor], .cursor(preference: .lastUsed, savedDraft: .cloud))
        XCTAssertEqual(try Data(contentsOf: url), before)
        do {
            let db = try SQLite(url: url, readOnly: false)
            try db.execute("INSERT INTO ItemTable VALUES (?, ?)", [.text("cursor/newAgentDefaultEnvironment"), .text("local")])
            try db.execute("DROP TABLE cursorDiskKV")
        }
        let refreshed = await reader.readRunLocations()
        XCTAssertEqual(refreshed[.cursor], .cursor(preference: .local, savedDraft: nil))
    }

    func testMissingCursorStateDoesNotChangeCodexLocalHandoff() async {
        let absent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ModelDefaultsReader(paths: SourcePaths(codexRoot: absent, cursorRoot: absent))
        let locations = await reader.readRunLocations()
        XCTAssertEqual(locations[.cursor], .unavailable)
        XCTAssertEqual(locations[.codex], .codexLocal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
    }
}
