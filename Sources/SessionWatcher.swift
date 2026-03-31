import Foundation
import CoreServices

/// Watches ~/.claude/projects/ with FSEvents and incrementally parses JSONL files
/// to maintain an up-to-date map of active Claude sessions and their token usage.
final class SessionWatcher {

    var onUpdate: (([SessionInfo]) -> Void)?

    private var sessions: [String: SessionInfo] = [:]   // sessionId -> SessionInfo
    private let parser = TokenParser()
    private var eventStream: FSEventStreamRef?
    private let projectsDir: URL

    init() {
        projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    // MARK: - Lifecycle

    func start() {
        loadExistingSessions()
        startFSEvents()
    }

    func stop() {
        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
    }

    func currentSessions() -> [SessionInfo] {
        pruneStale()
        return Array(sessions.values)
    }

    // MARK: - Initial load

    private func loadExistingSessions() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-86_400)   // last 24 h

        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        for projectDir in projectDirs {
            guard (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }

            let projectName = Self.projectName(from: projectDir.lastPathComponent)

            guard let files = try? fm.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
            ) else { continue }

            for file in files {
                let isDir = (try? file.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let modDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast

                if !isDir, file.pathExtension == "jsonl", modDate > cutoff {
                    // Main session file
                    let sessionId = file.deletingPathExtension().lastPathComponent
                    let tokens = parser.parseFull(fileURL: file)
                    upsertSession(sessionId: sessionId, projectName: projectName,
                                  addTokens: tokens, agentId: nil, date: modDate)
                    if let entry = TokenParser.readLastEntry(fileURL: file) {
                        sessions[sessionId]?.waitingState = Self.waitingState(from: entry)
                    }

                } else if isDir {
                    // Subagent files under {sessionId}/subagents/agent-{id}/agent-{id}.jsonl
                    let parentSessionId = file.lastPathComponent
                    let subagentsDir = file.appendingPathComponent("subagents")

                    guard let agentDirs = try? fm.contentsOfDirectory(
                        at: subagentsDir,
                        includingPropertiesForKeys: [.contentModificationDateKey]
                    ) else { continue }

                    for agentDir in agentDirs {
                        let agentDirName = agentDir.lastPathComponent            // "agent-{id}"
                        let agentId = String(agentDirName.dropFirst("agent-".count))
                        let agentFile = agentDir.appendingPathComponent("\(agentDirName).jsonl")

                        let aModDate = (try? agentFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                        guard aModDate > cutoff else { continue }

                        let tokens = parser.parseFull(fileURL: agentFile)
                        upsertSession(sessionId: parentSessionId, projectName: projectName,
                                      addTokens: tokens, agentId: agentId, date: aModDate)
                    }
                }
            }
        }

        onUpdate?(Array(sessions.values))
    }

    // MARK: - FSEvents

    private func startFSEvents() {
        let pathsToWatch = [projectsDir.path] as CFArray

        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let callback: FSEventStreamCallback = { (_, clientInfo, numEvents, eventPaths, _, _) in
            guard let clientInfo else { return }
            let watcher = Unmanaged<SessionWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
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
            0.5,    // 500 ms coalescing latency
            flags
        )

        if let stream = eventStream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
        }
    }

    // MARK: - Event handling

    private func handleFileEvent(path: String) {
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension == "jsonl" else { return }

        // Decompose path relative to projectsDir
        // Patterns:
        //   .../projects/{projectDir}/{sessionId}.jsonl
        //   .../projects/{projectDir}/{sessionId}/subagents/agent-{id}/agent-{id}.jsonl
        let base = projectsDir.path
        guard path.hasPrefix(base) else { return }

        let relative = String(path.dropFirst(base.count + 1))   // strip leading /
        let parts = relative.components(separatedBy: "/")        // [projectDir, ...]

        guard parts.count >= 2 else { return }

        let projectName = Self.projectName(from: parts[0])
        let now = Date()

        if parts.count == 2 {
            // Main session file
            let sessionId = url.deletingPathExtension().lastPathComponent
            if let delta = parser.parseIncremental(fileURL: url) {
                upsertSession(sessionId: sessionId, projectName: projectName,
                              addTokens: delta, agentId: nil, date: now, markLive: true)
            } else if sessions[sessionId] != nil {
                sessions[sessionId]?.lastActivity    = now
                sessions[sessionId]?.liveActiveUntil = Date().addingTimeInterval(30)
            }
            // Only the session's own file determines waiting state
            updateWaitingState(sessionId: sessionId, fileURL: url)
            onUpdate?(Array(sessions.values))

        } else if parts.count >= 5, parts[2] == "subagents" {
            let parentSessionId = parts[1]
            let agentDirName = parts[3]
            let agentId = String(agentDirName.dropFirst("agent-".count))

            if let delta = parser.parseIncremental(fileURL: url) {
                upsertSession(sessionId: parentSessionId, projectName: projectName,
                              addTokens: delta, agentId: agentId, date: now, markLive: true)
            } else if sessions[parentSessionId] != nil {
                sessions[parentSessionId]?.lastActivity    = now
                sessions[parentSessionId]?.liveActiveUntil = Date().addingTimeInterval(30)
            }
            // Don't update waitingState from subagent files — only the parent session file
            // determines whether the user is actually needed.
            onUpdate?(Array(sessions.values))
        }
    }

    // MARK: - Helpers

    private func upsertSession(sessionId: String, projectName: String,
                                addTokens: TokenCount, agentId: String?, date: Date,
                                markLive: Bool = false) {
        if sessions[sessionId] == nil {
            sessions[sessionId] = SessionInfo(
                sessionId: sessionId, projectName: projectName,
                usage: TokenCount(), agents: [:], lastActivity: date
            )
        }

        if let aid = agentId {
            sessions[sessionId]?.agents[aid, default: TokenCount()] += addTokens
        } else {
            sessions[sessionId]?.usage += addTokens
        }

        if date > (sessions[sessionId]?.lastActivity ?? .distantPast) {
            sessions[sessionId]?.lastActivity = date
        }

        if markLive {
            sessions[sessionId]?.liveActiveUntil = Date().addingTimeInterval(30)
        }
    }

    // MARK: - Waiting state detection

    private func updateWaitingState(sessionId: String, fileURL: URL) {
        guard let entry = TokenParser.readLastEntry(fileURL: fileURL) else { return }
        let state = Self.waitingState(from: entry)

        sessions[sessionId]?.waitingState = state

        // Only extend liveActiveUntil on user messages (Claude is actively processing).
        // On assistant messages, let liveActiveUntil expire naturally (30 s) to avoid
        // the ⚡ flickering on rapid tool-call cycles where auto-approved tool results
        // arrive just after the assistant entry. The badge priority logic (waiting > working)
        // ensures orange is shown even while liveActiveUntil hasn't expired yet.
        if state == .none {
            sessions[sessionId]?.liveActiveUntil = Date().addingTimeInterval(30)
        }
    }

    private static func waitingState(from entry: [String: Any]) -> WaitingState {
        guard entry["type"] as? String == "assistant" else { return .none }

        if let message = entry["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]],
           content.contains(where: { $0["type"] as? String == "tool_use" }) {
            return .waitingForApproval
        }
        return .waitingForResponse
    }

    private func pruneStale() {
        let cutoff = Date().addingTimeInterval(-86_400)
        sessions = sessions.filter { $0.value.lastActivity > cutoff }
    }

    private static func projectName(from dirName: String) -> String {
        // Dir names look like "-Users-lvi-Devs-Apps-MyProject"
        // Return the last meaningful path component.
        let parts = dirName.split(separator: "-").filter { !$0.isEmpty }
        return parts.last.map(String.init) ?? dirName
    }
}
