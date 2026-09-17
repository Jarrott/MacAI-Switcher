import Foundation
import OSLog

/// Persists accumulated application runtime across launches using a local SQLite counter.
/// Process intervals use the monotonic system clock, so clock/time-zone changes do not add time.
@MainActor
enum AppRuntime {
    private static let logger = Logger(subsystem: "com.aiswitcher.app", category: "runtime")
    private static var startedAt: TimeInterval?
    private static var tracker: RuntimeTracker?
    private static var checkpointTask: Task<Void, Never>?
    private static var reportedStorageFailure = false

    static let databaseURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AISwitcher/runtime.sqlite")

    /// Restore saved runtime at normal application startup and checkpoint every minute.
    /// Repeated calls do nothing; preview rendering deliberately never invokes this method.
    /// Storage failures preserve pending process time and are retried at the next checkpoint.
    static func beginTracking() {
        guard startedAt == nil else { return }
        startedAt = ProcessInfo.processInfo.systemUptime
        checkpoint()
        checkpointTask = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard !Task.isCancelled else { return }
                checkpoint()
            }
        }
    }

    /// Return total runtime in seconds without accessing SQLite during menu rendering.
    /// If storage cannot be opened, show the current process interval until recovery.
    /// Preview mode returns zero and never creates or modifies the production database.
    static var elapsed: TimeInterval {
        if let tracker { return tracker.elapsed }
        guard let startedAt else { return 0 }
        return max(0, ProcessInfo.processInfo.systemUptime - startedAt)
    }

    /// Flush the final partial minute during normal AppKit termination and stop the save task.
    /// A failed final write is logged without deleting or resetting previously saved runtime.
    static func saveBeforeExit() {
        checkpointTask?.cancel()
        checkpointTask = nil
        checkpoint()
    }

    /// Open/retry storage and save only time not previously committed by this process.
    /// Errors are logged once per failure period without file contents or account information.
    private static func checkpoint() {
        guard let startedAt else { return }
        do {
            if tracker == nil {
                tracker = try RuntimeTracker(
                    store: RuntimeStore(url: databaseURL), startedAt: startedAt)
            }
            try tracker?.checkpoint()
            reportedStorageFailure = false
        } catch {
            if !reportedStorageFailure {
                logger.error("Runtime could not be saved to SQLite; pending time will be retried.")
                reportedStorageFailure = true
            }
        }
    }
}
