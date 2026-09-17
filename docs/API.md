# Provider API reference

These endpoints are provider-owned, undocumented backend interfaces and may
change. Callers must handle non-2xx responses, decoding changes, and missing
fields without fabricating values.

## Codex / ChatGPT

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

Refresh uses the Codex OAuth client ID and persists rotated access, refresh, and
ID tokens to the managed snapshot. The live file is updated only when it belongs
to the same active account.

## Claude

### Usage windows

`GET https://api.anthropic.com/api/oauth/usage`

The `five_hour` and `seven_day` objects provide `utilization` on a 0...100 scale
and ISO-8601 `resets_at` timestamps.

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
items without spawning the credential reader. See
[recovery](FUNCTIONAL.md#claude-keychain-recovery). A snapshot-only
`aiSwitcherPreviousCredentialFingerprint` records the
SHA-256 digest of the preceding credential generation so a failed live write can
be repaired from the saved rotation on a later refresh. It is not an account ID.

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
