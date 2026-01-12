import Foundation

final class LogBuffer {
    static let shared = LogBuffer()
    private let queue = DispatchQueue(label: "LogBuffer.queue", qos: .utility)
    private var lines: [String] = []
    private let maxLines = 500

    private init() {}

    func add(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)"
        queue.async {
            self.lines.append(line)
            if self.lines.count > self.maxLines {
                self.lines.removeFirst(self.lines.count - self.maxLines)
            }
        }
    }

    func dumpText() -> String {
        var snapshot: [String] = []
        queue.sync { snapshot = self.lines }
        return snapshot.joined(separator: "\n")
    }
}
