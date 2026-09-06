import Foundation

enum Log {
    static var verbose = false

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        emit("INFO", message)
    }

    static func debug(_ message: String) {
        guard verbose else { return }
        emit("DEBUG", message)
    }

    static func error(_ message: String) {
        emit("ERROR", message)
    }

    private static func emit(_ level: String, _ message: String) {
        print("[\(formatter.string(from: Date()))] \(level) \(message)")
        fflush(stdout)
    }
}
