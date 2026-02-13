import test from "node:test";
import assert from "node:assert/strict";
import { moveSelection, renderMenuScreen, renderOptionsScreen, selectMenu, shimmerText, withSpinner } from "../lib/io.js";

test("moveSelection wraps upward from first index", () => {
  assert.equal(moveSelection(0, "up", 5), 4);
});

test("moveSelection wraps downward from last index", () => {
  assert.equal(moveSelection(4, "down", 5), 0);
});

test("renderMenuScreen includes key hint footer", () => {
  const out = renderMenuScreen({
    dmgPath: "C:\\Codex.dmg",
    items: [
      { value: "1", label: "1. Launch" },
      { value: "2", label: "2. Exit" }
    ],
    selectedIndex: 0
  });

  assert.match(out, /Keys: ↑\/↓ navigate/);
  assert.match(out, /DMG:/);
  assert.match(out, /1\. Launch/);
});

test("selectMenu fallback maps numeric input to item value", async () => {
  const value = await selectMenu({
    items: [
      { value: "yes", label: "Yes" },
      { value: "no", label: "No" }
    ],
    inStream: { isTTY: false },
    outStream: { isTTY: false },
    fallbackAsk: async () => "2",
    cancelValue: "back"
  });

  assert.equal(value, "no");
});

test("shimmerText preserves characters while styling one position", () => {
  const out = shimmerText("Install", 2);
  const plain = out.replace(/\x1b\[[0-9;]*m/g, "");
  assert.equal(plain, "Install");
});

test("withSpinner executes task and returns result in non-tty mode", async () => {
  const val = await withSpinner(async () => "ok", { out: { isTTY: false } });
  assert.equal(val, "ok");
});

test("renderOptionsScreen includes context lines above options", () => {
  const out = renderOptionsScreen({
    title: "Question",
    subtitle: "Subtitle",
    contextLines: ["DMG path set: C:\\Codex.dmg", "Create shortcut: Yes"],
    items: [{ value: "yes", label: "Yes" }],
    selectedIndex: 0
  });
  assert.match(out, /DMG path set:/);
  assert.match(out, /Create shortcut:/);
  assert.match(out, /Question/);
});

test("renderOptionsScreen places prompt directly above options", () => {
  const out = renderOptionsScreen({
    title: "Do you want to launch after build?",
    subtitle: "If No, build runs with -NoLaunch.",
    contextLines: ["DMG path set: C:\\Codex.dmg"],
    items: [
      { value: "yes", label: "Yes" },
      { value: "no", label: "No" }
    ],
    selectedIndex: 0
  });

  const plain = out.replace(/\x1b\[[0-9;]*m/g, "");
  assert.match(plain, /If No, build runs with -NoLaunch\.[\s\S]*Do you want to launch after build\?/);
  assert.match(plain, /Do you want to launch after build\?\n[ ›] Yes/);
});
