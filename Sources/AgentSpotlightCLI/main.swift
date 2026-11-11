import Foundation
import AgentSpotlightCore

@main
struct IndexCommand {
    static func main() async {
        do {
            let arguments = CommandLine.arguments
            let cache: URL
            if let offset = arguments.firstIndex(of: "--cache"), arguments.indices.contains(offset + 1) { cache = URL(fileURLWithPath: arguments[offset + 1]) }
            else { cache = ChatIndex.defaultURL }
            let index = try ChatIndex(url: cache)
            await index.refresh(providers: [CodexProvider(paths: SourcePaths()), CursorProvider(paths: SourcePaths())])
            let status = await index.currentStatus()
            for provider in status.providers {
                print("\(provider.source.displayName): \(provider.indexed)/\(provider.discovered) chats indexed, \(provider.unavailable) message histories unavailable")
                if let error = provider.error { print(error) }
            }
            let query = arguments.firstIndex(of: "--query").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? ""
            let rows = try await index.search(SearchQuery(text: query))
            print("Matching chats: \(rows.count)")
            if arguments.contains("--titles") {
                for row in rows { print("\(row.identity.source.displayName) | \(row.title) | \(row.id)") }
            }
        } catch { fputs("Index failed: \(error)\n", stderr); exit(1) }
    }
}
