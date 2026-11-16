---
summary: "Claude Platform (Claude Console) API credit balance, credit grants, and month-to-date spend via the platform.claude.com browser session."
provider_id: claudeplatform
provider_name: Claude Platform
provider_source: Browser or manual platform.claude.com session cookies for Console API credit balance, expiring credit grants, and month-to-date spend.
plugin_scope: Opaque sessionKey cookie; API-organization credit balance, grants, and optional spend on both engines.
read_when:
  - Configuring Claude Platform
  - Debugging Claude Console credit balance or spend
---

# Claude Platform

Claude Platform shows the API credit balance of your Claude Console organization at
<https://platform.claude.com>. It sits beside the [Claude](claude.md) provider the way OpenAI API sits beside Codex:
Claude tracks Claude.ai/Claude Code subscription limits, while Claude Platform tracks prepaid API credits. The two
providers never share identity, plan, or session data.

## Authentication

Enable Claude Platform in Settings → Providers and sign in at <https://platform.claude.com>. Automatic import reads
the `sessionKey` cookie for `platform.claude.com` in CodexBar's default browser order, which covers every browser in
the shared catalog (including Brave); the Cookie source description lists them. Import follows the host's
browser-access gate: use **Refresh** beside **Cookie source** (or the menu's Refresh action) to authorize the import;
scheduled refreshes never prompt. To keep CodexBar away from every browser store, choose **Manual** in Settings → Providers → Claude
Platform → **Cookie source** (config: `"cookieSource": "manual"` plus `cookieHeader`), and paste a Cookie request
header from a signed-in platform.claude.com request; it should contain `sessionKey`. Manual cookies are stored in the
CodexBar config file. **Off** (`"cookieSource": "off"`) disables cookie access. HTTP 401 from the organization list
or credit balance request, or HTTP 403 from the organization list, rejects that session. Legacy Auto may try the
next browser profile. An explicit account reads only its selected profile and never falls back. When the selected
session is rejected, sign in at platform.claude.com again.

Why cookies: the Anthropic Admin API (`sk-ant-admin…`) is unavailable for individual Console accounts, and inference
API keys cannot read billing. The Console session is the only credential that can read an individual organization's
balance.

### Independent browser accounts

In **Accounts**, add one connection for Chrome and another for Safari. Select each browser's existing profile/store;
no extra Chrome profile is required. The shared picker lists browser-store metadata, not credentials. Browser
accounts store no cookie. Manual accounts still accept a raw sessionKey or Cookie header.

The account ID owns its cache and refresh result. A failed account does not replace another account's balance.
Browser/profile and organization changes invalidate that account's cache. The host checks the same browser
session before and after each fetch; a changed session discards the result. Full Disk Access may be needed for
Safari, and the existing browser-access gate still controls Keychain prompts.

Config provider entry (inside the config's `providers` array; synthetic IDs and paths below).
Use the picker's real store ID. For initial discovery, omit `organizationId`:

```json
{
  "id": "claudeplatform",
  "enabled": true,
  "cookieSource": "auto",
  "tokenAccounts": {
    "version": 1,
    "activeIndex": 0,
    "accounts": [
      {
        "id": "11111111-1111-4111-8111-111111111111",
        "label": "Chrome account",
        "token": "",
        "addedAt": 0,
        "browserID": "chrome",
        "browserProfileID": "/Users/example/Library/Application Support/Google/Chrome/Default",
        "organizationId": "api-org-one"
      },
      {
        "id": "22222222-2222-4222-8222-222222222222",
        "label": "Safari account",
        "token": "",
        "addedAt": 0,
        "browserID": "safari",
        "browserProfileID": "/Users/example/Library/Cookies/Cookies.binarycookies",
        "organizationId": "api-org-two"
      }
    ]
  }
}
```

Manual accounts omit `browserID` and `browserProfileID` and put the cookie in `token`. The optional
`organizationId` is account-local; it never inherits another account's or the provider's pin. An incomplete
browser selection fails closed. Without saved accounts, provider-level `browserID`, `browserProfileID`, and
`organizationId` can select one connection; omit them to keep legacy Auto/manual behavior.
`cookieSource: "off"` disables access even for saved accounts.

CLI selection uses the existing `--account <label>`, `--account-index <index>`, and `--all-accounts` mechanism.
For example: `codexbar usage --provider claudeplatform --all-accounts --json`.
No browser cookies or secrets are included in the organization evidence.

To discover a pin after signing in, fetch one explicitly selected connection:

```bash
codexbar usage --provider claudeplatform --account "Chrome account" --source web --json
codexbar usage --provider claudeplatform --account "Safari account" --source web --json
```

Check the returned account label and `usage.identity.accountOrganization`. In `usage.details`, find the section
with `title: "Billing"`, then its row with `label: "Organization ID"`. Example excerpt:

```json
{
  "title": "Billing",
  "rows": [
    { "label": "This month (UTC)", "value": "$0.00" },
    { "label": "Organization ID", "value": "api-org-one" }
  ]
}
```

Copy that row's `value` to the matching saved account's `organizationId` and reload config. Fetch it again to
verify the pin. The account `id` is a local UUID; it is **not** the Console organization UUID. Discovery succeeds
only for a sole API organization. If several exist, obtain the intended UUID from Console and set it explicitly;
CodexBar will not test their billing endpoints to choose one.

### Validated CLI import and renewal

Sign in normally at <https://platform.claude.com>, then obtain a Cookie request header containing `sessionKey`.
Pipe the single-line header privately into:

```bash
codexbar config login --provider claudeplatform --stdin --json
```

The `claude-platform` alias works identically. The command reads stdin until EOF; it accepts no cookie-bearing
command-line option and never opens a browser or reads browser stores. It validates only the supplied candidate
through the bundled provider in web/manual mode, without using existing config cookies, environment credentials,
or cached usage. Validation requires a sole API organization; it never chooses the first of several organizations.
A valid zero balance succeeds; optional spend failure does not reject an otherwise valid session.

After validation, the command privately saves the header, selects Manual, and enables Claude Platform. It preserves
unrelated settings and accounts. Invalid sessions, required-request failures, cancellation, concurrent config edits,
and write failures keep the current config unchanged. JSON success is `{"status":"authorized"}`; validation or
storage failure returns `{"status":"failed","error":"..."}` and a nonzero exit code. Input errors use the normal
CLI argument-error envelope. The cookie and upstream response bodies are never printed.

Then run `codexbar usage --provider claudeplatform --source web --json`. Repeat the import with a fresh header when
the Console session expires. There is no supported refresh-token exchange for these cookies; human sign-in may be
required again. Scheduled usage never starts login or reads stdin. The existing `config set-cookie` command remains
available for storage without validation.

## Data

These are undocumented Console endpoints used by the platform.claude.com billing page, so they may change without
notice. CodexBar only issues read-only GETs:

- `/api/organizations` lists organizations. Every organization whose `capabilities` include `api` is a candidate,
  and Claude.ai chat organizations in the same list are ignored. An account without an API organization
  reports that it has no Claude Console API organization.
- `/api/organizations/{uuid}/prepaid/credits` supplies the total balance (`amount`, in minor units) and credit grants
  (`promo_tranches` and `tranches`). Only the pinned `organizationId` is requested. Without a pin, exactly one API
  organization must exist. A missing pin target, ambiguous organizations, or HTTP 403 fails without trying another
  organization. Amounts are divided by
  10^`balance.credits.exponent` (0–4, default 2 when absent). This request is required; a malformed balance fails the
  refresh.
- `/api/organizations/{uuid}/current_spend` supplies month-to-date spend for the selected organization. It is optional:
  a failed (including HTTP 401) or malformed response keeps the balance visible and shows **Spend: Unavailable**.

The menu card shows:

- **API credit**: the soonest-expiring subscription API credit grant (`subscription_api_credit`, for example the
  credit included with a Claude Max plan) that still has credit, as a used-percentage bar with
  `$124.75 of $200.00 left · Expires Oct 28 (UTC)`. When every subscription grant is exhausted this lane is omitted and
  the menu bar falls back to purchased credit.
- **Purchased credit**: the soonest-expiring purchased grant that still has credit (or, when all are exhausted, the
  soonest one), in the same format.
- **Other credit grants**: every other unexpired grant, including exhausted subscription grants, with its own amounts
  and expiry.
- **Prepaid credits**: the total balance, which the menu bar **Balance** element also shows.
- **Billing**: **This month (UTC)** with month-to-date spend, or **Spend: Unavailable**, plus **Organization ID**.
  Use this ID to pin the account after checking its organization name. An unavailable balance is an error, not zero.

Grants whose expiry is at or before the refresh time are dropped; an unparseable expiry is treated as unknown. Credit
grants expire instead of resetting, so their expiry dates are UTC calendar dates shown as detail text rather than reset
countdowns. The organization name and the `Console session` login label are the only identity fields.

CLI: `codexbar usage --provider claude-platform --source web --json`. On Linux use a manual cookie header in the
config; automatic browser import is macOS-only.
