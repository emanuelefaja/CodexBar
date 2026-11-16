# Compact account dashboard fork

Fork: <https://github.com/emanuelefaja/CodexBar>

Base: upstream `v0.84.0` (`5bebf9a05e68059eae11d5031c7239f1aa1d49ef`).
Branch: `blue/compact-accounts`.

## Scope

- A compact merged menu: account, limit, percentage left, reset countdown.
- Separate API balances, including negative balances and explicit unavailable data.
- Multiple Claude Platform billing connections, each bound to a browser/profile and API organization.
- Existing provider detail pages remain accessible from account rows.
- No automatic upstream updates. The fork uses the disabled updater even if an upstream Homebrew receipt exists.
- New fork-specific strings use English fallback in non-English catalogs. Existing translations are unchanged.

Subscription quotas and API balances are different products. Do not calculate an API grant balance by subtracting organization spend from a plan's advertised allowance. No OpenAI subscription-grant integration is added by this change.

## Build and install

Use the SwiftPM/package tools described in [DEVELOPMENT.md](DEVELOPMENT.md). Focused tests run through `Scripts/test_fast.sh`, which isolates test credentials and local preferences. Do not use real browser/Keychain reads as unit tests.

After checks pass:

```sh
./Scripts/install-local-fork.sh
```

The installer builds a release app with ad-hoc signing, verifies the staged signature, quits the existing app, and replaces `/Applications/CodexBar.app`. It keeps the previous app and private config/preferences under:

```text
~/Library/Application Support/CodexBar/ForkBackups/install-*/
```

The normal bundled CLI link continues to point to `CodexBar.app/Contents/Helpers/CodexBarCLI`.

A local build has a different signing identity from the official release. macOS may require renewed browser Keychain and Full Disk Access approval. Do not change foreign Keychain ACLs or bypass macOS privacy controls. The fork retains upstream's consent gates.

A manual Homebrew cask upgrade can still replace the app; in-app updates are disabled, not Homebrew itself.

## Rollback

Quit CodexBar. Move the current app aside, restore `CodexBar.app` from the chosen backup to `/Applications/`, then launch it. Keep the fork app until the restored app is verified. Config backups contain secrets: never paste them into issues or commit them.

Restore the saved config only if needed; doing so discards account/settings edits made after that backup. The installer does not automatically restore config on app rollback.

## Security and data rules

- Store secrets only in the user's existing private config or platform credential stores, never in this checkout.
- Browser-account selection must not fall back to a different browser after rejection.
- A pinned API organization must match the session's organization list and billing permission.
- Missing, rejected, or malformed data is unavailable, not zero.
- Retained readings must keep their capture time and a stale marker.
- An expiry is not a quota reset or a promise of another credit grant.

## Verification record

Implementation, focused checks, packaging and live-account results are recorded in the task handoff after execution. The instructions above are not evidence that those checks passed.
