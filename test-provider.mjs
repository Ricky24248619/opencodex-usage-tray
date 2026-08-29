import assert from "node:assert/strict";
import { projectQuota } from "./status-provider.mjs";

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

process.stdout.write("Quota projection tests passed\n");
