import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { createShortcut } from "../lib/windows.js";

const runIntegration = process.env.RUN_WINDOWS_INTEGRATION === "1" && process.platform === "win32";

test("windows integration: create actual .lnk shortcut", { skip: !runIntegration }, async () => {
  const shortcutWin = "C:\\Codex-app-mac\\work\\CodexAppTestShortcut.lnk";
  const shortcutWsl = "/mnt/c/Codex-app-mac/work/CodexAppTestShortcut.lnk";
  try {
    if (fs.existsSync(shortcutWsl)) fs.unlinkSync(shortcutWsl);
    await createShortcut({ shortcutPath: shortcutWin, workDir: "C:\\Codex-app-mac" });
    assert.equal(fs.existsSync(shortcutWsl), true);
  } finally {
    if (fs.existsSync(shortcutWsl)) fs.unlinkSync(shortcutWsl);
  }
});
