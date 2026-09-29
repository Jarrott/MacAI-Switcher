# Codex input refinement and AI suggestions

This optional local extension targets the same private Codex 0.159.0 client as the
[email-display repair](CODEX_STATUS_EMAIL.md). It preserves the prompt
arrow, keyboard editor, transcript, and account behavior while framing the input.

## Appearance

- Draw a thin rounded border on all four sides using the existing terminal widgets.
- Keep the terminal's background inside the input instead of painting a gray slab.
- Use the theme accent for the focused, enabled editor and a secondary tone otherwise.
- Reserve the existing top/bottom padding for the border; keep one blank column inside
  each side, followed by the normal prompt and editable text.
- Measure wrapping with the same inset as rendering and cursor placement. Remote
  images and the voice strip stay inside the frame; clipped layouts saturate safely.
- Draw the frame after decorative animations so its edges remain intact. AI hints
  appear in a padded break in the bottom rule, clear of the rounded corners.
- Preserve the transcript, status rows, keyboard controls and model-request behavior.

## AI input suggestions

The user explicitly enabled model-generated completions. After a 1.2-second typing
pause, a short plain-text draft can request an AI continuation through its existing
Codex backend. Requests are spaced at least six seconds apart. This uses model quota.

Only the current draft is supplied as completion content; the feature does not attach
conversation history, attachments, or read project files. Normal backend configuration
and instructions still apply. A supported Luna model from the account's model catalog
is preferred; otherwise the selected model/provider is retained.

- A small `AI…` indicator shows a pending request.
- The result appears as muted italic ghost text after the real cursor.
- **Tab** accepts the continuation into the editable draft; it does not submit it.
- **Esc** dismisses the current suggestion. **Enter** submits only actual input.
- Editing invalidates old results. Focus loss, a running task, popups, protected inputs,
  and thread changes cancel or suppress suggestions.
- Slash/shell commands, attachments, multiline or large drafts, and Vim input are
  excluded. Existing Tab queuing and command/file completion keep their behavior.
- A draft needs at least three characters after trimming outer whitespace and must
  fit within 1,024 UTF-8 bytes; place the cursor at the end to request a continuation.
- Generation is cancelled after 15 seconds, then the shared helper performs bounded cleanup.
- Errors or an empty model result leave ordinary editing available. No fabricated
  fallback suggestion is shown.

The completion runs in an ephemeral thread through the existing structured-request
helper. Built-in tools, MCP, plugins, skills and environment access are disabled by
that helper. The result is bounded to 120 characters and rejects control characters
and line breaks. Suggestions never become input unless accepted.

## Enable, disable and update

The version-scoped shell integration enables this feature only for the private client.
Open a new Orca terminal after installation, then start ordinary `codex`.
The installed private bundle includes all three repairs. Before replacement, its
previous executable, shell integration and build metadata are backed up together
under `~/.config/aiswitcher/backups/codex-input-<timestamp>/`.

Disable AI suggestions for one launch while keeping the visual/email repairs:

```zsh
AISWITCHER_CODEX_AI_SUGGESTIONS=0 codex
```

An upstream version change bypasses the private client as documented in the email
repair. The npm installation is not replaced. Existing running clients are not restarted.

## Verification

The source changes are retained as [appearance](../patches/codex-0.159.0-input-appearance.patch)
and [AI suggestions](../patches/codex-0.159.0-ai-suggestions.patch) patches. Apply
them in that order after the email repair, then apply the
[rounded-frame refinement](../patches/codex-0.159.0-rounded-input-frame.patch),
using the same pinned source and toolchain.
The combined patch sequence is checked against pristine release files.

Use the same upstream release profile as the verified email repair, including its
default thin link-time optimization. A single build job limits memory and disk peaks:

```zsh
CARGO_BUILD_JOBS=1 CARGO_INCREMENTAL=0 \
CARGO_PROFILE_RELEASE_DEBUG=0 CARGO_PROFILE_RELEASE_STRIP=symbols \
cargo +1.95.0 build --locked --release -p codex-cli --bin codex
```

### Initial appearance and suggestion validation

The initial strict release-profile regression run executed 396 selected tests: 395 passed,
including theme/wrapping snapshots, Chinese ghost text, accept/dismiss and submission
behavior, debounce/cancellation, the isolated app-server protocol test, and account
email regressions. One unchanged upstream reconnect test expects `/rollout`, which
the upstream command list disables without debug assertions; this release-only
mismatch remains a recorded failure. No snapshot force-pass flag was used in this run.

The zsh integration passes syntax validation and 46 invocation scenarios across two
test methods, including disabling suggestions and preserving official utility commands.

Scoped `just fix -p codex-tui --allow-no-vcs --profile release` completed successfully
after resolving two completion-specific lints; existing dependency warnings remain.
The archive lacks Git metadata required by `just fmt`, so modified Rust files were
formatted directly with the pinned Rust 1.95.0 formatter instead.

A live model check with the candidate TUI connected to the verified local backend
completed the Chinese draft `帮我给这个函数补充` with `注释`. Tab accepted it into the
editable input without submitting, and `/status` retained the matching email.
The initial candidate stalled during backend `thread/start`, even with suggestions
off. A native process sample located the wait in macOS Keychain password access
(`SecKeychainFindGenericPassword`), while the already-installed client could start.
This is a credential-access authorization issue, not evidence of an AI suggestion
or LTO regression. The final artifact retains the original release profile; a newly
built client may need system Keychain authorization before native startup can finish.

The final release artifact passed signature, version and upstream feature-list checks
and was installed into the existing private bundle. An ordinary `codex` launch in
a fresh Orca terminal reached a real session, displayed the account email in
`/status`, and generated a Chinese continuation with the Tab/Esc hint. Native startup
completed without requiring an additional authorization step during that check.
A separate native terminal check of that installed executable observed the pending
indicator and real model suffix, accepted it with an actual Tab key without submission,
and confirmed that the final `/status` email still matched the active credential.
Only identity equality was reported; credential contents were not logged.

### Rounded-frame validation

The follow-up frame change removes the solid input fill and reserves existing padding
for a rounded outline. Known terminal backgrounds are painted at their exact palette
color so decorative star effects retain their RGB input; unknown backgrounds use the
terminal reset color. The frame is restored after effects, and the AI hint has a padded
opening in the bottom rule.

The strict regression run executes 397 selected tests: 396 pass, with only the same
unchanged upstream release-only `/rollout` mismatch recorded above. Coverage includes
Chinese/multiline/narrow/disabled/unfocused snapshots, clipped zero-size viewports,
mouse selection, cursor alignment, attachments, voice controls, animation lifecycle,
AI acceptance/cancellation, and account identity. The 127 changed/new visual snapshots
were reviewed before acceptance; the strict run used no snapshot force-pass flag.
The fourth patch applies after the previous three and reproduces the verified source.

The rounded-frame release was installed after signature/version/catalog checks, with
rollback files retained at `~/.config/aiswitcher/backups/codex-input-20260930-025937/`.
A fresh Orca terminal running ordinary `codex` displayed all four rounded corners
and a ready session with the account email. A native terminal test of the installed
binary generated a real Chinese AI continuation inside the complete frame, accepted
it with Tab without submission, and confirmed the final `/status` email matched the
active credential. Existing sessions keep their loaded version until reopened.
