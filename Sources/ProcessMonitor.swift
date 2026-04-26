import Foundation

/// Counts running `claude` and `codex` CLI processes using pgrep.
/// Polls every 5 seconds; fires `onCountChange` only when any count changes.
final class ProcessMonitor {
    var onCountChange: ((Int) -> Void)?

    private(set) var claudeCount: Int = 0
    private(set) var codexCount: Int = 0

    /// Total processes across all providers.
    var count: Int { claudeCount + codexCount }

    private var timer: Timer?

    func start() {
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.scan()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func scan() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let newClaude = Self.countProcesses(named: "claude")
            let newCodex  = Self.countProcesses(named: "codex")
            DispatchQueue.main.async {
                guard let self else { return }
                if newClaude != self.claudeCount || newCodex != self.codexCount {
                    self.claudeCount = newClaude
                    self.codexCount  = newCodex
                    self.onCountChange?(self.count)
                }
            }
        }
    }

    private static func countProcesses(named name: String) -> Int {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-x", name]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return 0
        }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }
}
