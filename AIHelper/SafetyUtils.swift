import Foundation
import os.log

/// Centralized logging for the app
enum AppLogger {
    private static let subsystem = "com.aihelper.app"

    static let general = Logger(subsystem: subsystem, category: "general")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let transcription = Logger(subsystem: subsystem, category: "transcription")
    static let prompts = Logger(subsystem: subsystem, category: "prompts")
    static let ui = Logger(subsystem: subsystem, category: "ui")
}

/// Safely executes a throwing closure and logs any errors
/// - Parameters:
///   - operation: Description of the operation for logging
///   - logger: Logger to use
///   - block: The closure to execute
/// - Returns: The result of the closure, or nil if it threw
func safeExecute<T>(
    _ operation: String,
    logger: Logger = AppLogger.general,
    _ block: () throws -> T
) -> T? {
    do {
        return try block()
    } catch {
        logger.error("[\(operation)] Failed: \(error.localizedDescription)")
        return nil
    }
}

/// Safely executes an async throwing closure and logs any errors
/// - Parameters:
///   - operation: Description of the operation for logging
///   - logger: Logger to use
///   - block: The async closure to execute
/// - Returns: The result of the closure, or nil if it threw
func safeExecuteAsync<T>(
    _ operation: String,
    logger: Logger = AppLogger.general,
    _ block: () async throws -> T
) async -> T? {
    do {
        return try await block()
    } catch {
        logger.error("[\(operation)] Failed: \(error.localizedDescription)")
        return nil
    }
}

/// Extension for safe UserDefaults operations
extension UserDefaults {
    /// Safely decode a Codable object from UserDefaults
    func safeDecode<T: Codable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = data(forKey: key) else {
            return nil
        }

        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            AppLogger.general.error("Failed to decode \(String(describing: type)) for key '\(key)': \(error.localizedDescription)")
            // Remove corrupted data
            removeObject(forKey: key)
            return nil
        }
    }

    /// Safely encode and store a Codable object
    func safeEncode<T: Codable>(_ value: T, forKey key: String) {
        do {
            let data = try JSONEncoder().encode(value)
            set(data, forKey: key)
        } catch {
            AppLogger.general.error("Failed to encode \(String(describing: type(of: value))) for key '\(key)': \(error.localizedDescription)")
        }
    }
}

/// Extension for safe array operations
extension Array {
    /// Safely access an element at index, returns nil if out of bounds
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Extension for safe string operations
extension String {
    /// Truncate string to a maximum length
    func truncated(to maxLength: Int, trailing: String = "...") -> String {
        if count <= maxLength {
            return self
        }
        return String(prefix(maxLength - trailing.count)) + trailing
    }
}

/// Crash protection wrapper for view initialization
@MainActor
func safeLaunch(_ block: @escaping () -> Void) {
    DispatchQueue.main.async {
        autoreleasepool {
            block()
        }
    }
}
