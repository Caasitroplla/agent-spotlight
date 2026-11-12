import AppKit
import SwiftUI
import Carbon
import AgentSpotlightCore

@main
struct AgentSpotlightApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class SearchModel: ObservableObject {
    @Published var query = "" { didSet { scheduleSearch() } }
    @Published var cursorDraft = ""
    @Published var codexDraft = ""
    @Published var mode: LauncherMode = .search
    @Published var settings = LauncherSettings.load(from: .standard) {
        didSet { settings.save(to: .standard) }
    }
    @Published var openingChat = false
    @Published var modelDefaults: [ChatSource: AppModelDefault] = [:]
    @Published var runLocations: [ChatSource: AppRunLocation] = [:]
    var showSettings: (() -> Void)?

    @Published var source: ChatSource? { didSet { scheduleSearch() } }
    @Published var includeArchived = true { didSet { scheduleSearch() } }
    @Published var results: [ChatRecord] = []
    @Published var selectedID: String?
    @Published var status = IndexStatus()
    @Published var error: String?
    @Published var focusToken = 0
    var dismiss: (() -> Void)?
    private let index: ChatIndex?
    private var searchTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var generation = 0
    private let modelDefaultsReader = ModelDefaultsReader()
    private var modelDefaultsTask: Task<Void, Never>?

    init() {
        do { index = try ChatIndex() }
        catch { index = nil; self.error = "The search index could not be opened. \(error)" }
    }
    var inputText: String {
        get {
            switch mode {
            case .search: return query
            case .cursor: return cursorDraft
            case .codex: return codexDraft
            }
        }
        set {
            switch mode {
            case .search: query = newValue
            case .cursor: cursorDraft = newValue
            case .codex: codexDraft = newValue
            }
        }
    }
    var promptPreview: String { settings.prompt(for: mode, draft: inputText) }
    var inputPlaceholder: String { mode == .search ? "Search your agent chats" : "Type a prompt for \(mode.source!.displayName)" }
    var inputLabel: String { mode == .search ? "Search agent chats" : "\(mode.source!.displayName) prompt" }

    func selectMode(_ selected: LauncherMode) {
        mode = selected
        focusToken += 1
        refreshModelDefaults()
        if selected == .search { scheduleSearch(immediate: true) }
        else { searchTask?.cancel() }
    }

    func modelDefault(for source: ChatSource) -> AppModelDefault {
        modelDefaults[source] ?? .unknown("Reading saved app defaults…")
    }

    func refreshModelDefaults() {
        guard modelDefaultsTask == nil else { return }
        modelDefaultsTask = Task {
            modelDefaults = await modelDefaultsReader.read()
            runLocations = await modelDefaultsReader.readRunLocations()
            modelDefaultsTask = nil
        }
    }

    func runLocation(for source: ChatSource) -> AppRunLocation {
        runLocations[source] ?? (source == .codex ? .codexLocal : .unavailable)
    }

    func openCursorEnvironmentSettings() {
        guard let url = URL(string: "cursor://anysphere.cursor-deeplink/settings/chat") else { return }
        if !NSWorkspace.shared.open(url) { error = "Could not open Cursor Settings. Open Settings → Agents in Cursor to change Default Environment." }
    }

    func submit() {
        guard !openingChat else { return }
        guard mode != .search else { openSelected(); return }
        do {
            let request = NewChatRequest(mode: mode, prompt: promptPreview)
            let url = try request.deepLink()
            let bundle = mode == .cursor ? "com.todesktop.230313mzl4w4u92" : "com.openai.codex"
            guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
                error = "\(mode.source!.displayName) is not installed. Install it, then try again. Your draft is still here."
                return
            }
            error = nil
            openingChat = true
            let destination = mode.source!.displayName
            NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, failure in
                Task { @MainActor in
                    guard let self else { return }
                    self.openingChat = false
                    if let failure { self.error = "Could not open \(destination). \(failure.localizedDescription)" }
                    else { self.dismiss?() }
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    var selected: ChatRecord? { results.first(where: { $0.id == selectedID }) ?? results.first }
    var sourceErrors: String? { status.providers.compactMap(\.error).first }
    var footerText: String {
        if status.refreshing { return "Indexing history · \(status.indexed.formatted()) / \(status.discovered.formatted())" }
        if status.unavailable > 0 { return "\(status.indexed.formatted()) chats · \(status.unavailable.formatted()) histories unavailable" }
        if status.discovered == 0 { return "Looking for local chats" }
        return "\(status.discovered.formatted()) chats · On this Mac"
    }
    func appear() {
        selectMode(settings.defaultMode)
        refresh()
    }
    func refresh() {
        guard let index, refreshTask == nil else { return }
        let running = NSWorkspace.shared.runningApplications
        let codexRunning = running.contains { $0.bundleIdentifier == "com.openai.codex" }
        let cursorRunning = running.contains { $0.bundleIdentifier == "com.todesktop.230313mzl4w4u92" }
        refreshTask = Task {
            pollTask = Task {
                while !Task.isCancelled {
                    status = await index.currentStatus()
                    scheduleSearch(immediate: true)
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            await index.refresh(providers: [CodexProvider(paths: SourcePaths(), appRunning: codexRunning), CursorProvider(paths: SourcePaths(), appRunning: cursorRunning)])
            pollTask?.cancel(); pollTask = nil
            status = await index.currentStatus()
            scheduleSearch(immediate: true)
            refreshTask = nil
        }
    }
    func scheduleSearch(immediate: Bool = false) {
        generation += 1
        let requestedGeneration = generation
        searchTask?.cancel()
        guard mode == .search, let index else { return }
        let search = SearchQuery(text: query, source: source, includeArchived: includeArchived)
        searchTask = Task {
            if !immediate { try? await Task.sleep(for: .milliseconds(65)) }
            guard !Task.isCancelled else { return }
            do {
                let matches = try await index.search(search)
                guard !Task.isCancelled, generation == requestedGeneration else { return }
                results = matches
                if !matches.contains(where: { $0.id == selectedID }) { selectedID = matches.first?.id }
            } catch {
                guard generation == requestedGeneration else { return }
                self.error = "Search could not finish. \(error)"
            }
        }
    }
    func move(_ offset: Int) {
        guard mode == .search, !results.isEmpty else { return }
        let current = results.firstIndex(where: { $0.id == selectedID }) ?? 0
        selectedID = results[min(max(current + offset, 0), results.count - 1)].id
    }
    func openSelected() {
        guard mode == .search, let chat = selected, let url = chat.deepLink else { return }
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, failure in
            Task { @MainActor in
                if let failure { self?.error = "Could not open \(chat.identity.source.displayName). \(failure.localizedDescription)" }
                else { self?.dismiss?() }
            }
        }
    }
    func copyLink() {
        guard mode == .search, let url = selected?.deepLink else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}

final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = SearchModel()
    private var panel: SearchPanel!
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem!
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var keyboardMonitor: Any?
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bundle = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundle).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("AgentSpotlight.show"), object: nil)
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        panel = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 548), styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Agent Spotlight"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: SearchView(model: model))
        panel.appearance = NSAppearance(named: .darkAqua)
        model.dismiss = { [weak self] in self?.hide() }
        model.showSettings = { [weak self] in self?.openSettings() }
        createMenu()
        createMainMenu()
        registerShortcut()
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow, event.window === self.panel else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if modifiers == .command {
                let slots: [UInt16: Int] = [18: 0, 19: 1, 20: 2]
                if let slot = slots[event.keyCode], let mode = self.model.settings.mode(forSlot: slot) {
                    self.model.selectMode(mode)
                    return nil
                }
            }
            switch event.keyCode {
            case 53: self.hide(); return nil
            case 125 where self.model.mode == .search: self.model.move(1); return nil
            case 126 where self.model.mode == .search: self.model.move(-1); return nil
            case 36, 76: self.model.submit(); return nil
            case 8 where event.modifierFlags.contains([.command, .shift]): self.model.copyLink(); return nil
            default: return event
            }
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(show), name: Notification.Name("AgentSpotlight.show"), object: nil)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.model.refresh() } }
        show()
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        refreshTimer?.invalidate()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return false }
    func applicationDidResignActive(_ notification: Notification) { hide() }
    func windowDidResignKey(_ notification: Notification) { hide() }
    @objc func show() {
        if !panel.isVisible {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
            let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            panel.setFrameOrigin(NSPoint(x: frame.midX - 380, y: frame.minY + frame.height * 0.62 - 274))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        model.appear()
    }
    @objc func toggle() { panel.isVisible ? hide() : show() }
    @objc func hide() { panel?.orderOut(nil) }
    @objc func refresh() { model.refresh() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func openSettings() {
        hide()
        model.refreshModelDefaults()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Agent Spotlight Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: LauncherSettingsView(model: model))
            window.appearance = NSAppearance(named: .darkAqua)
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    private func createMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: "Agent Spotlight")
        let menu = NSMenu()
        let search = NSMenuItem(title: "Search chats", action: #selector(show), keyEquivalent: "␣")
        search.keyEquivalentModifierMask = [.option, .command]
        search.target = self; menu.addItem(search)
        let refresh = NSMenuItem(title: "Refresh history", action: #selector(refresh), keyEquivalent: "r"); refresh.target = self; menu.addItem(refresh)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self; menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Agent Spotlight", action: #selector(quit), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        statusItem.menu = menu
    }
    private func createMainMenu() {
        let main = NSMenu()
        let application = NSMenuItem()
        let menu = NSMenu(title: "Agent Spotlight")
        let search = NSMenuItem(title: "Search chats", action: #selector(show), keyEquivalent: "␣")
        search.keyEquivalentModifierMask = [.option, .command]
        search.target = self; menu.addItem(search)
        let refresh = NSMenuItem(title: "Refresh history", action: #selector(refresh), keyEquivalent: "r"); refresh.target = self; menu.addItem(refresh)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self; menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Agent Spotlight", action: #selector(quit), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        application.submenu = menu
        main.addItem(application)
        let edit = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (title, selector, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key))
        }
        edit.submenu = editMenu
        main.addItem(edit)
        NSApp.mainMenu = main
    }
    private func registerShortcut() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
            guard let data else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<AppDelegate>.fromOpaque(data).takeUnretainedValue()
            Task { @MainActor in owner.toggle() }
            return noErr
        }, 1, &type, opaque, &eventHandler)
        let result = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey | cmdKey), EventHotKeyID(signature: 0x41535054, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { model.error = "⌥⌘Space is already in use. Open search from the menu bar." }
    }
}

struct SearchView: View {
    @ObservedObject var model: SearchModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 15) {
                Image(systemName: model.mode == .search ? "magnifyingglass" : "square.and.pencil").font(.system(size: 25, weight: .light)).foregroundStyle(.white.opacity(0.55))
                SearchField(text: Binding(get: { model.inputText }, set: { model.inputText = $0 }), focusToken: model.focusToken, placeholder: model.inputPlaceholder, label: model.inputLabel)
                    .frame(height: 34)
                if !model.inputText.isEmpty {
                    Button { model.inputText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.35)) }.buttonStyle(.plain).accessibilityLabel("Clear input")
                }
                Text("esc").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.4)).padding(.horizontal, 6).padding(.vertical, 3).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
            }.padding(.horizontal, 25).frame(height: 82)
            Divider().overlay(.white.opacity(0.04))
            HStack(spacing: 7) {
                ForEach(LauncherMode.allCases, id: \.self) { mode in
                    Button { model.selectMode(mode) } label: {
                        HStack(spacing: 6) {
                            Text(mode.title)
                            Text(model.settings.shortcut(for: mode)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        .font(.system(size: 11, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 7)
                        .foregroundStyle(model.mode == mode ? .white : .white.opacity(0.5))
                        .background(model.mode == mode ? .white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                }
                Spacer()
                Button { model.showSettings?() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Settings · ⌘,").accessibilityLabel("Settings")
            }.padding(.horizontal, 20).frame(height: 43)
            if model.mode == .search {
                HStack(spacing: 6) {
                    filter("All chats", source: nil)
                    filter("Codex", source: .codex)
                    filter("Cursor", source: .cursor)
                    Spacer()
                    Toggle(isOn: $model.includeArchived) { Image(systemName: "archivebox").font(.system(size: 13)) }
                        .toggleStyle(.button).buttonStyle(.plain).foregroundStyle(model.includeArchived ? .white.opacity(0.65) : .white.opacity(0.25))
                        .help("Include archived chats").accessibilityLabel("Include archived chats")
                    Text(model.query.isEmpty ? "RECENT" : "\(model.results.count) RESULTS")
                        .font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.white.opacity(0.3)).padding(.leading, 8)
                }.padding(.horizontal, 20).frame(height: 38)
            }
            if let error = model.error ?? (model.mode == .search ? model.sourceErrors : nil) {
                HStack { Image(systemName: "exclamationmark.triangle"); Text(error).lineLimit(2); Spacer() }
                    .font(.system(size: 11)).foregroundStyle(.orange.opacity(0.9)).padding(.horizontal, 24).padding(.vertical, 8)
            }
            if model.mode == .search {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            if model.results.isEmpty {
                                VStack(spacing: 12) {
                                    Image(systemName: model.status.refreshing ? "clock.arrow.circlepath" : "text.magnifyingglass").font(.system(size: 32, weight: .ultraLight))
                                    Text(model.status.refreshing ? "Finding your conversations" : "No chats found").font(.system(size: 16, weight: .medium))
                                    Text(model.query.isEmpty ? "Codex and Cursor history appears here." : "Try a title, project, or a phrase from a message.").font(.system(size: 12)).foregroundStyle(.secondary)
                                }.foregroundStyle(.white.opacity(0.6)).frame(maxWidth: .infinity).frame(height: 290)
                            } else {
                                ForEach(model.results) { chat in
                                    ResultRow(chat: chat, selected: model.selectedID == chat.id)
                                        .contentShape(Rectangle())
                                        .onTapGesture { model.selectedID = chat.id; model.openSelected() }
                                        .id(chat.id)
                                        .accessibilityElement(children: .combine)
                                        .accessibilityAddTraits(.isButton)
                                        .accessibilityAction { model.selectedID = chat.id; model.openSelected() }
                                }
                            }
                        }.padding(.horizontal, 12).padding(.bottom, 10)
                    }.onChange(of: model.selectedID) { _, id in if let id { withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(id, anchor: .center) } } }
                }
            } else {
                composePane
            }
            Divider().overlay(.white.opacity(0.04))
            HStack(spacing: 7) {
                if model.status.refreshing && model.mode == .search { ProgressView().controlSize(.mini).scaleEffect(0.7) }
                else { Image(systemName: "lock.fill").font(.system(size: 9)) }
                Text(model.mode == .search ? model.footerText : "Opens a draft for you to review in \(model.mode.source!.displayName)").lineLimit(1)
                Spacer()
                if model.mode == .search { shortcut("↑↓", "navigate") }
                shortcut("↵", model.mode == .search ? "open chat" : "open draft")
            }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.36)).padding(.horizontal, 22).frame(height: 38)
        }
        .frame(width: 760, height: 548)
        .background(VisualEffect().overlay(Color.black.opacity(0.32)))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .preferredColorScheme(.dark)
    }
    private var composePane: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 10) {
                if let source = model.mode.source { Image(nsImage: AppIcons.icon(source)).resizable().frame(width: 29, height: 29) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.mode.title).font(.system(size: 17, weight: .medium))
                    Text("Type above. Your default prompt is added below.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if let source = model.mode.source {
                let saved = model.modelDefault(for: source)
                let location = model.runLocation(for: source)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        if model.settings.showModelDefaults {
                            Text("Saved app default").foregroundStyle(.secondary)
                            Text(saved.title).fontWeight(.medium).textSelection(.enabled)
                        } else {
                            Text("Launch details").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { model.refreshModelDefaults() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.plain).accessibilityLabel("Refresh app defaults")
                    }.font(.system(size: 12))
                    if model.settings.showModelDefaults {
                        Text(saved.note).font(.system(size: 10)).foregroundStyle(.secondary)
                        Divider().padding(.vertical, 3)
                    }
                    HStack(spacing: 8) {
                        Text("Run location").foregroundStyle(.secondary)
                        Text(location.title).fontWeight(.medium).textSelection(.enabled)
                    }.font(.system(size: 12))
                    Text(location.note).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityElement(children: .contain)
            }
            HStack {
                Text("PROMPT PREVIEW").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                Spacer()
                if !model.settings.prefix(for: model.mode).isEmpty { Text("Includes default prompt").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            ScrollView {
                Text(model.promptPreview.isEmpty ? "Your prompt will appear here." : model.promptPreview)
                    .font(.system(size: 13)).textSelection(.enabled)
                    .foregroundStyle(model.promptPreview.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(14)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityLabel("Complete prompt preview")
            HStack {
                Text("You send it from the destination app.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(model.openingChat ? "Opening…" : "Open \(model.mode.title.lowercased())") { model.submit() }
                    .buttonStyle(.borderedProminent).disabled(model.openingChat)
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func filter(_ title: String, source: ChatSource?) -> some View {
        Button { model.source = source } label: {
            HStack(spacing: 5) { if let source { Image(nsImage: AppIcons.icon(source)).resizable().frame(width: 13, height: 13) }; Text(title) }
                .font(.system(size: 11, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 6)
                .foregroundStyle(model.source == source ? .white.opacity(0.9) : .white.opacity(0.42))
                .background(model.source == source ? .white.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
    }
    private func shortcut(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) { Text(key).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.6)); Text(label) }.padding(.leading, 9)
    }
}

struct ResultRow: View {
    let chat: ChatRecord
    let selected: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(nsImage: AppIcons.icon(chat.identity.source)).resizable().frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 7)).padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(chat.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.94)).lineLimit(1)
                    if chat.archived { Image(systemName: "archivebox").font(.system(size: 9)).foregroundStyle(.white.opacity(0.3)) }
                    Spacer(minLength: 5)
                    if chat.activity == .detected {
                        HStack(spacing: 4) { Circle().fill(.green).frame(width: 5, height: 5); Text("Recently active") }.font(.system(size: 9)).foregroundStyle(.green.opacity(0.8))
                            .help("Recent activity in saved chat state. This may lag the app's live status.")
                    } else { Text(chat.updatedAt, style: .relative).font(.system(size: 10)).foregroundStyle(.white.opacity(0.32)).lineLimit(1) }
                }
                HStack(spacing: 5) {
                    Text(chat.identity.source.displayName)
                    if !chat.projectPath.isEmpty { Text("·"); Image(systemName: "folder").font(.system(size: 9)); Text(projectName).lineLimit(1).truncationMode(.middle) }
                }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.42))
                Text(chat.preview.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.36)).lineLimit(1)
            }
            if selected { Image(systemName: "return").font(.system(size: 12)).foregroundStyle(.white.opacity(0.35)).padding(.top, 17).frame(width: 14) }
            else { Color.clear.frame(width: 14) }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(height: 81)
        .background(selected ? Color.white.opacity(0.085) : .clear, in: RoundedRectangle(cornerRadius: 9))
    }
    private var projectName: String { URL(fileURLWithPath: chat.projectPath).lastPathComponent }
}

enum AppIcons {
    static let codex = load("com.openai.codex")
    static let cursor = load("com.todesktop.230313mzl4w4u92")
    static func icon(_ source: ChatSource) -> NSImage { source == .codex ? codex : cursor }
    private static func load(_ bundle: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSImage(systemSymbolName: "bubble.left.and.bubble.right.fill", accessibilityDescription: nil)!
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(); view.material = .hudWindow; view.blendingMode = .behindWindow; view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let focusToken: Int
    let placeholder: String
    let label: String
    private static let inputFont = NSFont.systemFont(ofSize: 24, weight: .regular)
    private var attributedPlaceholder: NSAttributedString {
        NSAttributedString(string: placeholder, attributes: [
            .font: Self.inputFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.35)
        ])
    }
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Self.inputFont
        field.textColor = .white
        field.placeholderAttributedString = attributedPlaceholder
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.setAccessibilityLabel(label)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        field.placeholderAttributedString = attributedPlaceholder
        field.setAccessibilityLabel(label)
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window, window.isVisible else { return }
                window.makeFirstResponder(field)
                if let editor = field.currentEditor() { editor.selectedRange = NSRange(location: field.stringValue.utf16.count, length: 0) }
            }
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var focusToken = -1
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { text.wrappedValue = field.stringValue }
        }
    }
}
