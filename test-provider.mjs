import assert from "node:assert/strict";
import { projectQuota, resolveActiveAccount } from "./status-provider.mjs";

const nowSeconds = Math.floor(Date.now() / 1000);
const asymmetric = projectQuota({
  shortPercent: 17,
  shortResetAt: nowSeconds + (2 * 60 * 60),
  shortWindowSeconds: 18_000,
  weeklyPercent: 63,
  weeklyResetAt: nowSeconds + (5 * 24 * 60 * 60),
});
assert.equal(asymmetric.fiveHour.usedPercent, 17);
assert.equal(asymmetric.fiveHour.windowSeconds, 18_000);
assert.equal(asymmetric.fiveHour.resetAt, (nowSeconds + (2 * 60 * 60)) * 1000);
assert.equal(asymmetric.week.usedPercent, 63);
assert.equal(asymmetric.week.resetAt, (nowSeconds + (5 * 24 * 60 * 60)) * 1000);

const extremes = projectQuota({
  shortPercent: 0,
  weeklyPercent: 100,
});
assert.equal(extremes.fiveHour.usedPercent, 0);
assert.equal(extremes.week.usedPercent, 100);

const canonical = projectQuota({
  fiveHourPercent: 22,
  fiveHourResetAt: nowSeconds + 60,
  shortPercent: 88,
  shortResetAt: nowSeconds + 120,
  weeklyPercent: 44,
});
assert.equal(canonical.fiveHour.usedPercent, 22);
assert.equal(canonical.fiveHour.resetAt, (nowSeconds + 60) * 1000);
assert.equal(canonical.week.usedPercent, 44);

const accounts = [
  { id: "primary-arbitrary-id", isMain: true, logLabel: "primary-live" },
  { id: "secondary-arbitrary-id", isMain: false, logLabel: "secondary-live" },
];

const selectedSecondary = resolveActiveAccount(accounts, {
  activeCodexAccountId: "secondary-arbitrary-id",
});
assert.equal(selectedSecondary.activeAccountId, "secondary-arbitrary-id");
assert.equal(selectedSecondary.activeAccountLabel, "secondary-live");
assert.equal(selectedSecondary.activeAccount, accounts[1]);

const selectedPrimary = resolveActiveAccount(accounts, {
  activeCodexAccountId: "primary-arbitrary-id",
});
assert.equal(selectedPrimary.activeAccountId, "primary-arbitrary-id");
assert.equal(selectedPrimary.activeAccountLabel, "primary-live");
assert.equal(selectedPrimary.activeAccount, accounts[0]);

const dynamicPrimaryFallback = resolveActiveAccount(accounts, {
  activeCodexAccountId: "stale-account-id",
});
assert.equal(dynamicPrimaryFallback.activeAccountId, "primary-arbitrary-id");
assert.equal(dynamicPrimaryFallback.activeAccountLabel, "primary-live");

const firstAccountFallback = resolveActiveAccount([
  { id: "first-live-id", logLabel: "first-live" },
  { id: "second-live-id", logLabel: "second-live" },
], {});
assert.equal(firstAccountFallback.activeAccountId, "first-live-id");
assert.equal(firstAccountFallback.activeAccountLabel, "first-live");

const idLabelFallback = resolveActiveAccount([
  { id: "dynamic-main-id", isMain: true },
], {});
assert.equal(idLabelFallback.activeAccountId, "dynamic-main-id");
assert.equal(idLabelFallback.activeAccountLabel, "dynamic-main-id");

process.stdout.write("Quota and active-account projection tests passed\n");
