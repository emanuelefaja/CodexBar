// Offline checks only: no browser discovery, Keychain, network, or account credentials.
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

let provider;
vm.runInNewContext(
  fs.readFileSync(new URL("../Sources/CodexBarCore/Resources/Plugins/claudeplatform.js", import.meta.url), "utf8"),
  {
    defineProvider(value) {
      provider = value;
    },
  },
);
const org = (uuid) => ({ uuid, name: `Synthetic ${uuid}`, capabilities: ["api"] });
async function fixture({
  organizations = [org("org-one")],
  pin,
  balance = 0,
  creditStatus = 200,
  spendStatus = 200,
  spend = 0,
  authStatus = 200,
} = {}) {
  const paths = [];
  const ctx = {
    settings: { get: () => pin },
    fail: Object.fromEntries(
      [
        "missingCredential",
        "authenticationExpired",
        "permissionDenied",
        "parseFailure",
        "apiFailure",
        "providerUnavailable",
        "rateLimited",
      ].map((kind) => [kind, (message) => Object.assign(new Error(message), { kind })]),
    ),
    browser: {
      availability: () => "auto",
      supportedBrowsers: "Synthetic",
      async *sessions() {
        yield { id: "synthetic-only" };
      },
      rejectCookie() {},
    },
    http: {
      async get(url) {
        const path = new URL(url).pathname;
        paths.push(path);
        if (path === "/api/organizations") return { status: authStatus, bodyText: JSON.stringify(organizations) };
        if (path.endsWith("/prepaid/credits"))
          return { status: creditStatus, bodyText: JSON.stringify({ amount: balance, currency: "USD" }) };
        if (path.endsWith("/current_spend"))
          return { status: spendStatus, bodyText: JSON.stringify({ amount: spend }) };
        throw new Error(`Unexpected path ${path}`);
      },
    },
    date: { now: () => new Date("2026-10-13T00:00:00Z"), iso: (value) => new Date(value) },
    format: { currency: (amount) => `$${amount.toFixed(2)}` },
    pct: (used, limit) => (used / limit) * 100,
  };
  try {
    return { value: await provider.fetchUsage(ctx), paths };
  } catch (error) {
    return { error, paths };
  }
}

const zero = await fixture();
assert.equal(zero.value.cost.balance, 0);
assert.equal(zero.value.details[0].rows[0].value, "$0.00");
assert.equal(zero.value.details[0].rows[1].value, "org-one");
const negative = await fixture({ balance: -252, spendStatus: 500 });
assert.equal(negative.value.cost.balance, -2.52);
assert.equal(negative.value.details[0].rows[0].value, "Unavailable");
const unavailable = await fixture({ creditStatus: 500 });
assert.equal(unavailable.error.kind, "providerUnavailable");
assert.equal(unavailable.value, undefined);
const multiple = [org("org-one"), org("org-two")];
for (const pin of [undefined, "missing", "../invalid"]) {
  const rejected = await fixture({ organizations: multiple, pin });
  assert.equal(rejected.error.kind, "permissionDenied");
  assert.deepEqual(rejected.paths, ["/api/organizations"]);
}
const pinned = await fixture({ organizations: multiple, pin: "org-two" });
assert.equal(pinned.value.identity.organization, "Synthetic org-two");
assert.deepEqual(pinned.paths, [
  "/api/organizations",
  "/api/organizations/org-two/prepaid/credits",
  "/api/organizations/org-two/current_spend",
]);
const denied = await fixture({ organizations: multiple, pin: "org-one", creditStatus: 403 });
assert.equal(denied.error.kind, "permissionDenied");
assert.deepEqual(denied.paths, ["/api/organizations", "/api/organizations/org-one/prepaid/credits"]);
const expired = await fixture({ authStatus: 401 });
assert.equal(expired.error.kind, "authenticationExpired");
assert.equal(negative.value.cost.balance, -2.52);
console.log(
  "Claude Platform offline fixtures passed (zero, negative, unavailable, org pinning, no fallback, auth failure).",
);
