import Foundation

/// Incrementally parses Claude CLI JSONL session files to extract token usage.
/// Tracks the last-read byte offset per file so each call only processes new lines.
final class TokenParser {
    private var fileOffsets: [String: UInt64] = [:]

    // MARK: - Public API

    /// Full re-parse of a file (resets the tracked offset).
    func parseFull(fileURL: URL, agentId: String? = nil) -> TokenCount {
        fileOffsets[fileURL.path] = nil
        return parseIncremental(fileURL: fileURL, agentId: agentId) ?? TokenCount()
    }

    /// Read only the bytes added since the last call. Returns nil if nothing new.
    @discardableResult
    func parseIncremental(fileURL: URL, agentId: String? = nil) -> TokenCount? {
        let path = fileURL.path
        let currentOffset = fileOffsets[path] ?? 0

        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? fileHandle.close() }

        let fileSize = (try? fileHandle.seekToEnd()) ?? 0
        guard fileSize > currentOffset else { return nil }

        try? fileHandle.seek(toOffset: currentOffset)
        let newData = fileHandle.readDataToEndOfFile()

        guard let content = String(data: newData, encoding: .utf8) else { return nil }

        // Only advance offset up to the last complete newline to avoid partial-line issues.
        guard let lastNL = content.lastIndex(of: "\n") else {
            fileOffsets[path] = currentOffset  // nothing complete yet
            return nil
        }

        let completeContent = String(content[content.startIndex...lastNL])
        fileOffsets[path] = currentOffset + UInt64(completeContent.utf8.count)

        return parseLines(completeContent)
    }

    func resetOffset(for fileURL: URL) {
        fileOffsets[fileURL.path] = nil
    }

    /// Reads the last complete JSON entry from a JSONL file without touching the offset.
    static func readLastEntry(fileURL: URL) -> [String: Any]? {
        guard let fh = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? fh.close() }

        let size = (try? fh.seekToEnd()) ?? 0
        guard size > 0 else { return nil }

        // Read up to the last 8 KB — enough for any single JSONL entry
        let chunk = min(size, 8192)
        try? fh.seek(toOffset: size - chunk)
        let data = fh.readDataToEndOfFile()

        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let lastLine = text.components(separatedBy: "\n").last(where: { !$0.isEmpty }),
              let lineData = lastLine.data(using: .utf8)
        else { return nil }

        return try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
    }

    // MARK: - Private

    private func parseLines(_ content: String) -> TokenCount {
        var result = TokenCount()

        for line in content.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let usage = extractUsage(from: json) {
                result += usage
            }
        }

        return result
    }

    /// Extracts a TokenCount from a JSONL entry, handling both direct assistant
    /// messages and nested progress events (subagents).
    private func extractUsage(from json: [String: Any]) -> TokenCount? {
        let type = json["type"] as? String

        // Direct assistant message
        if type == "assistant",
           let message = json["message"] as? [String: Any],
           let usage = message["usage"] as? [String: Any] {
            return tokenCount(from: usage)
        }

        // Progress event (subagent writing into parent session file)
        if type == "progress",
           let data = json["data"] as? [String: Any],
           let message = data["message"] as? [String: Any],
           let usage = message["usage"] as? [String: Any] {
            return tokenCount(from: usage)
        }

        return nil
    }

    private func tokenCount(from usage: [String: Any]) -> TokenCount {
        TokenCount(
            input:         usage["input_tokens"]                  as? Int ?? 0,
            output:        usage["output_tokens"]                 as? Int ?? 0,
            cacheCreation: usage["cache_creation_input_tokens"]   as? Int ?? 0,
            cacheRead:     usage["cache_read_input_tokens"]       as? Int ?? 0
        )
    }
}
