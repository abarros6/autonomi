// Logger.swift
// Structured logging via os.log.
// Each module creates its own AppLogger with a category tag for filtering in Console.app.

import Foundation
import os.log

/// Thin wrapper around os.Logger providing module-tagged, level-differentiated logging.
///
/// Usage:
///   private let logger = AppLogger(category: "ExecutionEngine")
///   logger.info("Intent '\(intent)' dispatched")
///   logger.error("Unexpected failure: \(error)")
struct AppLogger {

    private let inner: Logger

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.assistivecontrol.app"

    /// - Parameter category: The module or component name, shown in Console.app filter.
    init(category: String) {
        self.inner = Logger(subsystem: Self.subsystem, category: category)
    }

    // MARK: - Log Levels

    /// Informational message — normal operational events.
    func info(_ message: String) {
        inner.info("\(message, privacy: .public)")
    }

    /// Debug message — verbose detail for development; excluded from release logs by default.
    func debug(_ message: String) {
        inner.debug("\(message, privacy: .public)")
    }

    /// Warning — something unexpected occurred but execution can continue.
    func warning(_ message: String) {
        inner.warning("\(message, privacy: .public)")
    }

    /// Error — a failure occurred that impacts the operation.
    func error(_ message: String) {
        inner.error("\(message, privacy: .public)")
    }

    /// Fault — a critical, unrecoverable condition.
    func fault(_ message: String) {
        inner.fault("\(message, privacy: .public)")
    }
}
