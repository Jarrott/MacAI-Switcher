import Foundation
import XCTest

@testable import AISwitcher

/// Verifies real SQLite persistence using synthetic clocks and temporary database files.
@MainActor
final class RuntimePersistenceTests: XCTestCase {
    private func temporaryDatabase() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("runtime.sqlite")
    }

    /// First launch migrates to v1; repeated opening must preserve the existing duration.
    func testMigrationCreatesSingleRowAndPreservesSavedTotal() throws {
        let url = try temporaryDatabase()
        do {
            let store = try RuntimeStore(url: url)
            XCTAssertEqual(try store.integer("PRAGMA user_version"), 1)
            XCTAssertEqual(try store.totalMilliseconds(), 0)
            XCTAssertEqual(try store.add(milliseconds: 183_840_000), 183_840_000)
        }
        let reopened = try RuntimeStore(url: url)
        XCTAssertEqual(try reopened.totalMilliseconds(), 183_840_000)
        XCTAssertThrowsError(
            try reopened.execute(
                "INSERT INTO app_runtime (id, total_milliseconds) VALUES (2, 0)"))
        XCTAssertThrowsError(
            try reopened.execute(
                "UPDATE app_runtime SET total_milliseconds = -1 WHERE id = 1"))
        let permissions =
            try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    /// Restarting with a different monotonic baseline adds only the new process's running time.
    func testRuntimeContinuesAfterRestartAndExcludesDowntime() throws {
        let url = try temporaryDatabase()
        var uptime = 100.0
        do {
            let tracker = try RuntimeTracker(store: RuntimeStore(url: url), uptime: { uptime })
            uptime += 183_840
            try tracker.checkpoint()
            XCTAssertEqual(tracker.elapsed, 183_840, accuracy: 0.001)
        }
        uptime = 900_000  // Time passed while the application was closed is not accumulated.
        let reopened = try RuntimeTracker(store: RuntimeStore(url: url), uptime: { uptime })
        XCTAssertEqual(reopened.elapsed, 183_840, accuracy: 0.001)
        uptime += 75
        try reopened.checkpoint()
        XCTAssertEqual(try RuntimeStore(url: url).totalMilliseconds(), 183_915_000)
    }

    /// Shutdown's final checkpoint retains a partial minute without double-counting prior saves.
    func testRepeatedCheckpointsAndFinalPartialMinuteAreIdempotent() throws {
        let store = try RuntimeStore(url: temporaryDatabase())
        var uptime = 10.0
        let tracker = try RuntimeTracker(store: store, uptime: { uptime })
        uptime += 60
        try tracker.checkpoint()
        try tracker.checkpoint()
        uptime += 17.25
        try tracker.checkpoint()
        try tracker.checkpoint()
        XCTAssertEqual(try store.totalMilliseconds(), 77_250)
        XCTAssertEqual(tracker.elapsed, 77.25, accuracy: 0.001)
    }

    /// Killing a process without a final save preserves the last committed checkpoint.
    func testUncleanExitRetainsLastCheckpoint() throws {
        let url = try temporaryDatabase()
        var uptime = 1.0
        do {
            let tracker = try RuntimeTracker(store: RuntimeStore(url: url), uptime: { uptime })
            uptime += 60
            try tracker.checkpoint()
            uptime += 23
            XCTAssertEqual(tracker.elapsed, 83, accuracy: 0.001)
        }
        let reopened = try RuntimeTracker(store: RuntimeStore(url: url), uptime: { uptime })
        XCTAssertEqual(reopened.elapsed, 60, accuracy: 0.001)
    }

    /// Busy SQLite writes retain the unsaved interval and add it exactly once after recovery.
    func testLockFailureRetriesPendingTimeWithoutLossOrDuplication() throws {
        let url = try temporaryDatabase()
        let blocker = try RuntimeStore(url: url)
        let store = try RuntimeStore(url: url)
        var uptime = 0.0
        let tracker = try RuntimeTracker(store: store, uptime: { uptime })
        try blocker.execute("BEGIN IMMEDIATE")
        uptime = 60
        XCTAssertThrowsError(try tracker.checkpoint())
        XCTAssertEqual(tracker.elapsed, 60, accuracy: 0.001)
        try blocker.execute("ROLLBACK")
        uptime = 120
        try tracker.checkpoint()
        try tracker.checkpoint()
        XCTAssertEqual(try store.totalMilliseconds(), 120_000)
    }

    /// Separate connections atomically accumulate deltas instead of overwriting saved totals.
    func testSeparateApplicationInstancesCannotOverwriteEachOther() throws {
        let url = try temporaryDatabase()
        let first = try RuntimeStore(url: url)
        let second = try RuntimeStore(url: url)
        XCTAssertEqual(try first.add(milliseconds: 60_000), 60_000)
        XCTAssertEqual(try second.add(milliseconds: 25_000), 85_000)
        XCTAssertEqual(try first.add(milliseconds: 10_000), 95_000)
        XCTAssertEqual(try second.totalMilliseconds(), 95_000)
    }

    /// Schema versions newer than the app are rejected without erasing or rewriting saved data.
    func testFutureSchemaIsRejectedWithoutResettingRuntime() throws {
        let url = try temporaryDatabase()
        let store = try RuntimeStore(url: url)
        _ = try store.add(milliseconds: 45_000)
        try store.execute("PRAGMA user_version = 2")
        XCTAssertThrowsError(try RuntimeStore(url: url)) {
            guard case RuntimeStore.StoreError.unsupportedVersion(2) = $0 else {
                return XCTFail("Expected unsupported schema")
            }
        }
        XCTAssertEqual(try store.totalMilliseconds(), 45_000)
        XCTAssertEqual(try store.integer("PRAGMA user_version"), 2)
    }

    /// Corrupt storage is reported, not deleted or silently replaced with a fresh zero counter.
    func testCorruptDatabaseIsNotOverwritten() throws {
        let url = try temporaryDatabase()
        let data = Data("synthetic invalid SQLite database".utf8)
        try data.write(to: url)
        XCTAssertThrowsError(try RuntimeStore(url: url))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    /// The documented rollback restores a closed database backup without touching account files.
    func testDatabaseBackupCanRestorePreviousTotal() throws {
        let url = try temporaryDatabase()
        let backup = url.appendingPathExtension("backup")
        do { _ = try RuntimeStore(url: url).add(milliseconds: 60_000) }
        try FileManager.default.copyItem(at: url, to: backup)
        do { _ = try RuntimeStore(url: url).add(milliseconds: 40_000) }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: backup, to: url)
        XCTAssertEqual(try RuntimeStore(url: url).totalMilliseconds(), 60_000)
    }

    /// Missing singleton rows fail closed rather than implicitly creating a replacement record.
    func testMissingRuntimeRecordDoesNotResetToZero() throws {
        let url = try temporaryDatabase()
        let store = try RuntimeStore(url: url)
        try store.execute("DELETE FROM app_runtime WHERE id = 1")
        XCTAssertThrowsError(try RuntimeStore(url: url))
        XCTAssertThrowsError(try store.totalMilliseconds())
    }

    /// Integer overflow or negative intervals roll back the update and preserve the prior total.
    func testInvalidDurationAndOverflowLeaveSavedTotalIntact() throws {
        let store = try RuntimeStore(url: temporaryDatabase())
        XCTAssertThrowsError(try store.add(milliseconds: -1))
        _ = try store.add(milliseconds: Int64.max - 5)
        XCTAssertThrowsError(try store.add(milliseconds: 10))
        XCTAssertEqual(try store.totalMilliseconds(), Int64.max - 5)
    }

    /// Sub-millisecond remainder carries forward, and a backward clock cannot reduce runtime.
    func testFractionalIntervalsAndClockRegressionDoNotLoseSavedTime() throws {
        let store = try RuntimeStore(url: temporaryDatabase())
        var uptime = 10.0
        let tracker = try RuntimeTracker(store: store, uptime: { uptime })
        uptime += 0.0006
        try tracker.checkpoint()
        uptime += 0.0006
        try tracker.checkpoint()
        XCTAssertEqual(try store.totalMilliseconds(), 1)
        uptime = 5
        try tracker.checkpoint()
        XCTAssertEqual(try store.totalMilliseconds(), 1)
        XCTAssertGreaterThanOrEqual(tracker.elapsed, 0.001)
    }
}
