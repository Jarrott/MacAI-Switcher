import Foundation

/// Combines committed runtime with a monotonic delta; no wall-clock timestamps are persisted.
@MainActor
final class RuntimeTracker {
    private let store: RuntimeStore
    private let uptime: () -> TimeInterval
    private var checkpointUptime: TimeInterval
    private var savedMilliseconds: Int64

    /// Restore saved runtime and begin a process interval, optionally including startup time.
    /// Throws on unreadable database state; the caller decides when to retry opening storage.
    init(
        store: RuntimeStore,
        startedAt: TimeInterval? = nil,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) throws {
        self.store = store
        self.uptime = uptime
        checkpointUptime = startedAt ?? uptime()
        savedMilliseconds = try store.totalMilliseconds()
    }

    /// Return saved plus unsaved runtime in seconds; reading the menu never writes SQLite.
    var elapsed: TimeInterval {
        Double(savedMilliseconds) / 1_000 + max(0, uptime() - checkpointUptime)
    }

    /// Commit only the unsaved interval and advance the baseline after successful persistence.
    /// Fractional milliseconds carry forward. Failures preserve the whole interval for retry;
    /// repeated calls at the same uptime add nothing and restarts exclude application downtime.
    func checkpoint() throws {
        let delta = max(0, uptime() - checkpointUptime)
        let milliseconds = (delta * 1_000).rounded(.down)
        guard milliseconds.isFinite, milliseconds < Double(Int64.max) else {
            throw RuntimeStore.StoreError.invalidDuration
        }
        let committed = Int64(milliseconds)
        guard committed > 0 else { return }
        let total = try store.add(milliseconds: committed)
        savedMilliseconds = total
        checkpointUptime += Double(committed) / 1_000
    }
}
