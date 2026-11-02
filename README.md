# AI Switcher

A native macOS menu bar app that switches between multiple AI accounts and shows
their usage limits — a clone of "Codex Switcher", extended to support **Claude**
in addition to **Codex/OpenAI**, with **English + 简体中文** localization.

<p align="center">
  <img src="docs/images/menu-preview.png" alt="AI Switcher menu bar dropdown showing Codex and Claude accounts with usage bars" width="420">
</p>

## Features

- **Compact menu bar dropdown** inspired by the reference: native translucent panel, branded
  OpenAI/Codex and Anthropic/Claude sections with official compact provider artwork, per-account
  cards with a ✓ for the active account, segmented 5h / 7d remaining-quota bars (red below 10%,
  yellow from 10% through 50%, and green above 50%),
  percentages, reset dates, refresh status, verified reset-credit availability,
  confirmed reset redemption, accumulated runtime, and a hover-opened account submenu
  for one-click switching.
- **Multi-account switching** — activating an account swaps the underlying CLI
  credential so the `codex` (or `claude`) CLI uses that login. Active state is
  tracked independently for each provider.
- **Working account management** — Add Account can run the installed provider
  CLI's browser OAuth flow and automatically import the resulting credential,
  import an existing current login, or validate a credential JSON file. Account
  Settings supports custom names, activation, refresh, language selection, and
  confirmed removal of inactive account snapshots.
- **Transactional Codex OAuth** — browser sign-in uses an isolated temporary
  `CODEX_HOME`, so closing or cancelling the browser cannot log out the currently
  selected account. A new credential is activated only after successful validation.
- **Live usage** fetched from the provider APIs:
  - Codex: `GET https://chatgpt.com/backend-api/wham/usage`
  - Codex reset credits: `GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits`
  - Codex reset redemption: `POST https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume`
  - Claude: `GET https://api.anthropic.com/api/oauth/usage`
- **OAuth refresh** for expired Codex and Claude access tokens, including
  rotated-token persistence to the managed account snapshot. Claude uses the current
  OAuth endpoint, checks related live CLI credentials before renewal, coalesces
  overlapping requests, and reports refresh/storage errors separately.
- **Auto-refresh** every 5 minutes, plus a manual "Refresh Now".
- **Persistent runtime** — accumulated running time is saved to local SQLite every
  minute and on normal exit. Restarting continues the total; time while the app is
  closed is excluded. Preview rendering never changes the runtime database.
- **Launch at Login** via `SMAppService`.
- **Localization**: follows the system language, or force English / 简体中文 in
  Account Settings. Switches instantly, no relaunch.

## Provider details

| | Codex (OpenAI) | Claude (Anthropic) |
|---|---|---|
| Credential | `~/.codex/auth.json` | macOS Keychain `Claude Code-credentials` (file fallback `~/.claude/.credentials.json`) |
| Account identity | JWT claim `chatgpt_account_id` | `oauthAccount.accountUuid` in `~/.claude.json` (read-only) |
| Plan tier | JWT claim `chatgpt_plan_type` | `claudeAiOauth.subscriptionType` |
| Usage endpoint | `/backend-api/wham/usage` | `/api/oauth/usage` |
| 5h / 7d source | `rate_limit.primary_window` / `secondary_window`, classified by `limit_window_seconds` (18000 / 604800) | `five_hour.utilization` / `seven_day.utilization` |
| Token refresh | `auth.openai.com/oauth/token` | `platform.claude.com/v1/oauth/token` |

Claude's credential contains no account identifier and rotates both of its tokens
on every refresh, so identity is read from the account block Claude Code keeps in
`~/.claude.json`. The app never writes that file. Without it, accounts fall back to
a credential digest and a rotation performed by the CLI can look like a new login.

Account switching means snapshotting each account's credential into
`~/Library/Application Support/AISwitcher/{codex,claude}-accounts/` and writing the
chosen snapshot back to the live location. The credential that is live at that
moment is snapshotted first, so a rotation the CLI performed in the meantime is not
lost with the slot. Credential files are written atomically with owner-only (`0600`)
permissions.

Codex CLI 0.159.0 can attach new terminals to an already-running shared server
whose cached login differs from that file. For account switching with local zsh
terminals, use the optional [Codex shell integration](docs/CODEX_TERMINALS.md),
which launches interactive sessions with `--no-daemon`. Existing sessions still
need a separate, idle-only restart; the switcher does not hot-swap running sessions.
For the 0.159.0 `/status` email-display regression, see the optional
[version-specific client repair](docs/CODEX_STATUS_EMAIL.md).
The same private client can provide [rounded input styling and AI request
suggestions](docs/CODEX_INPUT.md), with explicit Tab acceptance and an opt-out.

Codex 401 recovery first reloads the matching live CLI credential, then performs at
most one OAuth exchange and one request retry. Usage and reset actions share token
renewal, and rotated credentials are saved before use. A rejected refresh token is
not exchanged again in the running app until that token changes. This follows the
[official credential lifecycle](https://learn.chatgpt.com/docs/auth#login-caching),
where Codex can update its cached tokens while it runs.

**You do not need to delete an account to repair its login.** Try Refresh Now first.
If the CLI already has a valid login, choose Add Account → Codex → Import Current
Login. If authorization has been revoked or expired, choose Sign In with Browser
and sign in to the same account. The existing row, custom name, and last-known usage
are retained. A rejected refresh token cannot be repaired without a valid replacement
or user authorization. These recovery paths currently use `~/.codex/auth.json`;
OS-keyring-only and custom `CODEX_HOME` credentials are outside this store's support.

Claude token renewal saves the new credential before retrying usage and never
reuses a refresh token that it already exchanged in the same request. Newer live
credentials are adopted only when token continuity proves they belong to the saved
account. If both tokens were independently replaced and ownership cannot be verified,
use Import Current Login; the app does not guess from the active checkmark or label.
A revoked refresh token still requires a valid current login or a new sign-in.

Unknown provider values stay unknown. In particular, a failed reset-credit
request is shown as unavailable rather than as a real zero.

In the compact menu, only account titles switch accounts. Usage bars and dates
are read-only. A positive reset-credit line is a full-width action with a strong,
non-bypassable confirmation alert and explicit cancel action. Only the destructive
confirmation consumes a credit; the idempotent result is followed by a usage refresh.

Hovering Account Settings opens a compact list of managed logins. The current
provider account is checkmarked, account rows switch immediately, and Manage
Accounts opens the full rename/remove/settings window.

## Build & run

```bash
./build-app.sh release        # builds .build/release/AI Switcher.app
open ".build/release/AI Switcher.app"
```

`swift build` alone produces a bare binary; `build-app.sh` assembles the proper
`.app` bundle (with `LSUIElement` so it's a menu-bar agent with no Dock icon) and
copies localized strings and menu artwork into the standard
`Contents/Resources` directory.

### UI preview without clicking the menu bar

```bash
AISWITCHER_RENDER=/tmp/en.png AISWITCHER_LANG=en       .build/release/AISwitcher
AISWITCHER_RENDER=/tmp/zh.png AISWITCHER_LANG=zh-Hans  .build/release/AISwitcher
AISWITCHER_RENDER=/tmp/auth.png AISWITCHER_SCENARIO=codex-auth-error AISWITCHER_LANG=zh-Hans .build/release/AISwitcher
AISWITCHER_RENDER=/tmp/real.png AISWITCHER_REAL=1      .build/release/AISwitcher   # real persisted data
AISWITCHER_RENDER=/tmp/switcher.png AISWITCHER_SURFACE=account-switcher .build/release/AISwitcher
```

## Runtime storage

The menu's accumulated runtime is stored in
`~/Library/Application Support/AISwitcher/runtime.sqlite`. The database contains
only an integer duration in milliseconds; accounts and tokens stay in their existing
stores. Older versions did not save runtime history, so the first run of this
version starts a new total. Subsequent launches continue it automatically.

See [docs/DATABASE.md](docs/DATABASE.md) for schema migration and backup/rollback details.

## Notes / limitations

- Claude Keychain reads and writes use the same `/usr/bin/security` identity as
  Claude Code. Permission metadata is checked without interaction before invoking
  it; locked or incompatible items are unavailable rather than repeatedly
  prompting. When several items share the service (newer Claude Code versions can
  leave an MCP-only item beside the login), the app uses the first one holding a
  `claudeAiOauth` login, preferring the current macOS user's account, then the
  most recently modified item. Native secret updates must not be used: they can replace the partition
  ACL with the ad-hoc app's code hash. Credential bytes travel through pipes, never
  command arguments or logs, and writes are verified by reading back the result.
- Older builds may have left a Claude item bound to AI Switcher's code hash. That
  item needs a one-time, password-authorized partition repair; see
  [Claude Keychain recovery](docs/FUNCTIONAL.md#claude-keychain-recovery).
- A missing Claude Keychain item must first be initialized by Claude's own login
  flow. A fallback file alone is not reported as a successful macOS account switch.
- Provider usage endpoints are undocumented backend APIs and may change. The app
  preserves the last successful snapshot and surfaces a per-account error when a
  refresh fails.
- Purchase actions are intentionally hidden until a real StoreKit product and
  restore flow are configured.
- OpenAI and Anthropic/Claude names and provider artwork remain the property of
  their respective owners. They are shown only to identify supported services and
  do not imply endorsement, sponsorship, or partnership.

## Project layout

```
Sources/AISwitcher/
  Models/Account.swift          # Provider, PlanTier, UsageWindow, Usage, Account
  Services/
    CodexCredentialStore.swift  # ~/.codex/auth.json read/snapshot/swap + JWT
    ClaudeCredentialStore.swift # credential snapshots and synchronization
    ClaudeProfileStore.swift    # stable Claude account identity from ~/.claude.json
    ClaudeKeychainStore.swift   # permission preflight and bounded system-tool I/O
    UsageService.swift          # /wham/usage + /api/oauth/usage
    TokenRefresher.swift        # typed Codex OAuth exchange and safe errors
    CodexAuthCoordinator.swift  # shared renewal and bounded 401 recovery
    ClaudeOAuthService.swift    # Claude OAuth exchange, errors and request coalescing
    SecureFileWriter.swift      # atomic owner-only credential writes
    AccountsManager.swift       # discovery, import, rename/remove, switching, refresh
    AppRuntime.swift            # runtime lifecycle and periodic checkpoints
    RuntimeTracker.swift        # saved total + monotonic unsaved interval
    RuntimeStore.swift          # one-row SQLite runtime repository
    RuntimeStore+Migrations.swift # versioned SQLite schema migration
    LocalizationManager.swift   # en / zh-Hans, live switching
    LaunchAtLogin.swift         # SMAppService wrapper
    JWT.swift
  Views/
    MenuContentView.swift       # the dropdown and stable provider grouping
    ProviderBrandView.swift     # official artwork loading + provider accents
    ProviderSectionView.swift   # branded OpenAI / Anthropic menu sections
    AccountCardView.swift  UsageRow.swift  MenuActionRow.swift
    AddAccountView.swift  SettingsView.swift  VisualEffectBlur.swift
  Resources/{en,zh-Hans}.lproj/Localizable.strings
Tests/AISwitcherTests/          # provider payload and model tests
docs/FUNCTIONAL.md              # behavior and UI states
docs/API.md                     # provider endpoint contracts
docs/DATABASE.md                # local SQLite schema, lifecycle and rollback
```

See [CHANGELOG.md](CHANGELOG.md) for implementation changes and
[AGENTS.md](AGENTS.md) for project-specific development rules.
