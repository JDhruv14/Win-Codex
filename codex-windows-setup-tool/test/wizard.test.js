import test from "node:test";
import assert from "node:assert/strict";
import {
  getExistingDmgItems,
  getLaunchPromptItems,
  getScreen1MenuItems,
  getShortcutPromptItems,
  resolveAutoInstallPlan
} from "../lib/wizard.js";

function recommendedCount(items) {
  return items.filter((item) => item.label.includes("[Recommended]")).length;
}

test("wizard option sets include exactly one recommended option", () => {
  assert.equal(recommendedCount(getScreen1MenuItems()), 1);
  assert.equal(recommendedCount(getExistingDmgItems()), 1);
  assert.equal(recommendedCount(getShortcutPromptItems()), 1);
  assert.equal(recommendedCount(getLaunchPromptItems()), 1);
});

test("screen 1 starts with auto DMG selection option", () => {
  const items = getScreen1MenuItems();
  assert.equal(items[0].value, "1");
  assert.match(items[0].label, /Select DMG path/);
});

test("screen 1 includes an explicit Exit option", () => {
  const items = getScreen1MenuItems();
  const exit = items.find((item) => item.value === "3");
  assert.ok(exit);
  assert.match(exit.label, /Exit/);
});

test("follow-up menus include Back option", () => {
  const existing = getExistingDmgItems();
  const shortcut = getShortcutPromptItems();
  const launch = getLaunchPromptItems();

  assert.ok(existing.some((item) => item.value === "back"));
  assert.ok(shortcut.some((item) => item.value === "back"));
  assert.ok(launch.some((item) => item.value === "back"));
});

test("resolveAutoInstallPlan returns download when DMG does not exist", async () => {
  const out = await resolveAutoInstallPlan({
    defaultDmgPath: "C:/Codex.dmg",
    prompt: { ask: async () => "" },
    selectMenuFn: async () => {
      throw new Error("selectMenu should not be called");
    },
    askTextInputFn: async () => {
      throw new Error("askTextInput should not be called");
    },
    existsSync: () => false
  });

  assert.deepEqual(out, { action: "download", targetPath: "C:/Codex.dmg" });
});

test("resolveAutoInstallPlan chooses use existing", async () => {
  const out = await resolveAutoInstallPlan({
    defaultDmgPath: "C:/Codex.dmg",
    prompt: { ask: async () => "" },
    selectMenuFn: async () => "use",
    askTextInputFn: async () => ({ value: "ignored" }),
    existsSync: () => true
  });

  assert.deepEqual(out, { action: "use", targetPath: "C:/Codex.dmg" });
});

test("resolveAutoInstallPlan supports rename flow", async () => {
  const out = await resolveAutoInstallPlan({
    defaultDmgPath: "C:/Codex.dmg",
    prompt: { ask: async () => "" },
    selectMenuFn: async () => "rename",
    askTextInputFn: async () => ({ value: "C:/Custom/Codex-alt.dmg" }),
    existsSync: (p) => p === "C:/Codex.dmg",
    pathResolve: (p) => p
  });

  assert.deepEqual(out, { action: "download", targetPath: "C:/Custom/Codex-alt.dmg" });
});

test("resolveAutoInstallPlan handles rename back", async () => {
  const out = await resolveAutoInstallPlan({
    defaultDmgPath: "C:/Codex.dmg",
    prompt: { ask: async () => "" },
    selectMenuFn: async () => "rename",
    askTextInputFn: async () => ({ back: true }),
    existsSync: (p) => p === "C:/Codex.dmg"
  });

  assert.deepEqual(out, { action: "back" });
});
