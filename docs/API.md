# Provider API reference

These endpoints are provider-owned, undocumented backend interfaces and may
change. Callers must handle non-2xx responses, decoding changes, and missing
fields without fabricating values.

## Local Codex status display

The optional [Codex 0.159.0 display repair](CODEX_STATUS_EMAIL.md) uses the existing
app-server JSON-RPC method `account/read` on the current session's connection.
`refreshToken` is false (the protocol may omit this default). The response's
`account` is nullable; a ChatGPT account exposes `type: "chatgpt"`, nullable
`email`, and `planType`. API-key and Amazon Bedrock accounts have no ChatGPT email.

An `account/updated` notification triggers a bounded three-second read. A missing
email remains unknown; errors/timeouts use the notification's plan-only fallback.
No previous email or AI Switcher selection is used as a substitute. The repair
does not change the upstream API, initiate login, or explicitly refresh tokens.

## Codex / ChatGPT

### Local input suggestions

The optional [input extension](CODEX_INPUT.md) reuses `config/read`, `thread/start`,
`turn/start`, `turn/interrupt` and `thread/unsubscribe` through the connected
app-server. It adds no backend endpoints or response fields. The temporary thread
has `ephemeral: true` and a `prompt_suggestion` feature source; model output follows
the JSON schema `{ "suffix": string }`. Client validation limits the suffix to
120 characters and rejects terminal controls or multiline output. The shared helper
bounds startup/turn execution to 30 seconds and detaches completed/cancelled threads.

### Usage windows

`GET https://chatgpt.com/backend-api/wham/usage`

Headers include bearer authorization, `chatgpt-account-id`, browser-style
request headers, Origin, and Referer. `rate_limit.primary_window` and
`secondary_window` are classified by `limit_window_seconds`:

- `18000`: 5-hour session
- `604800`: 7-day window

`used_percent` is stored as a consumed 0...1 fraction. The menu displays the
remaining value (`1 - usedFraction`) and uses the same remainder for bar width.

### Manual reset credits

`GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits`

Additional headers:

- `openai-beta: codex-1`
- `originator: Codex Desktop`

`available_count` is displayed only when the request succeeds. Missing or failed
responses remain unknown and are never shown as zero.

When present, `credits` rows with `status == "available"` are filtered to exclude
expired entries and sorted by nearest `expires_at`; their `id`, optional `title`,
and expiry are retained so redemption can prefer the earliest-expiring credit.
Redeemed rows are never presented as available.

### Consume one manual reset credit

`POST https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume`

The request uses the same bearer/account headers plus JSON content type and a
body containing a unique `redeem_request_id` UUID. When the credit listing
provided an identifier, the body also sends `credit_id`. The UUID is reused for
the single 401 token-refresh retry and is never reused for a separate user action.

Recognized result codes are `reset`, `already_redeemed`, `nothing_to_reset`,
`no_credit`, and `reset_wrong_provider`. Unknown 2xx bodies fail closed instead
of being treated as success. After every recognized result the app fetches and
persists fresh usage best-effort; a refresh failure retains last-known-good data.
The UI calls this mutation only after a separate destructive confirmation alert
with an explicit Cancel Reset action.

### Token refresh

`POST https://auth.openai.com/oauth/token`

Refresh uses the existing Codex OAuth client ID and a typed JSON request with
`grant_type`, `refresh_token`, `client_id` and `scope`. The response requires a
nonempty `access_token`; omitted `refresh_token`/`id_token` preserve their prior
values and explicitly empty values fail validation. Identity changes fail closed.
HTTP 401, `invalid_grant`, `refresh_token_reused`, `refresh_token_expired` and
`refresh_token_invalidated` become safe login-required errors; provider response
bodies are never shown or logged. Other HTTP, transport and persistence failures
remain distinguishable. Client-facing service error descriptions are English;
the application resolves UI messages through English/Chinese localization.

`CodexAuthCoordinator` is shared by usage and reset redemption. It reconciles
same-account live credentials before requests and after 401, coalesces concurrent
exchanges, and permits one exchange plus one 401 retry per operation. A rejected
refresh token is not replayed in this process until it changes; manual refresh does
not bypass this protection. 403/429 do not cause token exchange. Reset retries keep
the original JSON body and `redeem_request_id`.

`CodexCredentialStore` checks the saved generation before persisting rotated access,
refresh and ID tokens, preserving unknown provider JSON fields. Atomic writes use
0600 permissions. The live file is backed up and updated only if it still holds the
exchanged generation. A snapshot-only `aiSwitcherPreviousCredentialFingerprint`
(SHA-256 of the preceding token bundle) allows a failed live write to be repaired
on the next read or discovery instead of adopting retired tokens. If even the snapshot
write fails, the coordinator retains the exchanged generation in memory and retries
its persistence without another exchange. Restarting before storage recovers loses
that in-memory generation and may require reauthorization. This marker is stripped from
live writes and activation. The file checks detect observed conflicts but cannot
provide a transaction with independently writing CLI processes.

No provider endpoint or public response schema changes. Regression tests inject
HTTP transport and private temporary paths for 401 recovery, token rejection,
concurrent renewal, persistence failure, account isolation, reset idempotency and
same-account reauthorization without deletion.

## Claude

### Usage windows

`GET https://api.anthropic.com/api/oauth/usage`

The `five_hour` and `seven_day` objects provide `utilization` on a 0...100 scale
and ISO-8601 `resets_at` timestamps.

### Account identity

Claude's credential blob exposes no account identifier, and `/v1/oauth/token`
rotates both tokens on every refresh, so no field in it is stable across a
refresh. Account identity is read locally from `oauthAccount` in `~/.claude.json`,
which Claude Code maintains: `accountUuid`, `emailAddress`, `displayName` and
`organizationUuid`. The file is read-only to this app and parsed only after its
size or modification date changes.

The record describes whichever login Claude Code last wrote, so it is trusted only
when no managed snapshot already owns the live credential. Resolved identity is
persisted in the owner-only snapshot as `aiSwitcherAccountIdentity` and removed
from every live write, keeping the provider blob byte-shaped as the CLI wrote it.

### Token refresh

`POST https://platform.claude.com/v1/oauth/token`

Request JSON contains `grant_type: "refresh_token"`, `refresh_token`, and the
Claude Code OAuth `client_id` (`9d1c250a-e61b-44d9-88ed-5944d1962f5e`). The URL
matches the installed official Claude Code binary; Anthropic's
[2.1.7 changelog](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md)
records the migration from `console.anthropic.com` to `platform.claude.com`.
The old `/api/oauth/token` path must not be used.

The response requires a nonempty `access_token`. Optional `refresh_token` replaces
the old refresh token; an omitted value preserves it. Positive `expires_in` seconds
are converted to Unix milliseconds, with `expires_at` (seconds or milliseconds) as
fallback. Omitted expiry becomes unknown. Optional space-separated `scope` updates
stored scopes. Invalid/empty tokens and malformed expiry fields fail validation.

One usage operation exchanges a token at most once and retries usage at most once
after 401. It re-reads related live credentials before exchanging tokens. A 403/429
usage response does not itself trigger renewal. Concurrent operations for the same
managed snapshot share one task.

Rotated tokens are atomically saved before requesting usage. Unmodeled provider JSON
fields are preserved. The saved base generation is checked before replacement;
Keychain and an existing file fallback are updated only when they still match that
generation. Keychain writes use `security -i` with hex-encoded bytes on stdin and
verified readback; direct native secret updates are prohibited because they rebind
the partition ACL to the app. Metadata-only preflight rejects locked or incompatible
items without spawning the credential reader. With several same-service items, reads
and writes target the first accessible one containing a non-empty `claudeAiOauth`
access token, ordered by current-user account and then newest modification date. See
[recovery](FUNCTIONAL.md#claude-keychain-recovery). A snapshot-only
`aiSwitcherPreviousCredentialFingerprint` records the
SHA-256 digest of the preceding credential generation so a failed live write can
be repaired from the saved rotation on a later refresh. It is not an account ID.

A live credential that no longer shares tokens with its snapshot is adopted into
that snapshot when the recorded account matches, instead of exchanging the snapshot's
superseded refresh token. Rotation-based providers treat a replayed refresh token as
reuse and may revoke the token family it belongs to, so a credential the provider
rejected is not presented again until it changes.

OAuth `invalid_grant` and 401 return an actionable login error. Other refresh HTTP
statuses, invalid responses, network failures, storage failures and observed
credential conflicts have separate localized errors. Provider response bodies and
credentials are never displayed or logged. A failed refresh retains prior usage.

Regression tests inject synthetic HTTP responses and isolated credential directories;
no live account, Keychain item or provider request is used by the tests.

## Local runtime persistence

Runtime does not call a provider or expose a new HTTP endpoint. `AppRuntime` reads
an in-memory duration for the menu; `RuntimeTracker` computes unsaved monotonic time;
`RuntimeStore` persists integer milliseconds in local SQLite. See
[DATABASE.md](DATABASE.md) for the internal data contract, migration and rollback.
