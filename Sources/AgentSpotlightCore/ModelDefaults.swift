import Foundation

public enum AppModelDefault: Equatable, Sendable {
    case saved(String)
    case unknown(String)

    public var title: String {
        switch self {
        case .saved(let name): return name
        case .unknown: return "Check in app"
        }
    }

    public var note: String {
        switch self {
        case .saved: return "Saved app default. Project or chat settings can override it."
        case .unknown(let reason): return reason
        }
    }
}

public actor ModelDefaultsReader {
    private let paths: SourcePaths

    public init(paths: SourcePaths = SourcePaths()) { self.paths = paths }

    public func read() -> [ChatSource: AppModelDefault] {
        let codex: AppModelDefault
        do {
            codex = Self.codex(config: try String(contentsOf: paths.codexRoot.appendingPathComponent("config.toml"), encoding: .utf8))
        } catch { codex = .unknown("Codex's saved default could not be read. Check its model picker.") }
        let cursor: AppModelDefault
        do {
            let database = try SQLite(url: paths.cursorRoot.appendingPathComponent("state.vscdb"))
            let key = "src.vs.platform.reactivestorage.browser.reactiveStorageServiceImpl.persistentStorage.applicationUser"
            guard let json = try database.query("SELECT value FROM ItemTable WHERE key = ?", [.text(key)]).first?["value"]?.string,
                  let data = json.data(using: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
            cursor = try Self.cursor(data: data)
        } catch { cursor = .unknown("Cursor's saved default could not be read. Check its model picker.") }
        return [.codex: codex, .cursor: cursor]
    }

    static func codex(config: String) -> AppModelDefault {
        var values: [String: String] = [:]
        var multiline: String?
        for line in config.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if let delimiter = multiline {
                if line.contains(delimiter) { multiline = nil }
                continue
            }
            if line.hasPrefix("#") || line.isEmpty { continue }
            if line.hasPrefix("[") { break }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let raw = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("\"\"\"") || raw.hasPrefix("'''") {
                let delimiter = String(raw.prefix(3))
                if !raw.dropFirst(3).contains(delimiter) { multiline = delimiter }
                continue
            }
            guard ["model", "model_reasoning_effort", "service_tier", "profile"].contains(key) else { continue }
            guard let value = tomlString(raw) else { return .unknown("Codex's model settings could not be interpreted. Check its model picker.") }
            values[key] = value
        }
        if let profile = values["profile"], !profile.isEmpty {
            return .unknown("Codex uses profile \(profile). Check its model picker for the active model.")
        }
        guard let model = values["model"], !model.isEmpty else {
            return .unknown("Codex chooses its default model. Check its model picker.")
        }
        var parts = [model]
        if let effort = values["model_reasoning_effort"], !effort.isEmpty { parts.append(effort.capitalized) }
        if values["service_tier"] == "priority" { parts.append("Fast") }
        return .saved(parts.joined(separator: " · "))
    }

    private static func tomlString(_ text: String) -> String? {
        guard let quote = text.first, quote == "\"" || quote == "'" else { return nil }
        var escaped = false
        for index in text.indices.dropFirst() {
            let character = text[index]
            if escaped { escaped = false; continue }
            if quote == "\"", character == "\\" { escaped = true; continue }
            if character == quote {
                let remainder = text[text.index(after: index)...].trimmingCharacters(in: .whitespaces)
                guard remainder.isEmpty || remainder.hasPrefix("#") else { return nil }
                if quote == "'" { return String(text[text.index(after: text.startIndex)..<index]) }
                return try? JSONDecoder().decode(String.self, from: Data(text[...index].utf8))
            }
        }
        return nil
    }

    static func cursor(data: Data) throws -> AppModelDefault {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settings = root["aiSettings"] as? [String: Any],
              let configurations = settings["modelConfig"] as? [String: Any],
              let composer = configurations["composer"] as? [String: Any] else {
            return .unknown("Cursor's saved model settings are unavailable. Check its model picker.")
        }
        if settings["modelDefaultSwitchOnNewChat"] as? Bool == true {
            return .unknown("Cursor may reset the model on new chats. Check its model picker.")
        }
        let catalog = root["availableDefaultModels2"] as? [[String: Any]] ?? []
        let selections = composer["selectedModels"] as? [[String: Any]] ?? []
        var labels: [String] = []
        for selection in selections {
            guard let id = selection["modelId"] as? String, !id.isEmpty else { continue }
            let model = catalog.first { ($0["name"] as? String) == id }
            var parts = [model?["clientDisplayName"] as? String ?? (id == "default" ? "Auto" : id)]
            for parameter in selection["parameters"] as? [[String: String]] ?? [] {
                guard let value = parameter["value"], let key = parameter["id"] else { continue }
                switch key {
                case "effort", "reasoning_effort": parts.append(value.capitalized)
                case "fast" where value == "true": parts.append("Fast")
                case "context": parts.append(value.uppercased())
                case "thinking" where value == "true": parts.append("Thinking")
                default: break
                }
            }
            labels.append(parts.joined(separator: " · "))
        }
        if labels.isEmpty, let legacy = composer["modelName"] as? String, !legacy.isEmpty {
            labels = [legacy == "default" ? "Auto" : legacy]
        }
        guard !labels.isEmpty else { return .unknown("Cursor chooses its default model. Check its model picker.") }
        return .saved(labels.joined(separator: " + "))
    }
}
