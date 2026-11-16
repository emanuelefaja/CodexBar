# Compact account dashboard fork

Fork: <https://github.com/emanuelefaja/CodexBar>

Base: upstream `v0.84.0` (`5bebf9a05e68059eae11d5031c7239f1aa1d49ef`).
Branch: `blue/compact-accounts`.

## Scope

- A compact merged menu: account, limit, percentage left, reset countdown.
- Optional display-only row names and USD monthly prices from the private config. Slots follow stable display order and never route credentials; changing them does not refetch usage.
- Separate API balances, including negative balances and explicit unavailable data.
- Multiple Claude Platform billing connections, each bound to a browser/profile and API organization.
- An explicit OpenAI Web source for one existing Chrome profile and pinned Platform organization.
- Existing provider detail pages remain accessible from account rows.
- No automatic upstream updates. The fork uses the disabled updater even if an upstream Homebrew receipt exists.
- New fork-specific strings use English fallback in non-English catalogs. Existing translations are unchanged.

Subscription quotas and API balances are different products. Do not calculate an API grant balance by subtracting organization spend from a plan's advertised allowance. OpenAI Web reads the organization's exact available credits; it does not infer a subscription allowance or promise grant renewal.

## Account names and prices

Each provider config may carry a display-only `compactAccounts` map. Slot `"1"` is the first row in the
provider's stable dashboard order, `"2"` the second row, and so on. A slot only changes that row's label and
optional fixed USD monthly price; account IDs still own details, state, and credential routing.

```json
"compactAccounts": {
  "1": {"name": "Example Pro", "monthlyPriceUSD": 200},
  "2": {"name": "Example Pro 2", "monthlyPriceUSD": 200}
}
```

Names are trimmed, single-line, and limited to 48 characters. Prices must be finite, non-negative, and are
rounded to cents. Invalid values are omitted. These fields are excluded from fetch identity, so renaming or
repricing a row never refetches usage. API balance rows normally stay automatic.

## OpenAI browser credits

Choose **Web** under Settings → Providers → OpenAI, select an existing Chrome profile, and enter the required
Platform Organization ID. This source needs no API key. Auto and API keep their existing API-key behavior.
Web keeps saved API keys and token accounts passive, so one browser balance is not repeated against every key.
The compact dashboard labels it **OpenAI API**, separate from subscription quotas and Claude API balances.

Chrome-only support is intentional: the native source reads the selected profile's LocalStorage access token,
not cookies. Profile discovery reads metadata only and never auto-selects Default or creates a new profile.
Authentication and its exchange stay in memory; the source neither stores secrets nor rotates refresh tokens.
If authentication expires, open Platform in that same profile and sign in or refresh there, then refresh CodexBar.
The private Platform endpoints can change. Missing or rejected data is unavailable. A known session expiry is
checked before publication; a null expiry is allowed. Grant expiry is not a quota reset.
See [OpenAI setup and data rules](openai.md#browser-credits-explicit-web-source).

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

Installed application revision: `7c1d36a`.

- Focused OpenAI/account/provider regression run: 192 tests in 23 suites passed.
- `make check`: passed, including localization checks and strict lint. All six offline Claude Platform fixture scenarios passed.
- Independent review identified two issues, both corrected and checked: best-effort storage reads could retain an old login, and the prepaid detail card could display spend instead of balance. The source now uses strict current-key reads, and the detail card prefers the explicit balance. Synthetic real-LevelDB and final-card formatter tests cover both fixes.
- Release resource, helper CLI, symlinked CLI, cold WebKit, and isolated application launch checks: passed.
- Deep, strict ad-hoc codesign verification and a full 30-second normal-startup check: passed. The old app's open menu blocked AppleEvent Quit, so installation resumed from the verified staging app after stopping that process with TERM. No rebuild or smoke-check bypass was needed; the old app and private settings remain backed up.
- The installed OpenAI CLI Web source returned the reported available credit balance for the expected account and pinned organization. No API key or stored session credential was added.
- All five configured subscriptions returned fresh CLI readings, including both Claude Fable windows. GLM account emails are not independently verified.
- Final native-menu verification completed on this revision. The user confirmed success and supplied a screenshot showing all five subscription accounts and all three API balances together, including the negative Chrome billing balance. The browser connections remain pinned to distinct organizations.
- Safari recovered after the user renewed Full Disk Access and restarted the app. Chrome required app-specific Keychain access; helper CLI success alone did not prove app access. No permission approvals were automated, and no browser fallback or ACL edits were used. For UI automation, press the actual custom Refresh view, not its actionless NSMenuItem wrapper.
- A direct quota check confirmed that the second GLM account reports zero five-hour usage with `nextResetTime: null`. The displayed 100% remaining and unknown reset are therefore accurate; no reset is invented. GLM account emails remain independently unverified.
- The full test suite was not run.

The local Swift 6.3.2 optimized build required two narrow runtime workarounds: a callback-based WebKit identifier bridge and a nominal wrapper around the cookie-access observer TaskLocal. Packaging now exercises a detached-task synthetic cookie import, without real browser or credential access. The installer checks normal startup and restores the previous app if the fork exits during that check.
