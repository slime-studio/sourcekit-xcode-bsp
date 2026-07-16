import Darwin
import Foundation

/// Read/write access to process environment variables.
public protocol EnvironmentRepository: Sendable {
    /// Returns the value for the given environment variable, or `nil` if unset.
    func get(_ key: String) -> String?

    /// Sets an environment variable.
    ///
    /// - Parameters:
    ///   - key: The variable name.
    ///   - value: The value to assign.
    ///   - overwrite: When `false`, an existing value is left unchanged.
    func set(_ key: String, value: String, overwrite: Bool)
}

/// Pass-through implementation that reads and writes the real process environment.
public struct ProcessEnvironmentRepository: EnvironmentRepository {
    public init() {}

    public func get(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key]
    }

    public func set(_ key: String, value: String, overwrite: Bool) {
        setenv(key, value, overwrite ? 1 : 0)
    }
}
