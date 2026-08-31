import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { DatabaseSync } from "node:sqlite";

const codexRoot = process.env.CODEX_HOME?.trim() || join(homedir(), ".codex");
const openCodexRoot = process.env.OPENCODEX_HOME?.trim() || join(homedir(), ".opencodex");
const stateDbPath = join(codexRoot, "state_5.sqlite");
const historyDbPath = join(codexRoot, "thread_history_1.sqlite");
const openCodexConfigPath = join(openCodexRoot, "config.json");
const adminTokenPath = join(openCodexRoot, "admin-api-token");

const RUNNING_FRESHNESS_SECONDS = 10 * 60;
const RECENT_TASK_SECONDS = 2 * 60 * 60;
const MAX_TASKS = 8;

function safeError(error) {
  if (!(error instanceof Error)) return "Unexpected local error";
  return error.message
    .replace(/ocx_(?:admin|data|session)_[A-Za-z0-9_-]+/g, "<redacted>")
    .slice(0, 500);
}

function readOpenCodexConfig() {
  const parsed = JSON.parse(readFileSync(openCodexConfigPath, "utf8"));
  return parsed && typeof parsed === "object" ? parsed : {};
}

function managementToken() {
  const token = process.env.OPENCODEX_ADMIN_AUTH_TOKEN?.trim()
    || readFileSync(adminTokenPath, "utf8").trim();
  if (!/^ocx_admin_[A-Za-z0-9_-]{43}$/.test(token)) {
    throw new Error("OpenCodex management token is unavailable or invalid");
  }
  return token;
}

function openCodexBaseUrl() {
  const config = readOpenCodexConfig();
  const parsedPort = Number(config.port);
  const port = Number.isInteger(parsedPort) && parsedPort > 0 && parsedPort <= 65535
    ? parsedPort
    : 10100;
  return `http://127.0.0.1:${port}`;
}

async function openCodexJson(path, init = {}) {
  const headers = new Headers(init.headers);
  headers.set("x-opencodex-api-key", managementToken());
  if (init.body !== undefined) headers.set("content-type", "application/json");
  const response = await fetch(`${openCodexBaseUrl()}${path}`, {
    ...init,
    headers,
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
    signal: AbortSignal.timeout(path.includes("refresh=1") ? 30_000 : 15_000),
  });
  const text = await response.text();
  let payload = null;
  if (text) {
    try { payload = JSON.parse(text); }
    catch { payload = { error: text.slice(0, 300) }; }
  }
  if (!response.ok) {
    const message = typeof payload?.error === "string"
      ? payload.error
      : `OpenCodex request failed (${response.status})`;
    throw new Error(message);
  }
  return payload;
}

function unixSeconds(value) {
  if (!Number.isFinite(value)) return null;
  return value > 10_000_000_000 ? Math.floor(value / 1000) : Math.floor(value);
}

function epochMilliseconds(value) {
  if (!Number.isFinite(value) || value <= 0) return null;
  return value > 10_000_000_000 ? Math.floor(value) : Math.floor(value * 1000);
}

function threadDigest(threadId) {
  return createHash("sha256").update(threadId).digest("hex").slice(0, 32);
}

function queryTaskRows() {
  if (!existsSync(stateDbPath) || !existsSync(historyDbPath)) return [];

  const historyDb = new DatabaseSync(historyDbPath, { readOnly: true });
  const stateDb = new DatabaseSync(stateDbPath, { readOnly: true });
  try {
    historyDb.exec("PRAGMA query_only = ON; PRAGMA busy_timeout = 1500;");
    stateDb.exec("PRAGMA query_only = ON; PRAGMA busy_timeout = 1500;");
    const cutoff = Math.floor(Date.now() / 1000) - RECENT_TASK_SECONDS;
    const turns = historyDb.prepare(`
      WITH ranked AS (
        SELECT
          thread_id,
          turn_id,
          status,
          started_at,
          completed_at,
          duration_ms,
          ROW_NUMBER() OVER (
            PARTITION BY thread_id
            ORDER BY COALESCE(started_at, 0) DESC, rollout_ordinal DESC
          ) AS rank
        FROM thread_turns
      )
      SELECT thread_id, turn_id, status, started_at, completed_at, duration_ms
      FROM ranked
      WHERE rank = 1
        AND (status = 'inProgress' OR COALESCE(completed_at, 0) >= ?)
      ORDER BY CASE WHEN status = 'inProgress' THEN 0 ELSE 1 END,
               COALESCE(started_at, 0) DESC
      LIMIT ?
    `).all(cutoff, MAX_TASKS * 2);

    if (turns.length === 0) return [];
    const threadIds = [...new Set(turns.map(row => String(row.thread_id)))];
    const placeholders = threadIds.map(() => "?").join(",");
    const threadRows = stateDb.prepare(`
      SELECT
        id,
        title,
        preview,
        model,
        reasoning_effort,
        tokens_used,
        updated_at,
        updated_at_ms,
        archived
      FROM threads
      WHERE id IN (${placeholders})
    `).all(...threadIds);
    const threads = new Map(threadRows.map(row => [String(row.id), row]));
    return turns
      .map(turn => ({ ...turn, thread: threads.get(String(turn.thread_id)) }))
      .filter(row => row.thread && Number(row.thread.archived) === 0)
      .slice(0, MAX_TASKS);
  } finally {
    historyDb.close();
    stateDb.close();
  }
}

function taskAccountFromModel(model, knownLabels) {
  if (typeof model !== "string") return null;
  const slash = model.indexOf("/");
  if (slash <= 0) return null;
  const prefix = model.slice(0, slash);
  return knownLabels.has(prefix) ? prefix : null;
}

function accountLogLabel(account, index = 0) {
  const logLabel = typeof account?.logLabel === "string" ? account.logLabel.trim() : "";
  if (logLabel) return logLabel;
  const id = typeof account?.id === "string" ? account.id.trim() : "";
  return id || `account-${index + 1}`;
}

export function resolveActiveAccount(accountsValue, activePayloadValue) {
  const accounts = Array.isArray(accountsValue) ? accountsValue : [];
  const requestedId = typeof activePayloadValue?.activeCodexAccountId === "string"
    ? activePayloadValue.activeCodexAccountId.trim()
    : "";
  const activeAccount = (requestedId
    ? accounts.find(account => String(account?.id) === requestedId)
    : null)
    || accounts.find(account => account?.isMain === true)
    || accounts[0]
    || null;
  const activeIndex = activeAccount ? accounts.indexOf(activeAccount) : -1;
  return {
    activeAccount,
    activeAccountId: activeAccount ? String(activeAccount.id) : (requestedId || null),
    activeAccountLabel: activeAccount ? accountLogLabel(activeAccount, activeIndex) : null,
  };
}

export function projectQuota(quotaValue) {
  const quota = quotaValue && typeof quotaValue === "object" ? quotaValue : {};
  const fiveHourPercent = Number.isFinite(quota.fiveHourPercent)
    ? quota.fiveHourPercent
    : Number.isFinite(quota.shortPercent) ? quota.shortPercent : null;
  const fiveHourResetAt = Number.isFinite(quota.fiveHourResetAt)
    ? quota.fiveHourResetAt
    : quota.shortResetAt;
  const fiveHourWindowSeconds = Number.isFinite(quota.fiveHourWindowSeconds)
    ? quota.fiveHourWindowSeconds
    : Number.isFinite(quota.shortWindowSeconds) ? quota.shortWindowSeconds : 18_000;
  return {
    fiveHour: {
      usedPercent: fiveHourPercent,
      resetAt: epochMilliseconds(fiveHourResetAt),
      windowSeconds: fiveHourWindowSeconds,
    },
    week: {
      usedPercent: Number.isFinite(quota.weeklyPercent) ? quota.weeklyPercent : null,
      resetAt: epochMilliseconds(quota.weeklyResetAt),
    },
  };
}

function projectStatus(accountsPayload, activePayload, usagePayload, logsPayload) {
  const nowSeconds = Math.floor(Date.now() / 1000);
  const rawAccounts = Array.isArray(accountsPayload?.accounts) ? accountsPayload.accounts : [];
  const {
    activeAccountId,
    activeAccount,
    activeAccountLabel: activeLabel,
  } = resolveActiveAccount(rawAccounts, activePayload);
  const accountLabels = new Set(
    rawAccounts
      .map((account, index) => accountLogLabel(account, index))
      .filter(Boolean),
  );
  const accountIdByLabel = new Map(
    rawAccounts.map((account, index) => [
      accountLogLabel(account, index),
      String(account.id),
    ]),
  );

  const usageByAccount = new Map();
  for (const row of Array.isArray(usagePayload?.accounts) ? usagePayload.accounts : []) {
    if (typeof row?.accountLogLabel === "string") usageByAccount.set(row.accountLogLabel, row);
  }

  const latestLogByConversation = new Map();
  for (const log of Array.isArray(logsPayload?.logs) ? logsPayload.logs : []) {
    if (typeof log?.conversationId !== "string") continue;
    const previous = latestLogByConversation.get(log.conversationId);
    if (!previous || Number(log.timestamp || 0) >= Number(previous.timestamp || 0)) {
      latestLogByConversation.set(log.conversationId, log);
    }
  }

  let taskRows = [];
  let taskStateAvailable = true;
  try {
    taskRows = queryTaskRows();
  } catch {
    taskStateAvailable = false;
  }

  const tasks = taskRows.map(row => {
    const thread = row.thread;
    const threadId = String(row.thread_id);
    const log = latestLogByConversation.get(threadDigest(threadId));
    let accountLabel = typeof log?.accountLogLabel === "string" ? log.accountLogLabel : null;
    if (!accountLabel || !accountLabels.has(accountLabel)) {
      accountLabel = taskAccountFromModel(thread.model, accountLabels) || activeLabel;
    }
    const updatedSeconds = unixSeconds(Number(thread.updated_at_ms || 0))
      || unixSeconds(Number(thread.updated_at || 0))
      || 0;
    const rawStatus = String(row.status || "unknown");
    const status = rawStatus === "inProgress"
      ? (nowSeconds - updatedSeconds <= RUNNING_FRESHNESS_SECONDS ? "running" : "stalled")
      : rawStatus === "completed" ? "completed"
      : rawStatus === "failed" ? "failed"
      : rawStatus === "interrupted" ? "interrupted"
      : rawStatus.toLowerCase();
    const title = String(thread.title || thread.preview || "Untitled task")
      .replace(/\s+/g, " ")
      .trim();
    const startedAt = epochMilliseconds(Number(row.started_at));
    const completedAt = epochMilliseconds(Number(row.completed_at));
    const durationMs = row.duration_ms !== null
      && row.duration_ms !== undefined
      && Number.isFinite(Number(row.duration_ms))
      ? Number(row.duration_ms)
      : startedAt ? Math.max(0, Date.now() - startedAt) : null;
    return {
      id: threadId,
      title: title || "Untitled task",
      status,
      model: typeof thread.model === "string" ? thread.model : "unknown",
      reasoningEffort: typeof thread.reasoning_effort === "string" ? thread.reasoning_effort : null,
      tokensUsed: Number(thread.tokens_used || 0),
      accountLabel,
      accountId: accountIdByLabel.get(accountLabel) || null,
      startedAt,
      completedAt,
      durationMs,
      lastActivityAt: updatedSeconds ? updatedSeconds * 1000 : null,
    };
  });

  const runningCountByLabel = new Map();
  for (const task of tasks) {
    if (task.status !== "running") continue;
    runningCountByLabel.set(task.accountLabel, (runningCountByLabel.get(task.accountLabel) || 0) + 1);
  }

  const accounts = rawAccounts.map((account, index) => {
    const label = accountLogLabel(account, index);
    const usage = usageByAccount.get(label) || {};
    const projectedQuota = projectQuota(account.quota);
    const alias = typeof account.alias === "string" && account.alias.trim() ? account.alias.trim() : null;
    return {
      id: String(account.id),
      label,
      displayName: alias || (account.isMain ? "Main" : label.toUpperCase()),
      alias,
      email: typeof account.email === "string" ? account.email : "",
      plan: typeof account.plan === "string" ? account.plan : "unknown",
      active: activeAccountId !== null && String(account.id) === activeAccountId,
      paused: account.paused === true,
      needsReauth: account.needsReauth === true,
      health: typeof account.healthLabel === "string" ? account.healthLabel : "unknown",
      priority: Number(account.priority || 0),
      ...projectedQuota,
      tokens7d: Number(usage.totalTokens || 0),
      requests7d: Number(usage.requests || 0),
      coverage: Number.isFinite(usage.usageCoverageRatio) ? usage.usageCoverageRatio : null,
      runningTasks: runningCountByLabel.get(label) || 0,
    };
  });

  const summary = usagePayload?.summary && typeof usagePayload.summary === "object"
    ? usagePayload.summary
    : {};
  return {
    connected: true,
    generatedAt: Date.now(),
    openCodexGeneratedAt: Number(usagePayload?.generatedAt || 0) || null,
    activeAccountId,
    activeAccountLabel: activeLabel,
    accounts,
    tasks,
    taskStateAvailable,
    counts: {
      running: tasks.filter(task => task.status === "running").length,
      stalled: tasks.filter(task => task.status === "stalled").length,
      recent: tasks.filter(task => task.status !== "running" && task.status !== "stalled").length,
    },
    totals: {
      tokens7d: Number(summary.totalTokens || 0),
      requests7d: Number(summary.requests || 0),
      measuredRequests7d: Number(summary.measuredRequests || 0),
      coverage: Number.isFinite(summary.coverageRatio) ? summary.coverageRatio : null,
    },
    routing: {
      pinned: activePayload?.pinned === true,
      pinnedAccountId: typeof activePayload?.pinnedAccountId === "string" ? activePayload.pinnedAccountId : null,
      strategy: typeof activePayload?.accountPoolStrategy === "string" ? activePayload.accountPoolStrategy : "quota",
      autoSwitchThreshold: Number(activePayload?.autoSwitchThreshold ?? 80),
    },
  };
}

async function loadStatus(force) {
  const [accounts, active, usage, logs] = await Promise.all([
    openCodexJson(`/api/codex-auth/accounts${force ? "?refresh=1" : ""}`),
    openCodexJson("/api/codex-auth/active"),
    openCodexJson("/api/usage?range=7d"),
    openCodexJson("/api/logs?tail=500&limit=500"),
  ]);
  return projectStatus(accounts, active, usage, logs);
}

async function switchAccount(accountId) {
  const accountsPayload = await openCodexJson("/api/codex-auth/accounts");
  const accounts = Array.isArray(accountsPayload?.accounts) ? accountsPayload.accounts : [];
  const targetAccount = accounts.find(account => String(account.id) === accountId);
  if (!targetAccount) throw new Error("Unknown OpenCodex account");
  const targetLabel = accountLogLabel(targetAccount, accounts.indexOf(targetAccount));
  await openCodexJson("/api/codex-auth/active", {
    method: "PUT",
    body: { accountId },
  });
  try {
    return {
      ...(await loadStatus(false)),
      switchConfirmed: true,
      switchRefreshError: null,
    };
  } catch (error) {
    return {
      connected: false,
      generatedAt: Date.now(),
      activeAccountId: accountId,
      activeAccountLabel: targetLabel,
      switchConfirmed: true,
      switchRefreshError: safeError(error),
    };
  }
}

async function main() {
  const command = process.argv[2] || "status";
  if (command === "status") {
    const force = process.argv.includes("--refresh");
    process.stdout.write(`${JSON.stringify(await loadStatus(force))}\n`);
    return;
  }
  if (command === "switch") {
    const accountId = String(process.argv[3] || "").trim();
    if (!accountId) throw new Error("An account id is required");
    process.stdout.write(`${JSON.stringify(await switchAccount(accountId))}\n`);
    return;
  }
  throw new Error(`Unknown command: ${command}`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => {
    process.stderr.write(`${safeError(error)}\n`);
    process.exitCode = 1;
  });
}
