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

    /// Expires 30 seconds after the last real-time FSEvents write.
    var liveActiveUntil: Date = .distantPast

    /// Detected from the last JSONL entry.
    var waitingState: WaitingState = .none

    /// True when FSEvents detected a write in the last 30 seconds.
    var isRecentlyActive: Bool { Date() < liveActiveUntil }

    /// True only when an agent is blocked waiting for explicit approval (🔐).
    /// waitingForResponse is intentionally excluded — it fires after every reply
    /// and has no actionable urgency.
    var needsAttention: Bool {
        guard !isRecentlyActive else { return false }
        guard waitingState == .waitingForApproval else { return false }
        return Date().timeIntervalSince(lastActivity) < 3_600
    }

    var totalUsage: TokenCount {
        agents.values.reduce(usage) { $0 + $1 }
    }
}
