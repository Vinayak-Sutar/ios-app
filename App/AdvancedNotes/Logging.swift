import Foundation
import OSLog

/// Structured logging, and a way to read it back without a Mac.
///
/// There is no debugger on this project: the Swift is compiled on a CI runner
/// and installed over USB. `OSLogStore` lets the app read its own `Logger`
/// output, which makes an in-app log view the nearest thing to attaching a
/// debugger. Wiring this up first, before any feature, is deliberate.
enum Log {
    static let subsystem = "app.advancednotes"

    static let server = Logger(subsystem: subsystem, category: "server")
    static let routes = Logger(subsystem: subsystem, category: "routes")
    static let model = Logger(subsystem: subsystem, category: "model")
    static let embed = Logger(subsystem: subsystem, category: "embed")
    static let vault = Logger(subsystem: subsystem, category: "vault")

    /// Recent log lines for this process, newest last.
    ///
    /// Only this process's own entries, and only our subsystem — reading the
    /// whole system store is both slow and none of our business.
    static func recentEntries(sinceMinutes minutes: Int = 60, limit: Int = 2000) -> [String] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let start = store.position(date: Date().addingTimeInterval(-Double(minutes) * 60))
            let entries = try store.getEntries(at: start)
                .compactMap { $0 as? OSLogEntryLog }
                .filter { $0.subsystem == subsystem }
                .suffix(limit)

            let stamp = ISO8601DateFormatter()
            return entries.map { entry in
                "\(stamp.string(from: entry.date)) [\(entry.category)] \(levelName(entry.level)) \(entry.composedMessage)"
            }
        } catch {
            return ["could not read the log store: \(error.localizedDescription)"]
        }
    }

    private static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        case .undefined: return "?"
        @unknown default: return "?"
        }
    }
}
