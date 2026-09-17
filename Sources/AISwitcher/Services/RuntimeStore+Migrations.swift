import Foundation

extension RuntimeStore {
    /// Migration 1 creates a bounded, one-row integer accumulator in a transaction.
    /// Existing v1 totals survive restarts. Future versions are rejected without schema changes.
    /// Rollback: quit the app and restore a backup of runtime.sqlite, or remove only this database
    /// to intentionally reset runtime. Account storage is independent; see docs/DATABASE.md.
    func migrate() throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let version = try integer("PRAGMA user_version")
            switch version {
            case 0:
                try execute(
                    """
                    CREATE TABLE app_runtime (
                        id INTEGER PRIMARY KEY CHECK (id = 1),
                        total_milliseconds INTEGER NOT NULL DEFAULT 0
                            CHECK (typeof(total_milliseconds) = 'integer' AND total_milliseconds >= 0)
                    )
                    """)
                try execute("INSERT INTO app_runtime (id, total_milliseconds) VALUES (1, 0)")
                try execute("PRAGMA user_version = 1")
            case 1:
                _ = try totalMilliseconds()
            default:
                throw StoreError.unsupportedVersion(version)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}
