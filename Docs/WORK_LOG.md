# Agent Spotlight build

## Task list

- [x] Read the Principles section in full.
- [x] `how` over the affected subsystem.
- [x] `architect` for parallel design exploration.
- [x] Write the throughput checkpoint as four todo items.
- [x] Delegate code-writing to a subagent.
- [x] Verify on the matching surface. Native search and Cursor opening passed. Codex destination inspection is blocked by native control policy.
- [x] Rebase into small, ordered commits; stack follow-ups. One coherent initial feature commit, with no existing history to rebase.
- [x] If the design is contested, `interrogate` before shipping. skip: The design candidates and independent judge agreed.
- [x] Run **Opening a PR**. skip: The new local repository has no remote destination.

## Throughput checkpoint

- Blocking first steps. Inspect the installed source schemas, chat links, and active state before implementation.
- Independent workstreams. Two read-only design candidates inspect Codex and Cursor. One implementation owner writes the app after design selection.
- Shared mutable state. Source databases open read-only. An index actor owns the app's separate SQLite cache. UI state stays on the main actor.
- Smallest safe decomposition. One implementation owner keeps the core model and app contract consistent. The parent independently reviews and runs the result.

## Architecture comparison

The design candidates compare a persistent SQLite FTS5 index with direct federated queries. The criteria are full-history coverage, bounded foreground work, running and recency ordering, read-only integration, maintainable adapters, and keyboard operation.

## Source evidence

- Codex metadata lives in `.codex/state_5.sqlite`. The installed schema includes `thread_source`, `history_mode`, `preview`, and millisecond timestamps.
- Codex messages and turns live in `.codex/thread_history_1.sqlite`. User and assistant items have separate item kinds. Turn rows hold saved execution status.
- Codex's installed `early-bootstrap.js` constructs `codex://threads/<id>`. The main ChatGPT app registers the scheme.
- Cursor's `conversation-search.db` contains `conversations` and the FTS5 `conversation_fts` table.
- Cursor's `state.vscdb` contains compact `composerHeaders` metadata. This avoids scanning its large message values.
- Cursor's installed `main.js` constructs `cursor://anysphere.cursor-deeplink/agent?id=<id>`.

## Verification contract

Test body matches, running and recency ordering, app and archived filters, punctuation and empty queries, persistence, source failures, source database immutability, and schema fallback. Build a launchable app bundle. Exercise the global shortcut, typing, arrows, escape, and real chat opening through native app control. Do not claim exact live execution status where the source only persists a last-known state.

## Runtime choices

Generic agents inherit the parent model and effort. Custom profiles are unavailable. Designs share read-only access. Only the implementation owner writes application code. No goals, automations, or user-owned chats are created. No PR can be published until a remote destination exists.

## Design decision

Choose the persistent FTS5 candidate. The independent judge agreed. The direct-query candidate contributes Cursor header metadata, existing body extraction, chat links, and coverage accounting. Direct federation would still require a separate Codex text index and would repeat its initial work after restart.

The main risks are partial Cursor coverage, stale saved activity, search starvation during import, and schema drift. The implementation must backfill uncovered composers, label saved activity as recent activity, suspend between import batches, retain prior bodies on read failures, and adapt optional columns at each source boundary. Pruning requires successful source enumeration. Distinct source IDs prevent accidental cross-app merging.

The native control tool refused access to `com.openai.codex` for safety. Codex's URL route has installed-source proof. Its on-screen destination remains a verification gap unless a supported control path can show it. This does not block verifying the search app itself.

## Principle decisions

- Model the Domain. Use typed chat identity, activity, filters, and coverage instead of unrelated flags.
- Foundational Thinking. Seed metadata before body imports so search starts before full history import ends.
- Experience First. Prioritize keyboard interaction, title availability, native panel behavior, and visible progress.
- Exhaust the Design Space. Compare persistent indexing with federated search before choosing the implementation.
- Build the Lever. Keep a rerunnable app packaging script and fixture tests as deliverables.
- Prove It Works. Build, exercise actual searches, and inspect native UI rather than treating compilation as completion.
- Test Behavior, Not Implementation. Assert result identities, order, matched message snippets, and refreshed content using source fixtures.
- Sequence Work into Verifiable Units. Verify the core import and search before packaging and native interaction checks.

## Final verification

The parent ran all 22 XCTest cases with zero failures. The release app passed strict signature verification after installation at `~/Applications/Agent Spotlight.app`.

Native control verified initial search-field focus, typed message searches, Codex and Cursor filters, clear search, visible arrow-key selection, GUI chat names, and the registered shortcut from Finder and Cursor. Return opened Cursor's exact selected conversation, confirmed by its selected chat tab and transcript. The panel was left on All chats with an empty search.

The inspection API reactivates the app when reading its window. That prevents a clean observation of its hidden state after Escape. The key handler and dismissal path were inspected. Codex's destination cannot be inspected because the native control tool blocks that app. Its route is verified from the installed handler and covered by URL tests. These are verification limits, not claims of live proof.

Independent source review found a partial Cursor discovery path that could prune cached chats. The fix records incomplete discovery, retains those records, and reports the source warning. Regression tests cover recovery and later successful pruning. Parent UI testing found a Settings-only launch path that stole focus. The app now uses an AppKit lifecycle with SwiftUI content and a native search field.

The no-comments audit found no removable comments or correctness suppressions. The required SwiftPM version directive remains. Deslop is not installed. Direct cleanup checks covered dead code, extra abstractions, comments, and consistency.

Exact running status remains unavailable from these saved stores. Recently active is an explicit heuristic. Uncached remote content remains unavailable. The app reports five missing Cursor histories in the live source snapshot.
