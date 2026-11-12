import Foundation
import XCTest
@testable import AgentSpotlightCore

final class LauncherTests: XCTestCase {
    func testDefaultModesAndPrompts() {
        let settings = LauncherSettings()
        XCTAssertEqual(settings.shortcutModes, [.search, .cursor, .codex])
        XCTAssertEqual(settings.defaultMode, .search)
        XCTAssertEqual(settings.prompt(for: .cursor, draft: "Fix tests"), "/poteto_mode\n\nFix tests")
        XCTAssertEqual(settings.prompt(for: .codex, draft: "Fix tests"), "/poteto_mode\n\nFix tests")
    }

    func testRemappingSwapsActionsWithoutLosingAnAction() {
        var settings = LauncherSettings()
        settings.assign(.codex, toSlot: 0)
        XCTAssertEqual(settings.shortcutModes, [.codex, .cursor, .search])
        XCTAssertEqual(settings.shortcut(for: .search), "⌘3")
        XCTAssertEqual(settings.mode(forSlot: 0), .codex)
        settings.assign(.cursor, toSlot: 2)
        XCTAssertEqual(settings.shortcutModes, [.codex, .search, .cursor])
        settings.assign(.search, toSlot: 20)
        XCTAssertEqual(settings.shortcutModes, [.codex, .search, .cursor])
        XCTAssertNil(settings.mode(forSlot: -1))
    }

    func testSettingsRoundTripAndInvalidRecovery() throws {
        let suite = "AgentSpotlightTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = LauncherSettings()
        settings.assign(.cursor, toSlot: 0)
        settings.defaultMode = .codex
        settings.cursorPrefix = "Always use\n/poteto_mode"
        settings.codexPrefix = ""
        settings.save(to: defaults)
        XCTAssertEqual(LauncherSettings.load(from: defaults), settings)
        defaults.set(Data("broken".utf8), forKey: "launcherSettings")
        XCTAssertEqual(LauncherSettings.load(from: defaults), LauncherSettings())
        defaults.set(Data(#"{"shortcutModes":["search","search","cursor"],"cursorPrefix":"Custom"}"#.utf8), forKey: "launcherSettings")
        let repaired = LauncherSettings.load(from: defaults)
        XCTAssertEqual(repaired.shortcutModes, [.search, .cursor, .codex])
        XCTAssertEqual(repaired.cursorPrefix, "Custom")
    }

    func testPromptCompositionHandlesBlankParts() {
        var settings = LauncherSettings()
        settings.cursorPrefix = "  Always use /poteto_mode\n"
        XCTAssertEqual(settings.prompt(for: .cursor, draft: "  Check a & b + café\n"), "Always use /poteto_mode\n\nCheck a & b + café")
        XCTAssertEqual(settings.prompt(for: .cursor, draft: "  "), "Always use /poteto_mode")
        settings.cursorPrefix = ""
        XCTAssertEqual(settings.prompt(for: .cursor, draft: "Only my prompt"), "Only my prompt")
        XCTAssertEqual(settings.prompt(for: .cursor, draft: ""), "")
    }

    func testCodexDeepLinkPreservesCompletePrompt() throws {
        let prompt = "/poteto_mode\n\nFix C++ &foo=bar #tag? literal %2B = café 🥔"
        let url = try NewChatRequest(mode: .codex, prompt: prompt).deepLink()
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "prompt", value: prompt)])
        XCTAssertTrue(url.absoluteString.contains("%2B%2B"))
        XCTAssertFalse(url.absoluteString.contains("+"))
        XCTAssertEqual(components.scheme, "codex")
        XCTAssertEqual(components.host, "threads")
        XCTAssertEqual(components.path, "/new")
    }

    func testCursorDeepLinkSurvivesItsTwoStageQueryDecoding() throws {
        let prompt = "/poteto_mode\n\nFix C++ &foo=bar #tag? literal %2B = café 🥔"
        let url = try NewChatRequest(mode: .cursor, prompt: prompt).deepLink()
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let encodedQuery = try XCTUnwrap(components.percentEncodedQuery)
        let cursorQuery = try XCTUnwrap(encodedQuery.removingPercentEncoding)
        let parameters = cursorQuery.split(separator: "&")
        XCTAssertEqual(parameters.count, 1)
        let parameter = try XCTUnwrap(parameters.first).split(separator: "=", maxSplits: 1)
        XCTAssertEqual(parameter.first, "text")
        let received = String(parameter.last ?? "").replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        XCTAssertEqual(received, prompt)
        XCTAssertEqual(components.queryItems?.first?.value?.removingPercentEncoding, prompt)
        XCTAssertTrue(url.absoluteString.contains("%252B%252B"))
        XCTAssertFalse(url.absoluteString.contains("+"))
        XCTAssertEqual(components.scheme, "cursor")
        XCTAssertEqual(components.host, "anysphere.cursor-deeplink")
        XCTAssertEqual(components.path, "/prompt")
    }

    func testInvalidRequestsAndCursorLengthLimit() throws {
        XCTAssertThrowsError(try NewChatRequest(mode: .search, prompt: "Hello").deepLink())
        XCTAssertThrowsError(try NewChatRequest(mode: .cursor, prompt: String(repeating: "🥔", count: 1_000)).deepLink())
        XCTAssertNoThrow(try NewChatRequest(mode: .cursor, prompt: String(repeating: " ", count: 1_900)).deepLink())
        XCTAssertThrowsError(try NewChatRequest(mode: .cursor, prompt: String(repeating: " ", count: 2_000)).deepLink())
        XCTAssertNoThrow(try NewChatRequest(mode: .codex, prompt: String(repeating: "a", count: 10_000)).deepLink())
    }
}
