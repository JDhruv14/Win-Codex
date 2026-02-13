import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { buildShortcutPs, escapePsSingleQuoted, findDmgCandidates, makeRunScriptArgs, pickDefaultDmg } from "../lib/core.js";

test("findDmgCandidates returns Codex.dmg first when present", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "codex-windows-setup-tool-test-"));
  fs.writeFileSync(path.join(dir, "Codex.dmg"), "x");
  fs.writeFileSync(path.join(dir, "Other.dmg"), "x");

  const cands = findDmgCandidates(dir);
  assert.equal(path.basename(cands[0]), "Codex.dmg");
  assert.equal(cands.length, 2);
});

test("pickDefaultDmg prefers Codex.dmg", () => {
  const candidates = ["C:/tmp/Other.dmg", "C:/tmp/Codex.dmg"];
  assert.equal(pickDefaultDmg(candidates), "C:/tmp/Codex.dmg");
});

test("makeRunScriptArgs composes flags", () => {
  const args = makeRunScriptArgs({ dmgPath: "C:\\Codex.dmg", reuse: true, noLaunch: true });
  assert.deepEqual(args, [
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    "scripts/run.ps1",
    "-DmgPath",
    "C:\\Codex.dmg",
    "-Reuse",
    "-NoLaunch"
  ]);
});

test("escapePsSingleQuoted doubles single quotes", () => {
  assert.equal(escapePsSingleQuoted("C:\\Users\\o'hara"), "C:\\Users\\o''hara");
});

test("buildShortcutPs contains expected launcher pieces", () => {
  const ps = buildShortcutPs({
    shortcutPath: "C:\\Users\\garet\\Desktop\\CodexApp.lnk",
    workDir: "C:\\Codex-app-mac"
  });
  assert.match(ps, /CreateShortcut\('/);
  assert.match(ps, /powershell\.exe/);
  assert.match(ps, /run\.ps1/);
  assert.match(ps, /shortcut-created/);
});
