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

/// Prints `message` only in DEBUG builds. In Release this is a no-op so
/// internal diagnostics never reach the unified system log on user devices.
///
/// Use this for any service-layer trace logging. For user-actionable errors
/// that should always be recorded, post to `LogBuffer.shared.add` instead
/// (the in-memory buffer powers the in-app "Copy Logs" support feature, and
/// callers are expected to redact identifiers before adding).
@inlinable
func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}
