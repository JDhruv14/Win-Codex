import test from "node:test";
import assert from "node:assert/strict";
import { applyAutoFixes, runEnvironmentChecks, summarizeChecks } from "../lib/verify.js";

test("runEnvironmentChecks reports warnings when optional tools are missing", () => {
  const checks = runEnvironmentChecks({
    repoRoot: "C:/repo",
    platform: "win32",
    nodeVersion: "22.1.0",
    spawnSyncFn: () => ({ status: 1 }),
    fsModule: { mkdirSync: () => {} }
  });

  const ids = new Set(checks.map((c) => c.id));
  assert.equal(ids.has("7zip"), true);
  assert.equal(ids.has("codex"), true);
  assert.equal(ids.has("wsl"), true);
  assert.equal(checks.some((c) => c.status === "warn"), true);
  assert.equal(checks.some((c) => c.fixInstructions && c.fixInstructions.length > 0), true);
});

test("summarizeChecks counts statuses", () => {
  const out = summarizeChecks([
    { status: "ok" },
    { status: "warn" },
    { status: "fail" },
    { status: "ok" }
  ]);
  assert.deepEqual(out, { ok: 2, warn: 1, fail: 1 });
});

test("applyAutoFixes returns results for fixable checks", () => {
  const results = applyAutoFixes(
    [
      { id: "7zip", fixable: true, fixInstructions: "install 7z" },
      { id: "codex", fixable: true, fixInstructions: "install codex" }
    ],
    () => ({ status: 0 })
  );

  assert.equal(results.length, 2);
  assert.equal(results.every((r) => r.ok), true);
  assert.equal(results.every((r) => typeof r.fixInstructions === "string"), true);
});
