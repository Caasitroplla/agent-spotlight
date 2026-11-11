# Agent Spotlight

Search Codex and Cursor chats from a native SwiftUI panel. Press **⌥⌘Space** from any app. Type words from a title, project, or message. Recent activity comes first, followed by the newest chats.

## Download v1.0

Download the macOS app ZIP from [Releases](https://github.com/Caasitroplla/agent-spotlight/releases). Extract it, move **Agent Spotlight.app** to Applications, and open it. The app stays in the menu bar.

The v1.0 download requires an Apple Silicon Mac running macOS 14 or later. Intel users can build from source on their Mac. The downloadable app is ad-hoc signed and is not notarized with Apple. macOS may block the download. Building from source is an alternative.

## Build and launch

Requires macOS 14 or later and the Swift command-line tools.

```sh
./Scripts/build-app.sh
open 'dist/Agent Spotlight.app'
```

The app lives in the menu bar. You can move the built app to your Applications folder. The shortcut does not require Accessibility permission. If another app owns the shortcut, the panel shows an error and the menu bar still opens search.

Use the arrow keys to select a result and Return to open its chat. Escape closes the panel. **⌘⇧C** copies the selected chat's link. The app filters select All chats, Codex, or Cursor. The archive button includes or excludes archived chats. Subagent chats and untitled Codex or Cursor chats stay hidden from the panel.

The app refreshes when you open the panel and every 30 seconds while it runs. Initial indexing starts with titles, then reads message histories from newest to oldest. The footer shows progress and unavailable message histories.

## Local history and activity

The app opens these source stores read-only.

- Codex metadata and history under `~/.codex`.
- Cursor metadata and cached conversation text under `~/Library/Application Support/Cursor/User/globalStorage`.

The app owns a separate full-text index at `~/Library/Application Support/Agent Spotlight/search.sqlite`. It does not send history to a server. The index contains copies of searchable chat messages. Quit the app and remove this directory to clear the cache. Opening the app builds it again.

Search includes available user and assistant text. Codex reasoning, system messages, and tool output are excluded. Cursor uses its existing search text and reads message records for chats missing from that cache. Cloud chats are available only when Cursor has cached their text locally. Deleted or unavailable remote messages cannot be recovered by this app.

**Recently active** means that the app is running and saved chat state records an unfinished recent turn. Saved state can lag or survive a crash. This label does not guarantee that a model is currently generating.

Chat-opening links use each installed app's route. Codex opens through `codex://threads/<id>`. Cursor opens through its agent deep link. Source formats are private implementation details and may change in later app versions. Read errors appear in the panel instead of hiding the other app's results.

## Verify the build

```sh
swift test
swift run spotlight-index
swift run spotlight-index --query 'migration'
```

The diagnostic tool refreshes the same local index and prints counts. It prints chat titles only with `--titles`. Use `--cache /path/to/test.sqlite` to choose a separate index.
