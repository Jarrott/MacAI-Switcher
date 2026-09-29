# Codex terminal account switching

## Credential selection and running processes

AI Switcher writes the selected Codex snapshot to `~/.codex/auth.json`. Codex CLI
0.159.0 can attach a new terminal to its existing local background server. That
server may retain another account in memory, so opening another terminal alone
does not guarantee that the selected credential is loaded.

The official CLI option `--no-daemon` starts a local interactive instance without
attaching to that shared server. Disabling `features.daemon_auto_start` alone is
insufficient while a server already exists (verified with CLI 0.159.0).

The optional `scripts/codex-shell.zsh` function applies `--no-daemon` to local
interactive starts, `resume`, and `fork`. Utility commands and explicitly remote
connections pass through. Arguments are forwarded as separate words without
`eval`; credentials are neither read nor printed by the function. It retains all
upstream approval/sandbox settings, forwards the executable's exit status and
does not terminate existing processes. No new runtime dependency is required.

This integration applies to interactive zsh shells that source it, including Orca
shell terminals. Absolute executable paths, `command codex`, other shells and
launchers that bypass `.zshrc` bypass the function. A custom `CODEX_HOME`, keyring
storage, or explicit remote server can use a different credential store from the
one managed by AI Switcher.

## Installation and rollback

First verify that `codex --help` lists `--no-daemon`. From the repository root:

```zsh
mkdir -p ~/.config/aiswitcher
cp scripts/codex-shell.zsh ~/.config/aiswitcher/codex-shell.zsh
```

Back up `.zshrc` with owner-only permissions before editing. Add this once at the
end of `.zshrc`, after any existing aliases/functions have been reviewed:

```zsh
# AI Switcher: read the selected account on each local Codex launch.
source ~/.config/aiswitcher/codex-shell.zsh
```

Open a new shell, or source just the integration in an existing shell:

```zsh
source ~/.config/aiswitcher/codex-shell.zsh
whence -w codex  # should report a function
codex
```

To roll back, remove those two `.zshrc` lines, run `unfunction codex` in existing
shells, and optionally remove the installed integration file. A fresh shell then
uses the upstream executable unchanged. Shell changes cannot update already
running Codex processes.

## Existing sessions

Only stop a session after confirming it is idle and recording its exact session
ID. Exit using `/quit`, then run `codex resume --no-daemon <session-id>`. A shared
server may retain a lock after the terminal disconnects: wait for the session to
unload before retrying. Do not fork as an automatic substitute, delete locks,
archive unrelated threads or restart a shared server while work is active.

An empty session can disappear without a saved transcript; `resume` can then
report that no saved session exists. Confirm there was no history before starting
a replacement blank session. Never use `--last` when preserving a particular
conversation, because another session may have become the most recent.

## Verify identity, not only quota

Unpatched CLI 0.159.0 can lose the email in `/status`: its initial
`account/updated` notification contains only the auth mode and plan, and the TUI
processes that notification after loading the full account. The renderer still
supports email, but its cached email has been replaced with `None`. This is a
display regression, not evidence that the credential has no email. A quota
percentage or plan label cannot identify an account.

The optional [0.159.0 display repair](CODEX_STATUS_EMAIL.md) reads `account/read`
from the same session backend after account notifications. When installed beside
the shell integration, it restores the native `/status` email row. It neither
switches accounts nor reads AI Switcher's selected-account label. The launcher
uses the repair only while the upstream CLI version is exactly 0.159.0; after an
upstream upgrade, it falls back to that upstream executable automatically.

The official [app-server account/read API](https://learn.chatgpt.com/docs/app-server)
can return the account email and plan. For diagnosis, compare these with the
selected credential in memory and report only whether they match. An absent
email means identity cannot be verified by email. Querying a fresh app-server
process checks a fresh login load; querying the existing server checks its cached
login. These are separate checks. Do not print tokens, put them in command
arguments, or commit credential/configuration files.

## Validation

```zsh
zsh -n scripts/codex-shell.zsh
python3 scripts/test-codex-shell.py
```

The regression test uses a temporary synthetic CLI to verify local invocation,
resume/fork, root options, explicit remote overrides, utility commands, quoting
and exit-status propagation. It does not read real credentials or call a provider.
For local installation verification, open a fresh login shell, confirm `codex`
resolves to the function, then inspect a new no-task session with `/status` and
exit it. With this integration, ordinary local launches should no longer show
`Server: Local background server`.
