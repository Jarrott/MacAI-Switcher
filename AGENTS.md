# AI Switcher Development Guide

This project follows the global enterprise development rules supplied by the
maintainer. The rules below capture project-specific constraints only.

## Architecture

- Target: native macOS 14+ menu-bar app built with Swift 6 and SwiftUI.
- App state lives in `AccountsManager`; views must not read or write credential
  files directly.
- Provider credential logic stays under `Services/*CredentialStore.swift`.
- Provider HTTP parsing stays in `UsageService`; parsing must remain unit-testable
  without live network or real credentials.
- User-facing strings belong in both `en.lproj` and `zh-Hans.lproj`.

## Security and data correctness

- Never commit or log access tokens, refresh tokens, account credential files,
  Keychain payloads, or local `accounts.json` content.
- Unknown provider values remain optional. Never convert an unavailable usage,
  reset date, or reset-credit count into a real zero.
- Account switching must back up the current live credential before replacement.
- Codex and Claude credentials are independent; active state is tracked per
  provider.
- New provider response mappings require parser tests with synthetic payloads.

## UI

- Keep the menu compact and keyboard accessible. Preserve loading, empty, error,
  active, hover, and disabled states.
- Prefer macOS visual-effect materials and existing SwiftUI controls over custom
  drawing or third-party UI dependencies.
- Validate menu changes through the `AISWITCHER_RENDER` preview path in English
  and Chinese.

## Verification

For code changes, run as applicable:

1. `swift format` with the checked-in `.swift-format` configuration.
2. `swift test`.
3. `swift build -c release` or `./build-app.sh release` for bundle changes.
4. English and Chinese preview rendering for menu UI changes.
5. Review changed files and update `README.md`, `docs/`, and `CHANGELOG.md`.
