import Foundation
import CoreServices
import SQLite3

/// Watches Codex CLI sessions by querying ~/.codex/state_5.sqlite and
/// monitoring ~/.codex/sessions/ with FSEvents for live updates.
final class CodexSessionWatcher {

    var onUpdate: (([SessionInfo]) -> Void)?

    private var sessions: [String: SessionInfo] = [:]          // threadId -> SessionInfo
    private var rolloutToThread: [String: String] = [:]        // rollout path -> threadId
    private var lastTokensUsed: [String: Int] = [:]            // threadId -> tokens_used

    private var eventStream: FSEventStreamRef?
    private let sessionsDir: URL
    private let dbDir: String
    private let dbPath: String

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        sessionsDir = home.appendingPathComponent(".codex/sessions")
        dbPath = home.appendingPathComponent(".codex/state_5.sqlite").path
        dbDir  = (dbPath as NSString).deletingLastPathComponent
    }

    // MARK: - Lifecycle

    func start() {
        loadFromDatabase()
        startFSEvents()
    }

    func stop() {
        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
    }

    // MARK: - Initial load

    private func loadFromDatabase() {
        let cutoff = Int64(Date().addingTimeInterval(-86_400).timeIntervalSince1970)

        withDatabase { db in
            let sql = """
                SELECT id, rollout_path, cwd, tokens_used, updated_at
                FROM threads
                WHERE archived = 0 AND updated_at > ?
                ORDER BY updated_at DESC
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, cutoff)

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idCStr   = sqlite3_column_text(stmt, 0),
                      let pathCStr = sqlite3_column_text(stmt, 1),
                      let cwdCStr  = sqlite3_column_text(stmt, 2)
                else { continue }

                let threadId    = String(cString: idCStr)
                let rolloutPath = String(cString: pathCStr)
                let cwd         = String(cString: cwdCStr)
                let tokensUsed  = Int(sqlite3_column_int64(stmt, 3))
                let updatedAt   = TimeInterval(sqlite3_column_int64(stmt, 4))
                let date        = Date(timeIntervalSince1970: updatedAt)
                let fileURL     = URL(fileURLWithPath: rolloutPath)
                let projectName = Self.projectName(from: cwd)

                // Token breakdown from JSONL (last token_count event), or fall back to DB total
                let tokens = Self.readLastTokenCount(fileURL: fileURL)
                          ?? TokenCount(input: tokensUsed, output: 0, cacheCreation: 0, cacheRead: 0)

                sessions[threadId] = SessionInfo(
                    sessionId: threadId, projectName: projectName,
                    provider: .codex,
                    usage: tokens, agents: [:], lastActivity: date
                )

                if let entry = TokenParser.readLastEntry(fileURL: fileURL) {
                    sessions[threadId]?.waitingState = Self.waitingState(from: entry)
                }

                rolloutToThread[rolloutPath] = threadId
                lastTokensUsed[threadId] = tokensUsed
            }
        }

        onUpdate?(Array(sessions.values))
    }

    // MARK: - FSEvents

    private func startFSEvents() {
        // Watch both the sessions JSONL directory and the DB directory
        let pathsToWatch = [sessionsDir.path, dbDir] as CFArray

        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let callback: FSEventStreamCallback = { (_, clientInfo, numEvents, eventPaths, _, _) in
            guard let clientInfo else { return }
            let watcher = Unmanaged<CodexSessionWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self)
            for i in 0..<numEvents {
                guard let path = paths[i] as? String else { continue }
                DispatchQueue.main.async { watcher.handleFileEvent(path: path) }
            }
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
        )

        eventStream = FSEventStreamCreate(
            nil, callback, &ctx,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        )

        if let stream = eventStream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
        }
    }

    // MARK: - Event handling

    private func handleFileEvent(path: String) {
        if path.hasSuffix(".jsonl") {
            handleJSONLEvent(path: path)
        } else if path.hasSuffix("state_5.sqlite") {
            refreshTokensFromDatabase()
        }
    }

    private func handleJSONLEvent(path: String) {
        let now = Date()

        if let threadId = rolloutToThread[path] {
            // Known session — mark live, refresh waiting state
            sessions[threadId]?.lastActivity    = now
            sessions[threadId]?.liveActiveUntil = now.addingTimeInterval(30)

            let url = URL(fileURLWithPath: path)
            if let entry = TokenParser.readLastEntry(fileURL: url) {
                let state = Self.waitingState(from: entry)
                sessions[threadId]?.waitingState = state
                if state == .none {
                    sessions[threadId]?.liveActiveUntil = now.addingTimeInterval(30)
                }
            }
            onUpdate?(Array(sessions.values))
        } else {
            // Unknown JSONL — might be a brand-new session; reload from DB
            refreshTokensFromDatabase()
        }
    }

    private func refreshTokensFromDatabase() {
        let cutoff = Int64(Date().addingTimeInterval(-86_400).timeIntervalSince1970)
        var updated = false

        withDatabase { db in
            let sql = """
                SELECT id, rollout_path, cwd, tokens_used, updated_at
                FROM threads
                WHERE archived = 0 AND updated_at > ?
                ORDER BY updated_at DESC
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, cutoff)

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idCStr   = sqlite3_column_text(stmt, 0),
                      let pathCStr = sqlite3_column_text(stmt, 1),
                      let cwdCStr  = sqlite3_column_text(stmt, 2)
                else { continue }

                let threadId    = String(cString: idCStr)
                let rolloutPath = String(cString: pathCStr)
                let cwd         = String(cString: cwdCStr)
                let tokensUsed  = Int(sqlite3_column_int64(stmt, 3))
                let updatedAt   = TimeInterval(sqlite3_column_int64(stmt, 4))
                let date        = Date(timeIntervalSince1970: updatedAt)
                let fileURL     = URL(fileURLWithPath: rolloutPath)

                if sessions[threadId] == nil {
                    // New thread
                    let tokens = Self.readLastTokenCount(fileURL: fileURL)
                              ?? TokenCount(input: tokensUsed, output: 0, cacheCreation: 0, cacheRead: 0)
                    sessions[threadId] = SessionInfo(
                        sessionId: threadId, projectName: Self.projectName(from: cwd),
                        provider: .codex,
                        usage: tokens, agents: [:], lastActivity: date
                    )
                    if let entry = TokenParser.readLastEntry(fileURL: fileURL) {
                        sessions[threadId]?.waitingState = Self.waitingState(from: entry)
                    }
                    rolloutToThread[rolloutPath] = threadId
                    lastTokensUsed[threadId] = tokensUsed
                    updated = true
                } else if lastTokensUsed[threadId] != tokensUsed {
                    // Tokens updated — refresh usage
                    if let tokens = Self.readLastTokenCount(fileURL: fileURL) {
                        sessions[threadId]?.usage = tokens
                    } else {
                        sessions[threadId]?.usage = TokenCount(input: tokensUsed, output: 0, cacheCreation: 0, cacheRead: 0)
                    }
                    if date > (sessions[threadId]?.lastActivity ?? .distantPast) {
                        sessions[threadId]?.lastActivity = date
                    }
                    lastTokensUsed[threadId] = tokensUsed
                    updated = true
                }
            }
        }

        if updated { onUpdate?(Array(sessions.values)) }
    }

    // MARK: - JSONL helpers

    /// Reads the last `token_count` event from the tail of a Codex JSONL file (≤8 KB scan).
    private static func readLastTokenCount(fileURL: URL) -> TokenCount? {
        guard let fh = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? fh.close() }

        let size = (try? fh.seekToEnd()) ?? 0
        guard size > 0 else { return nil }

        let chunk = min(size, 8192)
        try? fh.seek(toOffset: size - chunk)
        guard let text = String(data: fh.readDataToEndOfFile(), encoding: .utf8) else { return nil }

        for line in text.components(separatedBy: "\n").reversed() {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "event_msg",
                  let payload = json["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any]
            else { continue }

            return TokenCount(
                input:         total["input_tokens"]        as? Int ?? 0,
                output:        total["output_tokens"]       as? Int ?? 0,
                cacheCreation: 0,
                cacheRead:     total["cached_input_tokens"] as? Int ?? 0
            )
        }
        return nil
    }

    // MARK: - State detection

    private static func waitingState(from entry: [String: Any]) -> WaitingState {
        guard entry["type"] as? String == "event_msg",
              let payload = entry["payload"] as? [String: Any]
        else { return .none }

        switch payload["type"] as? String ?? "" {
        case "task_complete", "token_count":
            // Session ended — waiting for next user message
            return .waitingForResponse
        case "agent_message":
            return payload["phase"] as? String == "final_answer" ? .waitingForResponse : .none
        default:
            return .none
        }
    }

    // MARK: - SQLite helper

    /// Opens the database read-only, runs `body`, then closes it.
    private func withDatabase(body: (OpaquePointer) -> Void) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db
        else { return }
        defer { sqlite3_close(db) }
        body(db)
    }

    // MARK: - Misc helpers

    private static func projectName(from cwd: String) -> String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }
}
