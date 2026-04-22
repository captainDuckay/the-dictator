import Foundation
import OSLog

enum AppLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "the-dictator"

    static let app = Logger(subsystem: subsystem, category: "App")
    static let workflow = Logger(subsystem: subsystem, category: "Workflow")
    static let settings = Logger(subsystem: subsystem, category: "Settings")
    static let notifications = Logger(subsystem: subsystem, category: "Notifications")

    static func debug(_ logger: Logger, _ message: String) {
#if DEBUG
        logger.debug("\(message, privacy: .public)")
#endif
    }

    static func info(_ logger: Logger, _ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    static func error(_ logger: Logger, _ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
