import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { Readable } from "node:stream";
import { downloadDmgToPath, nextAvailablePath, resolveDmgInteractively } from "../lib/flow.js";

function makePrompt(answers) {
  let idx = 0;
  return {
    async ask() {
      const v = answers[idx] ?? "";
      idx += 1;
      return v;
    }
  };
}

test("resolveDmgInteractively asks until existing path is provided", async () => {
  const logs = [];
  const existing = new Set(["C:/ok/Codex.dmg"]);
  const prompt = makePrompt(["C:/missing.dmg", "C:/ok/Codex.dmg"]);

  const out = await resolveDmgInteractively({
    prompt,
    currentPath: null,
    existsSync: (p) => existing.has(p),
    pathResolve: (p) => p,
    log: (line) => logs.push(line),
    helpUrl: "https://example.test/dmg"
  });

  assert.equal(out, "C:/ok/Codex.dmg");
  assert.ok(logs.some((l) => String(l).includes("No DMG found")));
  assert.ok(logs.some((l) => String(l).includes("https://example.test/dmg")));
  assert.ok(logs.some((l) => String(l).includes("DMG not found: C:/missing.dmg")));
});

test("downloadDmgToPath writes downloaded bytes to destination", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "codex-dmg-download-"));
  const destinationPath = path.join(dir, "Codex.dmg");

  const fetchImpl = async () => ({
    ok: true,
    status: 200,
    body: Readable.from(["dmg-bytes"])
  });

  const out = await downloadDmgToPath({
    url: "https://example.test/Codex.dmg",
    destinationPath,
    fetchImpl
  });

  assert.equal(out, destinationPath);
  assert.equal(fs.readFileSync(destinationPath, "utf8"), "dmg-bytes");
});

test("downloadDmgToPath throws on failed response", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "codex-dmg-download-fail-"));
  const destinationPath = path.join(dir, "Codex.dmg");

  const fetchImpl = async () => ({
    ok: false,
    status: 500,
    body: null
  });

  await assert.rejects(
    () =>
      downloadDmgToPath({
        url: "https://example.test/Codex.dmg",
        destinationPath,
        fetchImpl
      }),
    /Download failed \(500\)/
  );
});

test("nextAvailablePath returns first free suffixed filename", () => {
  const existing = new Set([
    "C:/tmp/Codex.dmg",
    "C:/tmp/Codex-2.dmg"
  ]);

  const out = nextAvailablePath("C:/tmp/Codex.dmg", {
    existsSync: (p) => existing.has(p)
  });

  assert.equal(out, "C:/tmp/Codex-3.dmg");
});
