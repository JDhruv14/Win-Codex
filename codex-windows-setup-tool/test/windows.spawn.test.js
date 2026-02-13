import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { createShortcut, runPowerShellArgs } from "../lib/windows.js";

function spawnSuccess(expected) {
  return (cmd, args, opts) => {
    expected.push({ cmd, args, opts });
    const ee = new EventEmitter();
    queueMicrotask(() => ee.emit("close", 0));
    return ee;
  };
}

function spawnFailCode(code) {
  return () => {
    const ee = new EventEmitter();
    queueMicrotask(() => ee.emit("close", code));
    return ee;
  };
}

test("runPowerShellArgs invokes powershell.exe with provided args", async () => {
  const calls = [];
  await runPowerShellArgs(["-NoProfile", "-Command", "Write-Host ok"], {
    cwd: "C:\\Codex-app-mac",
    spawnFn: spawnSuccess(calls)
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].cmd, "powershell.exe");
  assert.deepEqual(calls[0].args.slice(0, 2), ["-NoProfile", "-Command"]);
  assert.equal(calls[0].opts.cwd, "C:\\Codex-app-mac");
});

test("runPowerShellArgs rejects on non-zero exit", async () => {
  await assert.rejects(
    () => runPowerShellArgs(["-NoProfile"], { spawnFn: spawnFailCode(9) }),
    /PowerShell exited with code 9/
  );
});

test("createShortcut delegates to runPowerShell with shortcut script", async () => {
  const invocations = [];
  const runPowerShell = async (args, opts) => {
    invocations.push({ args, opts });
  };
  await createShortcut(
    {
      shortcutPath: "C:\\Users\\garet\\Desktop\\CodexApp.lnk",
      workDir: "C:\\Codex-app-mac"
    },
    { runPowerShell }
  );
  assert.equal(invocations.length, 1);
  assert.equal(invocations[0].args[0], "-NoProfile");
  assert.equal(invocations[0].args[1], "-Command");
  assert.match(invocations[0].args[2], /CreateShortcut/);
  assert.equal(invocations[0].opts.cwd, "C:\\Codex-app-mac");
});
