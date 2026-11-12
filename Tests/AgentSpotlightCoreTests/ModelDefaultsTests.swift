import Foundation
import XCTest
@testable import AgentSpotlightCore

final class ModelDefaultsTests: XCTestCase {
    func testCodexReadsOnlyRootSettingsAndIgnoresComments() {
        let config = #"""
        # model = "wrong"
        model = 'example-codex' # saved default
        model_reasoning_effort = "high"
        service_tier = "priority"
        [profiles.other]
        model = "another-model"
        """#
        XCTAssertEqual(ModelDefaultsReader.codex(config: config), .saved("example-codex · High · Fast"))
    }

    func testCodexDoesNotReadModelsInsideMultilineInstructions() {
        let config = "developer_instructions = \"\"\"\nmodel = 'wrong'\n\"\"\"\nmodel = \"correct\"\n"
        XCTAssertEqual(ModelDefaultsReader.codex(config: config), .saved("correct"))
        XCTAssertEqual(ModelDefaultsReader.codex(config: "model = \"broken" ).title, "Check in app")
        XCTAssertEqual(ModelDefaultsReader.codex(config: "profile = 'work'\nmodel = 'base'" ).title, "Check in app")
        XCTAssertEqual(ModelDefaultsReader.codex(config: "[profiles.other]\nmodel = 'other'" ).title, "Check in app")
    }

    func testCursorReadsComposerChoiceAndParametersInsteadOfAnotherFeature() throws {
        let json = #"""
        {"aiSettings":{"modelConfig":{
          "cmd-k":{"modelName":"wrong"},
          "composer":{"modelName":"legacy","selectedModels":[{"modelId":"example-model","parameters":[
            {"id":"reasoning_effort","value":"high"},{"id":"fast","value":"true"},{"id":"context","value":"500k"}
          ]}]}}},"availableDefaultModels2":[{"name":"example-model","clientDisplayName":"Example Model"}]}
        """#
        XCTAssertEqual(try ModelDefaultsReader.cursor(data: Data(json.utf8)), .saved("Example Model · High · Fast · 500K"))
    }

    func testCursorAutoEnsemblesAndUnknownSettings() throws {
        let auto = #"{"aiSettings":{"modelConfig":{"composer":{"selectedModels":[{"modelId":"default","parameters":[]}]}}}}"#
        XCTAssertEqual(try ModelDefaultsReader.cursor(data: Data(auto.utf8)), .saved("Auto"))
        let ensemble = #"{"aiSettings":{"modelConfig":{"composer":{"selectedModels":[{"modelId":"one"},{"modelId":"two"}]}}}}"#
        XCTAssertEqual(try ModelDefaultsReader.cursor(data: Data(ensemble.utf8)), .saved("one + two"))
        let reset = #"{"aiSettings":{"modelDefaultSwitchOnNewChat":true,"modelConfig":{"composer":{"modelName":"old-choice"}}}}"#
        XCTAssertEqual(try ModelDefaultsReader.cursor(data: Data(reset.utf8)).title, "Check in app")
        XCTAssertEqual(try ModelDefaultsReader.cursor(data: Data("{}".utf8)).title, "Check in app")
        XCTAssertThrowsError(try ModelDefaultsReader.cursor(data: Data("broken".utf8)))
    }

    func testReaderRefreshesSavedValuesWithoutWritingToSourceStores() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config.toml")
        try "model = 'first'".write(to: config, atomically: true, encoding: .utf8)
        let databaseURL = root.appendingPathComponent("state.vscdb")
        do {
            let db = try SQLite(url: databaseURL, readOnly: false)
            try db.execute("CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)")
            try db.execute("INSERT INTO ItemTable VALUES (?, ?)", [
                .text("src.vs.platform.reactivestorage.browser.reactiveStorageServiceImpl.persistentStorage.applicationUser"),
                .text(#"{"aiSettings":{"modelConfig":{"composer":{"modelName":"cursor-saved"}}}}"#)
            ])
        }
        let before = try Data(contentsOf: databaseURL)
        let reader = ModelDefaultsReader(paths: SourcePaths(codexRoot: root, cursorRoot: root))
        let first = await reader.read()
        XCTAssertEqual(first[.codex], .saved("first"))
        XCTAssertEqual(first[.cursor], .saved("cursor-saved"))
        try "model = 'updated'".write(to: config, atomically: true, encoding: .utf8)
        let refreshed = await reader.read()
        XCTAssertEqual(refreshed[.codex], .saved("updated"))
        XCTAssertEqual(try Data(contentsOf: databaseURL), before)
        try FileManager.default.removeItem(at: config)
        let missing = await reader.read()
        XCTAssertEqual(missing[.codex]?.title, "Check in app")
    }

    func testDisplayPreferenceMigratesWithoutChangingExistingSettings() throws {
        let data = Data(#"{"shortcutModes":["codex","cursor","search"],"cursorPrefix":"Custom"}"#.utf8)
        var settings = try JSONDecoder().decode(LauncherSettings.self, from: data)
        XCTAssertTrue(settings.showModelDefaults)
        XCTAssertEqual(settings.cursorPrefix, "Custom")
        XCTAssertEqual(settings.shortcutModes, [.codex, .cursor, .search])
        settings.showModelDefaults = false
        XCTAssertFalse(try JSONDecoder().decode(LauncherSettings.self, from: JSONEncoder().encode(settings)).showModelDefaults)
    }
}
