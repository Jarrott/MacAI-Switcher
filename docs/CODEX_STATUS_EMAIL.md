# Codex 0.159.0 status email repair

## Cause and scope

The 0.159.0 TUI still supports `Account: email (plan)`. On a routed ChatGPT
account, the server emits an initial `account/updated` notification containing
only `authMode` and `planType`. The full `account/read` response includes email,
but processing the queued notification replaces the TUI account display with
`email: None`. This reproduces with both `--no-daemon` and a private local server.

The repair is a small patch to Codex's account-notification handler. It reads
`account/read` on the **same backend connection**, with `refreshToken: false`
and a three-second timeout, then uses the returned account for `/status`.
Failures leave a plan-only fallback; no old email is reused. Logout clears the
display. No AI Switcher credential, auth token, permission, session history, or
account-selection logic is changed.

An existing process cannot load a replacement executable. Open a new terminal
and start Codex to load both the updated shell integration and display repair.
Account switching and session restart
remain separate operations; there is no automatic session synchronization.

## Local integration

The optional repaired executable is installed at:

```text
~/.config/aiswitcher/codex-status/bin/codex
```

Its matching `codex-code-mode-host` companion must be in the same directory.
`scripts/codex-shell.zsh` selects this executable for interactive launches,
resume/fork, and explicit remote interactive connections, only if the upstream
`codex --version` is exactly `codex-cli 0.159.0`. Utility commands (including
login, app-server, exec, help and version) continue to use upstream. An upstream
upgrade automatically bypasses this repair; it never pins the user to an older
CLI. The official npm installation is not overwritten.

In a new zsh terminal, run ordinary `codex`, then `/status`. For a ChatGPT
credential exposing an email, the Account row should contain the address and
plan. An API-key login or a backend that supplies no email cannot display one.
The launcher itself does not read credentials, print email, or rewrite terminal
output. It preserves the upstream sandbox and approval configuration.

To disable only the display repair, move the `codex-status` directory aside.
The shell function will fall back to upstream while keeping `--no-daemon` for
local interactive launches. See [terminal integration](CODEX_TERMINALS.md) to
remove the whole integration.

## Source and reproducibility

The source patch is [codex-0.159.0-status-email.patch](../patches/codex-0.159.0-status-email.patch).
It applies to the upstream `openai/codex` tag `rust-v0.159.0`. Upstream is Apache-2.0
licensed. No upstream source archive, credentials, or compiled binary belongs in
this Git repository.

The inspected source tarball from
`https://codeload.github.com/openai/codex/tar.gz/refs/tags/rust-v0.159.0` has SHA-256:

```text
d5fe92c6522bdd3d1f4bb8e74470e6226e80cd5991101c92f587f4a23be8e1ff
```

Apply the patch with `patch -p1` from that extracted source root. Use its pinned
Rust 1.95.0 toolchain. The release tag's Cargo manifests have version 0.159.0,
while its lockfile still has 0.0.0 for 158 local workspace packages. Cargo must
normalize those local versions before a locked build. Verify that **only those
local version fields** change: external package versions, checksums, sources and
dependency lists must stay unchanged. Do not update third-party dependencies.

From `codex-rs`, build the release binary without debug symbols:

```zsh
CARGO_BUILD_JOBS=4 CARGO_INCREMENTAL=0 \
CARGO_PROFILE_RELEASE_DEBUG=0 CARGO_PROFILE_RELEASE_STRIP=symbols \
cargo +1.95.0 build --locked --release -p codex-cli --bin codex
```

Run the TUI tests through upstream's `just test -p codex-tui`, including
`account_email_tests`. The regression uses a local mock app-server with synthetic
account responses to cover successive emails, account-read failure, missing email,
and logout. Validate the actual native `/status` output against the connected
backend before installing. Keep the matching official `codex-code-mode-host`
companion available; this patch does not modify it.

The launcher has its own isolated tests:

```zsh
zsh -n scripts/codex-shell.zsh
python3 scripts/test-codex-shell.py
```

These exercise argument quoting, exit codes, utility passthrough, explicit server
options, repair selection, and automatic fallback after an upstream upgrade.

### Validation limits

The optimized release build succeeds. Its native `/status` shows the credential's
email after session initialization, without changing the credential file. After
installation, a fresh Orca terminal launched ordinary `codex` and showed the same
email and plan in the Account row. The temporary verification terminal was closed;
existing terminals were left running. The release and official executable report
identical feature configuration.

The shell integration passes 45 argument/version cases. The email regression and
two existing account-state tests pass; restoring the unmodified upstream handler
makes the email regression fail. The source patch is also checked by applying it
to pristine release files and comparing the result byte-for-byte.

The complete upstream TUI suite is **not green** on this release checkout:
5,550 tests ran, with 5,442 passing, 107 failures, one timeout, and four skips.
Three sampled failures (two status cases and an Analytics account-plan case)
also reproduce with the unmodified handler. The full suite has not been made
green as part of this display repair. Its initial new-test fixture was replaced
by the isolated app-server fixture described above, which now passes.

Changed Rust files pass scoped `rustfmt` checks. Upstream's repository-wide
`just fmt` cannot run directly from the source archive because its Bazel formatter
requires Git metadata; no claim is made that that aggregate command passed.
