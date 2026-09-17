# Local runtime database

## Scope and ownership

`~/Library/Application Support/AISwitcher/runtime.sqlite` stores accumulated
application process runtime, across launches, in integer milliseconds. It contains
no accounts, credentials, logs, device identifiers or event history. The parent is
created with owner-only `0700` permissions and the database uses `0600`.

`RuntimeStore` owns all SQL. `RuntimeTracker` calculates pending monotonic intervals;
`AppRuntime` loads at normal startup and saves every 60 seconds and at normal exit.
Menu reads use the in-memory total. Preview rendering bypasses tracking entirely.
The app uses one connection with a 100 ms busy timeout. SQLite's normal rollback
journal and `synchronous=FULL` protect committed writes; journal files are transient.

The project previously had no database layer. The system SQLite C API is used for
this single atomic counter and SQLite-specific schema/version control; adding an ORM
and third-party dependency for one fixed row is unnecessary. SQL is restricted to
the repository/migration files, with bound parameters for runtime values.

## Version 1 migration (Up)

`RuntimeStore+Migrations.swift` checks `PRAGMA user_version` inside a
`BEGIN IMMEDIATE` transaction. A new database at version 0 executes:

```sql
CREATE TABLE app_runtime (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    total_milliseconds INTEGER NOT NULL DEFAULT 0
        CHECK (typeof(total_milliseconds) = 'integer' AND total_milliseconds >= 0)
);
INSERT INTO app_runtime (id, total_milliseconds) VALUES (1, 0);
PRAGMA user_version = 1;
```

The schema and initial record commit together or roll back together. Version 1
validates the saved singleton; it never recreates a missing record silently.
Unsupported future schema versions and corrupt databases fail without resetting
runtime. Future schema changes must add a new versioned migration; do not edit v1
after release.

| Field | Type | Contract |
|---|---|---|
| `id` | INTEGER PRIMARY KEY | Required; always 1; prevents additional runtime rows |
| `total_milliseconds` | INTEGER | Required; default 0; nonnegative signed 64-bit milliseconds; no nulls or rounding of stored values |

Older versions kept runtime only in process memory. There is no historical file
or table to migrate, so the initial total is zero. No account records are changed.
There are no foreign keys, additional indexes, timestamp formats or timezone fields.

## Checkpoints and query plan

The tracker keeps the prior successful monotonic checkpoint. Each save binds the
new nonnegative interval and an overflow limit, then executes this short transaction:

```sql
BEGIN IMMEDIATE;
UPDATE app_runtime
SET total_milliseconds = total_milliseconds + ?
WHERE id = 1 AND total_milliseconds <= ?;
SELECT total_milliseconds FROM app_runtime WHERE id = 1;
COMMIT;
```

The bound overflow limit is `Int64.max - delta`. Exactly one row must be updated.
Any update/read/commit failure rolls back; only a successful commit advances the
in-memory checkpoint. Partial milliseconds carry into the next interval. Separate
processes add their own elapsed intervals rather than overwriting each other's totals;
concurrently running copies therefore contribute their respective process runtimes.

Both lookup and update use `SEARCH app_runtime USING INTEGER PRIMARY KEY (rowid=?)`
under `EXPLAIN QUERY PLAN`. The table is permanently bounded to one row, with no
pagination, history scans, joins, text search, counts, aggregation jobs, caches,
partitioning or archival requirements. It cannot grow toward a million-row workload.
No network call is made inside a database transaction.

A forced kill or power loss retains the last committed checkpoint. During healthy
60-second checkpoint scheduling, normally less than one minute is lost. A delayed
main thread or failed storage can extend that unsaved interval. Normal quit flushes
the remaining partial minute. Persistent write failure is logged without contents;
the app never deletes the database to hide an error.

## Backup and rollback (Down procedure)

1. Quit every running copy of AI Switcher so no database transaction is active.
2. Back up `runtime.sqlite` before a database migration or intentional reset. With
   all connections cleanly closed, the normal rollback journal is absent. Do not
   remove a leftover hot journal after an abnormal exit; let SQLite recover first.
3. To roll back to a backed-up schema/data version, restore that closed database
   backup and run the matching app version. The regression suite exercises this
   backup/restore path.
4. To return to a version before SQLite runtime tracking, keep the database backup;
   the older application ignores it. To intentionally undo v1 completely, remove
   only `runtime.sqlite` after clean shutdown; the next new-version launch recreates
   v1 at zero. This intentionally loses the runtime total, not account data.

Do not remove the `AISwitcher` directory, `accounts.json` or credential snapshots.
A future-version database is never automatically downgraded.

## Verification

`RuntimePersistenceTests` uses real SQLite files in temporary directories and
synthetic clocks to cover first migration, reopening, continuing accumulated days,
excluding downtime, repeated checkpoints, partial-minute exit saves, unclean exit,
lock/retry behavior, independent connections, corruption, future schema rejection,
integer overflow, missing records and restoring a backup. It never touches the real
runtime database or provider credentials.

SQLite contracts: [transactions](https://www.sqlite.org/lang_transaction.html),
[application schema version](https://www.sqlite.org/pragma.html#pragma_user_version),
[busy timeout](https://www.sqlite.org/c3ref/busy_timeout.html).
