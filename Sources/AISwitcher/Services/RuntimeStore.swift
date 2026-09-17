import Foundation
import SQLite3

/// One-row SQLite repository for lifetime runtime; contains no account or credential data.
/// Uses the system SQLite API for an atomic counter instead of adding an ORM dependency.
/// The owning tracker serializes calls; SQLite transactions also protect separate app processes.
final class RuntimeStore {
    enum StoreError: Error {
        case sqlite(Int32)
        case unsupportedVersion(Int64)
        case invalidDuration
        case invalidRecord
    }

    private var database: OpaquePointer?

    /// Open the local database, restrict permissions, and apply versioned migrations.
    /// - Parameter url: Explicit SQLite file URL, overridden by tests with temporary storage.
    /// - Throws: Filesystem, SQLite, schema-version or data-validation errors; never resets data.
    /// - Side effects: Creates a private directory/file and at most one runtime row.
    init(url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let status = sqlite3_open_v2(
            url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil)
        guard status == SQLITE_OK else {
            sqlite3_close(database)
            database = nil
            throw StoreError.sqlite(status)
        }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
            // Bound UI-thread contention; failed saves retain their pending delta for retry.
            guard sqlite3_busy_timeout(database, 100) == SQLITE_OK else {
                throw StoreError.sqlite(sqlite3_errcode(database))
            }
            try execute("PRAGMA synchronous = FULL")
            try migrate()
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    /// Read the sole nonnegative integer duration, using the primary-key lookup.
    /// Throws on missing/corrupt data instead of silently replacing a saved total with zero.
    func totalMilliseconds() throws -> Int64 {
        let total = try integer("SELECT total_milliseconds FROM app_runtime WHERE id = 1")
        guard total >= 0 else { throw StoreError.invalidRecord }
        return total
    }

    /// Atomically add a pending monotonic duration and return the committed global total.
    /// - Parameter milliseconds: Nonnegative elapsed milliseconds since the caller's last save.
    /// - Throws: Invalid duration, overflow, missing row, lock contention or storage failure.
    /// - Side effects: One short write transaction; failures roll back and can be retried.
    func add(milliseconds: Int64) throws -> Int64 {
        guard milliseconds >= 0 else { throw StoreError.invalidDuration }
        try execute("BEGIN IMMEDIATE")
        do {
            try execute(
                """
                UPDATE app_runtime SET total_milliseconds = total_milliseconds + ?
                WHERE id = 1 AND total_milliseconds <= ?
                """,
                parameters: [milliseconds, Int64.max - milliseconds])
            guard sqlite3_changes(database) == 1 else { throw StoreError.invalidRecord }
            let total = try totalMilliseconds()
            try execute("COMMIT")
            return total
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Execute repository-owned SQL, binding every runtime value as a 64-bit integer.
    /// Statements are always finalized; SQLite failures expose numeric codes only.
    func execute(_ sql: String, parameters: [Int64] = []) throws {
        try statement(sql) { statement in
            for (index, value) in parameters.enumerated() {
                let status = sqlite3_bind_int64(statement, Int32(index + 1), value)
                guard status == SQLITE_OK else { throw StoreError.sqlite(status) }
            }
            let status = sqlite3_step(statement)
            guard status == SQLITE_DONE else { throw StoreError.sqlite(status) }
        }
    }

    /// Read one integer from repository-owned scalar SQL; reject NULL, REAL and missing rows.
    func integer(_ sql: String) throws -> Int64 {
        try statement(sql) { statement in
            let status = sqlite3_step(statement)
            guard status == SQLITE_ROW else { throw StoreError.sqlite(status) }
            guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER else {
                throw StoreError.invalidRecord
            }
            return sqlite3_column_int64(statement, 0)
        }
    }

    /// Prepare and release one statement around a throwing operation; SQL is never user input.
    private func statement<T>(_ sql: String, body: (OpaquePointer) throws -> T) throws -> T {
        var prepared: OpaquePointer?
        let status = sqlite3_prepare_v2(database, sql, -1, &prepared, nil)
        guard status == SQLITE_OK, let prepared else { throw StoreError.sqlite(status) }
        defer { sqlite3_finalize(prepared) }
        return try body(prepared)
    }
}
