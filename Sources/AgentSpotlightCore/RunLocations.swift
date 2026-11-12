import Foundation

public enum CursorEnvironmentPreference: String, Sendable {
    case lastUsed = "last-used"
    case cloud, local
    case newWorktree = "new-worktree"
    case sharedPool = "shared-pool"
    case remoteControl = "remote-control"

    public var title: String {
        switch self {
        case .lastUsed: return "Last used"
        case .cloud: return "Cloud"
        case .local: return "Local"
        case .newWorktree: return "Local worktree"
        case .sharedPool: return "Remote machines"
        case .remoteControl: return "Remote control"
        }
    }
}

public enum DraftEnvironment: String, Sendable {
    case local = "Local", cloud = "Cloud", remote = "Remote"
}

public enum AppRunLocation: Equatable, Sendable {
    case codexLocal
    case cursor(preference: CursorEnvironmentPreference, savedDraft: DraftEnvironment?)
    case unavailable

    public var title: String {
        switch self {
        case .codexLocal: return "Local"
        case .cursor(let preference, let draft):
            guard preference == .lastUsed else { return preference.title }
            return draft.map { "Last used · \($0.rawValue) draft" } ?? "Last used · check Cursor"
        case .unavailable: return "Check in Cursor"
        }
    }

    public var note: String {
        switch self {
        case .codexLocal:
            return "This launcher opens a local Codex chat. Cloud launch is not supported by this handoff."
        case .cursor(.lastUsed, _):
            return "Cursor uses Last Used. The saved draft is a hint; the active project can change the target. Confirm in Cursor before sending."
        case .cursor:
            return "Cursor's saved Default Environment. Project selection can override it. Change it in Cursor Settings → Agents."
        case .unavailable:
            return "Cursor's run location could not be read. Check its environment picker before sending."
        }
    }

    static func fromCursor(preference: String?, draftTarget: Data?) -> AppRunLocation {
        let raw = preference.map { text in
            (try? JSONDecoder().decode(String.self, from: Data(text.utf8))) ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? "last-used"
        guard let preference = CursorEnvironmentPreference(rawValue: raw) else { return .unavailable }
        var draft: DraftEnvironment?
        if let data = draftTarget,
           let target = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let environment = target["environment"] as? [String: Any] {
            switch target["type"] as? String {
            case "new":
                draft = environment["usePrivateWorker"] as? Bool == true ? .remote : .cloud
            case "existing":
                let uri = environment["uri"] as? [String: Any]
                if uri?["scheme"] as? String == "file" { draft = .local }
                else if uri?["scheme"] as? String == "vscode-remote" { draft = .remote }
                else if environment["id"] as? String == "empty-window" { draft = .local }
            default: break
            }
        }
        return .cursor(preference: preference, savedDraft: draft)
    }
}
