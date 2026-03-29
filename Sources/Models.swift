import Foundation

// MARK: - Status

enum ClaudeStatus: Equatable {
    case idle
    case working(count: Int)
    case waiting(count: Int)
}

// MARK: - Token counts

struct TokenCount {
    var input: Int = 0
    var output: Int = 0
    var cacheCreation: Int = 0
    var cacheRead: Int = 0

    var total: Int { input + output + cacheCreation + cacheRead }

    mutating func add(input: Int = 0, output: Int = 0, cacheCreation: Int = 0, cacheRead: Int = 0) {
        self.input += input
        self.output += output
        self.cacheCreation += cacheCreation
        self.cacheRead += cacheRead
    }

    static func + (lhs: TokenCount, rhs: TokenCount) -> TokenCount {
        TokenCount(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheCreation: lhs.cacheCreation + rhs.cacheCreation,
            cacheRead: lhs.cacheRead + rhs.cacheRead
        )
    }

    static func += (lhs: inout TokenCount, rhs: TokenCount) {
        lhs = lhs + rhs
    }
}

// MARK: - Waiting state

enum WaitingState: Equatable {
    case none
    case waitingForResponse   // last entry = assistant (text)
    case waitingForApproval   // last entry = assistant (tool_use pending)

    var icon: String {
        switch self {
        case .none:                return "⏸"
        case .waitingForResponse:  return "💬"
        case .waitingForApproval:  return "🔐"
        }
    }
}

// MARK: - Session

struct SessionInfo {
    let sessionId: String
    let projectName: String
    var usage: TokenCount
    var agents: [String: TokenCount]   // agentId -> tokens
    var lastActivity: Date

    /// Set only by live FSEvents writes (never by initial file-load).
    /// Expires 30 seconds after the last real-time write.
    var liveActiveUntil: Date = .distantPast

    /// Timestamp of the last live FSEvents write (independent of liveActiveUntil).
    var lastFSEventWrite: Date = .distantPast

    /// Detected from the last JSONL entry — set when process is alive.
    var waitingState: WaitingState = .none

    /// True only when FSEvents detected a write within the last 30 seconds.
    var isRecentlyActive: Bool { Date() < liveActiveUntil }

    /// True when the session needs attention AND had a recent write (< 5 min).
    /// Guards against stale waiting state from finished sessions.
    var needsAttention: Bool {
        guard waitingState != .none else { return false }
        return Date().timeIntervalSince(lastFSEventWrite) < 300
    }

    var totalUsage: TokenCount {
        agents.values.reduce(usage) { $0 + $1 }
    }
}
