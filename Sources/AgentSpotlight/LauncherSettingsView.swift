import SwiftUI
import AgentSpotlightCore

struct LauncherSettingsView: View {
    @ObservedObject var model: SearchModel

    var body: some View {
        Form {
            Section {
                Picker("Open panel in", selection: $model.settings.defaultMode) {
                    ForEach(LauncherMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                }
            } header: { Text("Default mode") }
            Section {
                ForEach(0..<3) { slot in
                    Picker("⌘\(slot + 1)", selection: Binding(
                        get: { model.settings.mode(forSlot: slot) ?? .search },
                        set: { model.settings.assign($0, toSlot: slot) }
                    )) {
                        ForEach(LauncherMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                    }
                }
                Text("Changing a shortcut swaps its previous action. Number keys still type normally.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } header: { Text("Mode shortcuts") }
            Section {
                prefixEditor("Cursor default prompt", text: $model.settings.cursorPrefix)
                prefixEditor("Codex default prompt", text: $model.settings.codexPrefix)
                Text("Added before every new prompt. Leave blank to use only what you type. Changes save automatically.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } header: { Text("Default prompts") }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
    }

    private func prefixEditor(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium))
            TextEditor(text: text).font(.system(size: 12, design: .monospaced))
                .frame(height: 58).scrollContentBackground(.hidden)
                .padding(6).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel(title)
        }
    }
}
