import Foundation

/// Counts running `claude` CLI processes using `ps`.
/// Polls every 5 seconds; fires `onCountChange` only when the count changes.
final class ProcessMonitor {
    var onCountChange: ((Int) -> Void)?
    private(set) var count: Int = 0
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
            let newCount = Self.countClaudeProcesses()
            DispatchQueue.main.async {
                guard let self else { return }
if newCount != self.count {
                    self.count = newCount
                    self.onCountChange?(newCount)
                }
            }
        }
    }

    private static func countClaudeProcesses() -> Int {
        // pgrep -x matches the exact process name "claude" — more reliable than
        // parsing ps output which truncates comm to 16 chars in some environments.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-x", "claude"]

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
