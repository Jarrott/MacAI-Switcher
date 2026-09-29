# Functional specification

## Menu bar

The app presents a compact translucent menu. Accounts are grouped in stable
OpenAI/Codex and Anthropic/Claude sections even if discovery returns a different
order. Each section uses official compact provider artwork, a distinct cool or
warm low-opacity accent, and a bordered glass surface. Each account row shows
its plan as a compact accent badge, remaining 5-hour quota, remaining 7-day quota,
reset dates, manual reset-credit availability, active state, loading state, and
the most recent refresh error when applicable.

The menu header shows accumulated application runtime ("Total runtime" / "累计运行")
across launches. It restores the saved SQLite total, adds the current process's
monotonic interval, and refreshes its text once per minute without triggering any
provider usage request. Time while the application is closed is excluded. If trial
metadata is available, both statuses are shown.

Runtime is checkpointed to `~/Library/Application Support/AISwitcher/runtime.sqlite`
every 60 seconds and during normal application termination. Each transaction adds
only the unsaved interval; repeated saves do not double-count time. An abnormal exit
retains the latest successful checkpoint (normally losing less than one minute,
assuming the timer runs and storage remains writable). Lock or write failures retain
the pending interval for retry and log a non-sensitive diagnostic. If the database
cannot initially be opened, only the current process interval is available for display
until storage recovers; existing data is never deleted or reset as error recovery.

Older versions kept runtime only in process memory, so previously closed sessions
cannot be reconstructed. Accumulation begins with the first launch of this version.
Preview mode shows zero runtime and neither opens nor modifies the runtime database.
The schema, migration and rollback contract are in [DATABASE.md](DATABASE.md).

The status item uses a monochrome vector switch glyph at an 18-point logical
size. AppKit rasterizes the SVG at the current display scale and applies native
template tinting, avoiding bitmap enlargement on Retina screens.

Codex and Claude are separate CLI providers. One account can be active for each
provider at the same time. Selecting an account replaces only that provider's
live credential.

Available menu actions are:

- Add Account / Import Current Login (`⌘N`)
- Account Settings
- Launch at Login (`⌘L`)
- Refresh Now (`⌘R`)
- Quit (`⌘Q`)

There are no purchase actions until a real StoreKit product and restore flow are
configured. Placeholder actions must not be presented as working features.

## Account discovery and switching

- Codex reads `~/.codex/auth.json`.
- Claude reads the `Claude Code-credentials` Keychain item, with
  `~/.claude/.credentials.json` as fallback.
- The current login is snapshotted under Application Support before it becomes a
  managed account.
- Discovery reconciles the live credential with the persisted account and marks
  the matching account active for its provider.
- Startup reconciles and persists the file-backed Codex login before reading the
  Claude Keychain, so a delayed Keychain response cannot suppress the Codex
  active checkmark.
- Startup discovery begins from AppKit's launch-completion lifecycle instead of
  SwiftUI value initialization, ensuring credential reconciliation runs reliably
  for a menu-bar-only application.
- Claude identifiers use a deterministic SHA-256-derived credential fingerprint. Legacy snapshots
  created with Swift `hashValue` are reconciled by credential equality.

For Codex shared-server login caching, local terminal integration, identity
verification and safe session recovery, see [CODEX_TERMINALS.md](CODEX_TERMINALS.md).
The active checkmark represents the selected live credential, not proof that an
already-running CLI or background server has reloaded it.
The optional [Codex 0.159.0 email-display repair](CODEX_STATUS_EMAIL.md) restores
the native `/status` email using the session backend's identity. It does not
change the selected credential or synchronize running sessions. Utilities and
newer upstream CLI versions continue to use the official executable.
The optional [input extension](CODEX_INPUT.md) adds a rounded four-sided input frame,
terminal-matched background, balanced padding and AI ghost-text suggestions. Completion uses the current backend in an
isolated temporary thread; Tab accepts text and Enter never implicitly accepts it.

## Add account

- Add Account opens a dedicated utility window and lets the user select Codex or
  Claude.
- The window shows the provider login command (`codex login` or
  `claude auth login`), can copy it, and can open Terminal.
- Sign In with Browser locates the installed provider CLI, runs its official
  OAuth login process without requiring a Terminal window, waits for the browser
  flow to finish, imports the CLI credential, and refreshes usage. Missing CLIs,
  failed launches, cancellations, and missing post-login credentials show
  distinct errors.
- Browser login prepends the resolved CLI directory and common Homebrew/system
  directories to the GUI process PATH. This lets NVM-installed Codex scripts
  resolve their adjacent `node` runtime. Closing the window or choosing Cancel
  terminates the in-flight CLI process.
- Application shutdown terminates every registered browser-login wrapper and its
  direct provider CLI child before exit, preventing orphaned `codex login` or
  `claude auth login` processes.
- Codex browser OAuth runs with a unique owner-only temporary `CODEX_HOME`.
  Closing the browser, cancelling, or a failed CLI exit therefore cannot delete,
  replace, or log out the currently selected Codex account. The staged
  `auth.json` is validated and atomically activated only after OAuth succeeds;
  its temporary directory is removed on success, failure, and cancellation.
- Before OAuth starts, the current live credential is reconciled and securely
  snapshotted. Cancellation, browser closure, CLI failure, or a successful CLI
  exit without a usable new credential restores both the previous live credential
  and its active marker. A different account explicitly selected while OAuth is
  open is never overwritten by rollback.
- Import Current Login validates the provider's live credential, creates an
  owner-only managed snapshot, reconciles duplicates, marks that provider account
  active, and refreshes usage.
- Import Credential File accepts one JSON file, validates it against the selected
  provider, and creates an owner-only managed snapshot without replacing the live
  CLI credential. Invalid, unreadable, or identity-less files show an error.

## Account settings

- Hovering Account Settings immediately opens a submenu containing every managed
  login. Each row shows the corresponding provider artwork, and active provider
  accounts show checkmarks; selecting a row switches that provider credential and
  dismisses the submenu. A short dismissal delay lets the pointer cross from the
  parent row without closing the submenu.
- Clicking Account Settings, or choosing Manage Accounts from its submenu, opens
  the dedicated utility window.
- Native popover dismissal, application focus loss, and menu closure immediately
  cancel delayed hover work and clear the parent-row highlight. Clicking Account
  Settings closes its submenu before the management window opens.
- Account names can be customized; provider discovery updates generated metadata
  without overwriting the custom name.
- Inactive accounts can be activated from the list. Activation replaces only the
  selected provider's live credential.
- Inactive accounts can be removed after confirmation. The active account is
  protected from deletion, and successful removal also deletes its managed
  credential snapshot.
- Usage can be refreshed from the settings window. Empty, refreshing, and error
  states are visible.

## Menu interaction regions

- Only each account title row is a switch-account button.
- The 5-hour and 7-day bars, percentages, and reset dates are display-only and do
  not trigger account switching.
- A positive Codex reset-credit count is a separate full-width action row. Its
  default surface is subtle and its hover state uses the same neutral translucent
  light-gray surface as the other interactive rows. Zero or unavailable counts
  remain non-interactive text.
- The first reset-row click never consumes a credit. It opens a strong warning
  naming the account, stating that one credit is consumed immediately and that
  the action cannot be undone. The alert provides destructive Confirm Reset and
  explicit Cancel Reset actions; only confirmation starts the provider request.
- Reset confirmation and result dialogs use independent AppKit alert windows,
  not SwiftUI presentation state attached to the transient `MenuBarExtra` host.
  Cancel, Escape, and alert dismissal therefore close the modal window completely
  and cannot leave an orphaned overlay or trigger redemption.
- Confirmed reset requests are idempotent, coalesce repeated taps, prefer the
  earliest-expiring provider credit, and refresh the account snapshot after a
  recognized outcome. Unknown responses are errors and are never inferred as
  successful. Success, already-redeemed, nothing-to-reset, no-credit, and failure
  outcomes receive distinct user-visible messages.
- Action rows, account titles, and account-submenu rows use a neutral translucent
  light-gray surface while hovered instead of the system accent color. The Account
  Settings row remains highlighted while its account submenu is open.
- Main and submenu surfaces share a lightweight native popover material, subtle
  cool tint, continuous border, and system-font hierarchy. Desktop colors remain
  visibly blurred through the panel without reducing primary-text legibility.
- Main account titles, usage values, reset metadata, menu actions, submenu rows,
  and their indicator symbols all use regular weight. Hierarchy comes from size,
  spacing, and opacity rather than bold typography.
- The visual-effect layer is partially composited rather than fully opaque, so
  recognizable background color boundaries and silhouettes remain visible under
  the blur. A low-opacity cool tint and bottom gradient provide text contrast.
- The MenuBarExtra and account-switcher popover windows clear their own opaque
  backing surfaces before applying native menu material. The blur therefore
  samples the actual desktop/window behind the menu rather than an intermediate
  SwiftUI window color. Transparency is reapplied when the ephemeral window is
  ordered, activated, rehosted, or redrawn so live display and screenshots use
  the same composition.
- Glass intensity is applied through `NSVisualEffectView.alphaValue`, not a
  SwiftUI opacity wrapper. This keeps real-time WindowServer composition aligned
  with captured frames. The main menu currently uses a 10% material alpha so
  browser boundaries remain clearly recognizable behind the text.

## Usage refresh

- Usage refresh runs once at application launch, every five minutes while the
  application remains active, and only when the user explicitly chooses Refresh
  Now. Opening or reopening the menu is display-only and never starts a request.
- Accounts refresh concurrently.
- A failed refresh retains the last successful snapshot and displays an error;
  it does not silently replace unknown values with zero.
- Provider payloads report consumed percentages; the menu displays and fills bars
  with `100 - used_percent`, matching the reference switcher’s remaining quota.
- Remaining-quota bars use compact, partially fillable segments. Each usage window
  is red below 10%, yellow from 10% through 50%, and green above 50%. Unknown
  provider values keep a neutral track and `--%` label instead of becoming zero.
- Access tokens are refreshed shortly before expiry and once after HTTP 401.
  HTTP 403 does not trigger refresh-token rotation.

### Claude renewal and recovery

- Claude uses `https://platform.claude.com/v1/oauth/token` for renewal.
- Before usage or a 401 retry, newer live CLI credentials are copied into the
  snapshot only when an access or refresh token proves continuity. Missing or
  unreadable snapshots never fall back to an unrelated live account.
- Overlapping requests for one snapshot share a single operation. A proactive
  renewal is not followed by another exchange of the old refresh token on 401.
- Snapshot writes complete before renewed tokens are used. Keychain write failures
  remain visible even if a fallback file could be written. Saved rotations can
  repair a matching older live credential on a later refresh without rotating again.
- Provider metadata outside the owned OAuth fields is preserved during writes.
- English and Chinese distinguish renewal rejection, transient HTTP/network errors,
  malformed responses, persistence failures and credentials changed during renewal.
- If both tokens were replaced independently with no provable continuity, the app
  keeps the account snapshots separate. Import Current Login establishes the current
  credential; a revoked refresh token may require signing in again once. The app
  cannot restore tokens revoked by the provider or guarantee persistence when macOS
  denies access to its credential storage.

### Claude Keychain recovery

Claude's `Claude Code-credentials` item is shared with the installed CLI. Both
its trusted-application ACL and partition ACL must permit `/usr/bin/security`.
On the affected macOS version, native secret updates (including `SecItemUpdate`)
replace the partition with the writer's identity even when the trusted-app list
survives. This is why clicking Always Allow can add the system reader to the
trusted-app list while repeated password prompts continue.

The app now uses the CLI's Apple-signed system tool for reads and writes. A
short-lived metadata-only helper avoids stale legacy Keychain references and
checks that the unique item is unlocked and already authorizes the system
reader. It exits before account discovery, runtime persistence or networking.
Blocked items are not passed to the reader. Commands have a five-second deadline;
a failed access state is not retried until permission metadata changes or the app
restarts. Credential bytes use pipes, never command-line arguments or logs.
Every write is verified by reading back the exact bytes. An external lock or ACL
change between preflight and execution can still fail the command.

Existing affected items require a one-time repair. Inspect only the exact Claude
service/account in its actual Keychain, retain its current partition identifiers,
and append `apple-tool:` with `security set-generic-password-partition-list`.
Use exact `-s`, `-a` and Keychain-path selectors. Omit `-k`: enter the login
Keychain password only in the tool's terminal prompt. Retain the existing
trusted-app list, including `/usr/bin/security`; do not enable all applications,
delete/recreate the credential, or apply a blanket partition change to a whole
Keychain. The fix does not require reading or exporting the OAuth credential.

The app deliberately does not create a missing third-party Keychain item. Run
Claude's browser login once to initialize it. Denied or missing Keychain writes
fail activation without changing the fallback file or active marker. Reopen the
app after repairing permissions if a previous command failure was latched.

Optional system integration check (the login Keychain must already be unlocked):

```bash
swiftc Sources/AISwitcher/Services/ClaudeKeychainStore.swift \
  scripts/verify-claude-keychain.swift -o /tmp/aiswitcher-verify-keychain
/tmp/aiswitcher-verify-keychain
```

This opt-in check creates and removes one uniquely named **synthetic** item in
the default Keychain, without reading existing credentials. It verifies system
reader access, production writes/readback, preserved partitions, service names
with spaces, missing-item refusal and preflight rejection of the original broken
ACL. Regular `swift test` uses synthetic files and injected credential operations.
