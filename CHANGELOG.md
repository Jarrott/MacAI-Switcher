# Changelog

## Unreleased

### Changed

- Give the optional Codex client a rounded four-sided input border, terminal-matched
  background and balanced padding. Preserve editing behavior and keep AI hints
  clear of the border corners.
- Add opt-out AI draft suggestions through the connected Codex backend, with
  debouncing, cancellation, Tab acceptance and no automatic submission.
- Persist accumulated application runtime in local SQLite instead of resetting the
  menu timer on every launch. Save once per minute and during normal termination;
  application downtime is excluded, and preview rendering leaves saved runtime alone.
- Add a versioned one-row runtime schema, atomic delta updates, storage-failure retries,
  migration/backup guidance and regression tests for restart and crash recovery.
- Rename the menu header to "Total runtime" / "累计运行" in English and Chinese.
- Grouped menu accounts into branded OpenAI/Codex and Anthropic/Claude glass
  sections with official provider artwork, distinct low-opacity accents, compact
  plan badges, and matching icons across the switcher and account windows.
- Added one-click browser OAuth login through the installed Codex or Claude CLI,
  followed by automatic credential import and usage refresh.
- Limited account switching to the account title rows; usage metrics are now
  display-only, while positive reset-credit counts use their own full-width action.
- Added confirmed Codex reset-credit redemption with a neutral translucent hover row,
  irreversible-action warning, explicit Cancel Reset action, idempotent request,
  outcome-specific feedback, and post-result usage refresh.
- Replaced the blurry bitmap-style status item with a custom vector switching
  glyph and Retina-safe AppKit loading, retaining PNG and SF Symbol fallbacks.
- Replaced the Add Account placeholder and unreliable settings selector with
  dedicated SwiftUI windows.
- Added validated import of current Codex/Claude logins and credential JSON
  files, with duplicate reconciliation and usage refresh.
- Use Claude's authentication command (`claude auth login`) instead of opening a
  regular Claude chat session from the Add Account guide.
- Added account rename, activation, refresh, and confirmed removal controls;
  active account credentials are protected from deletion.
- Reworked the menu to a compact 320-point layout with native translucent
  material, reduced overlay opacity, day-first English reset dates, keyboard
  shortcuts, and explicit loading/empty/error states.
- Replaced continuous usage capsules with compact segmented meters and color each
  usage window by remaining quota: red below 10%, yellow through 50%, and green
  above 50%, independent of reset-credit availability.
- Removed non-functional purchase placeholders from the production menu.
- Track active accounts independently for Codex and Claude, including migration
  from the previous single-active-account persistence schema.
- Reconcile Claude accounts with a deterministic SHA-256-derived identifier instead of
  process-randomized Swift `hashValue`.
- Added an Account Settings hover submenu with active checkmarks, immediate
  account switching, and a retained entry to the full management window.
- Refined the shared glass material, cool contrast tint, border/shadow treatment,
  neutral translucent hover states, and typography across account and action rows.
- Increased main/submenu translucency by using a lighter native popover material
  and substantially reducing the dark tint and bottom gradient.
- Reduced the visual-effect layer itself to partial opacity, allowing backdrop
  contours—not only averaged colors—to remain visible through the menu.
- Clear the SwiftUI presentation window backing layer and use native menu
  material, preventing the glass from collapsing the backdrop into a flat
  brown/gray fill.

### Fixed

- Add a version-scoped Codex 0.159.0 client repair for `/status` losing its email
  after a plan-only account notification. Re-read identity from the same backend
  without refreshing tokens; never carry an old email across account changes.
- Route interactive launches to the optional repaired client only when upstream
  is exactly 0.159.0. Preserve utility commands and automatically bypass the
  repair after an upstream version change.
- Add optional zsh integration for Codex local interactive launches, resume and
  fork. Use `--no-daemon` to avoid reusing a shared server's cached old account;
  preserve utility commands, explicit remote connections and CLI exit statuses.
- Document existing-session limits, lock handling, missing empty-session history,
  account-identity verification and shell-integration installation/rollback.

- Prevent repeated Claude Keychain password prompts caused by native credential
  writes rebinding the partition ACL to AI Switcher's ad-hoc code hash. Use the
  same Apple-signed system reader/writer as Claude, preflight permissions in a
  fresh metadata-only process, bound operations, and verify writes by readback.
- Stop retrying an unchanged failed Keychain access state. Fail account activation
  when authoritative Keychain persistence fails instead of treating a fallback
  file write as a successful macOS switch. Leave initial item creation to the CLI.
- Document scoped repair for existing affected items and add synthetic regression
  coverage for activation failure and actual system-tool read/write compatibility.
- Fix Claude renewal using the current `platform.claude.com/v1/oauth/token` endpoint.
- Reconcile newer related Claude CLI credentials before usage/401 retries, coalesce
  overlapping refreshes, and avoid reusing an already-exchanged refresh token.
- Preserve unknown CLI credential metadata, surface snapshot/Keychain write errors,
  and retry failed live writes from the saved rotated credential. Missing snapshots
  no longer fall back to another Claude account's live login.
- Add localized Claude authentication failure categories and isolated regression
  coverage for expiry, retry limits, credential ownership and persistence recovery.
- Replace the reset confirmation's transient SwiftUI alert with a lifecycle-owned
  AppKit modal alert, so Cancel/Escape work reliably and no orphaned overlay
  survives after the menu closes.
- Ensure browser OAuth launched from the menu-bar app can resolve NVM/Homebrew
  runtimes, report actual CLI failures instead of labeling every exit as a user
  cancellation, and terminate the login subprocess when its window closes.
- Make browser OAuth transactional: snapshot the current provider credential
  before login and restore its credential plus active selection whenever the
  browser is closed or the new login does not complete.
- Isolate Codex browser OAuth in a private temporary `CODEX_HOME`; only a
  successfully validated staged credential is committed, so closing the browser
  can no longer clear or log out the currently selected account.
- Restore the active Codex marker before attempting Claude Keychain discovery,
  preventing a delayed Keychain read from leaving all accounts unchecked.
- Start account discovery from AppKit's launch-completion callback so existing
  live credentials reliably repair persisted active-account state after restart.
- Load packaged localization and menu artwork from standard app resources first,
  avoiding SwiftPM bundle enumeration that could hang menu-bar startup.
- Terminate registered browser-login wrappers and their provider CLI children on
  cancellation and app shutdown, preventing orphaned login processes.
- Clear Account Settings hover, delayed-dismissal, and accent-highlight state on
  native popover dismissal, menu closure, and application focus loss.
- Stop treating menu presentation as a refresh trigger; opening the status-item
  panel now displays cached state without issuing provider network requests.
- Reapply transparent window backing after SwiftUI's presentation lifecycle and
  let native menu material own the blur, fixing a compositor mismatch where the
  menu appeared black live but translucent only in screenshots.
- Set glass intensity through AppKit's native visual-effect alpha and reduce the
  remaining tint/gradient overlays, so the live menu preserves backdrop shapes
  instead of becoming an opaque black panel.
- Lower the native menu-material alpha to 30% for a visibly lighter glass panel.
- Reduce that material strength by a further 30%, from 30% to 21%, while keeping
  the existing tint and text-contrast treatment.
- Lower native material strength from 21% to 16% and reduce the remaining tint
  and gradient treatment by 20% for a clearer backdrop.
- Lower native material strength from 16% to 10% and reduce the remaining tint
  and gradient treatment by another 20%.
- Add a monotonic, minute-updating process runtime line to the menu header without
  coupling it to provider refreshes, and reduce menu typography weights for a
  lighter native appearance.
- Standardize all main-menu and account-submenu text plus indicator symbols on
  regular font weight; no usage, title, reset, or action row remains bold.
- Display remaining Codex/Claude quota (`100 - used`) instead of incorrectly
  presenting the provider's consumed percentage as available capacity.
- Prefer the email local-part for Codex account labels and repair existing saved
  labels, matching the reference switcher's account names.
- Fetch Codex manual reset credits from the dedicated backend endpoint.
- Preserve an unknown reset-credit count instead of reporting it as zero and
  incorrectly coloring the usage bar red.
- Fail closed on unknown reset-redemption responses and reuse the same UUID only
  for the single OAuth-refresh retry, preventing duplicate credit consumption.
- Clamp invalid provider percentages before display.
- Preserve and display per-account refresh failures instead of silently ignoring
  them.
- Refresh and persist expired Claude OAuth credentials.
- Import both Codex and Claude credentials from the Add Account flow.
- Restrict generated credential snapshots and fallbacks to owner-only file
  permissions.
- Reject persisted snapshot paths that escape the app-managed credential
  directories before reading, activating, overwriting, or deleting them.
- Derive Codex snapshot filenames from a SHA-256 digest so account identifiers
  cannot inject path components.

### Documentation and tests

- Added project-level development instructions, functional/API documentation,
  and parser tests for Codex and Claude usage payloads.
