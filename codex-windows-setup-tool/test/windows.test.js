import test from "node:test";
import assert from "node:assert/strict";
import { defaultShortcutPath } from "../lib/windows.js";

test("defaultShortcutPath points to Desktop-style location", () => {
  const val = defaultShortcutPath();
  assert.match(val, /Desktop\\CodexApp\.lnk$/);
});
