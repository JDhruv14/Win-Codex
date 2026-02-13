import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";

function parseMajor(version) {
  const major = Number(String(version || "").split(".")[0]);
  return Number.isFinite(major) ? major : 0;
}

function makeCheck({
  id,
  label,
  where,
  status,
  details,
  fixable = false,
  fixInstructions = ""
}) {
  return { id, label, where, status, details, fixable, fixInstructions };
}

function hasCommand(name, spawnSyncFn = spawnSync, platform = process.platform) {
  if (platform === "win32") {
    const r = spawnSyncFn("cmd", ["/c", "where", name], { stdio: "pipe", encoding: "utf8" });
    return r.status === 0;
  }
  const r = spawnSyncFn("sh", ["-lc", `command -v ${name}`], { stdio: "pipe", encoding: "utf8" });
  return r.status === 0;
}

function runFixCommand(command, spawnSyncFn = spawnSync) {
  const r = spawnSyncFn("cmd", ["/c", command], { stdio: "inherit", encoding: "utf8" });
  return r.status === 0;
}

export function runEnvironmentChecks({
  repoRoot,
  platform = process.platform,
  nodeVersion = process.versions.node,
  spawnSyncFn = spawnSync,
  fsModule = fs
}) {
  const workDir = path.join(repoRoot, "work");
  const checks = [];

  checks.push(makeCheck({
    id: "os",
    label: "Windows 10/11",
    where: "This machine",
    status: platform === "win32" ? "ok" : "fail",
    details: platform === "win32" ? "Windows detected." : `Unsupported platform: ${platform}`,
    fixInstructions: "Run the setup tool on Windows 10 or Windows 11."
  }));

  const nodeMajor = parseMajor(nodeVersion);
  checks.push(makeCheck({
    id: "node",
    label: "Node.js runtime",
    where: "This machine",
    status: nodeMajor >= 18 ? "ok" : "fail",
    details: `Detected Node ${nodeVersion}. Required: >= 18.`,
    fixInstructions: "Install Node.js 18+ from https://nodejs.org and reopen the terminal."
  }));

  const npmOk = hasCommand("npm", spawnSyncFn, platform);
  checks.push(makeCheck({
    id: "npm",
    label: "npm available",
    where: "This machine",
    status: npmOk ? "ok" : "fail",
    details: npmOk ? "npm found in PATH." : "npm not found in PATH.",
    fixInstructions: "Install Node.js (includes npm) and verify with `npm --version`."
  }));

  const psOk = hasCommand("powershell.exe", spawnSyncFn, platform) || hasCommand("powershell", spawnSyncFn, platform);
  checks.push(makeCheck({
    id: "powershell",
    label: "PowerShell available",
    where: "This machine",
    status: psOk ? "ok" : "fail",
    details: psOk ? "PowerShell found." : "PowerShell not found.",
    fixInstructions: "Install PowerShell 5+ / PowerShell 7 and ensure `powershell.exe` is in PATH."
  }));

  const sevenZipOk = hasCommand("7z", spawnSyncFn, platform);
  checks.push(makeCheck({
    id: "7zip",
    label: "7-Zip (7z) available",
    where: "This machine",
    status: sevenZipOk ? "ok" : "warn",
    details: sevenZipOk ? "7z found in PATH." : "7z not found. Runner will fail without extraction tooling.",
    fixable: !sevenZipOk,
    fixInstructions: "Install 7-Zip from https://www.7-zip.org or run `winget install --id 7zip.7zip -e`."
  }));

  const codexOk = hasCommand("codex", spawnSyncFn, platform);
  checks.push(makeCheck({
    id: "codex",
    label: "Codex CLI available",
    where: "This machine",
    status: codexOk ? "ok" : "warn",
    details: codexOk ? "codex found in PATH." : "codex not found globally. Setup can still use local CLI fallback.",
    fixable: !codexOk,
    fixInstructions: "Install with `npm i -g @openai/codex`, then verify with `codex --version`."
  }));

  const wslOk = hasCommand("wsl", spawnSyncFn, platform);
  checks.push(
    makeCheck({
      id: "wsl",
      label: "WSL availability (optional)",
      where: "This machine",
      status: "ok",
      details: wslOk
        ? "WSL detected (optional path available)."
        : "WSL not detected (native Windows path still supported).",
      fixInstructions: "Optional: install WSL with `wsl --install` if you plan to run Codex from Linux paths."
    })
  );

  try {
    fsModule.mkdirSync(workDir, { recursive: true });
    checks.push(makeCheck({
      id: "workdir",
      label: "Writable work directory",
      where: workDir,
      status: "ok",
      details: "work directory is writable.",
      fixInstructions: ""
    }));
  } catch (err) {
    checks.push(makeCheck({
      id: "workdir",
      label: "Writable work directory",
      where: workDir,
      status: "fail",
      details: err.message,
      fixInstructions: `Ensure you can write to ${workDir} (permissions or antivirus policy).`
    }));
  }

  return checks;
}

export function statusIcon(status) {
  if (status === "ok") return "🟢";
  if (status === "warn") return "🟡";
  if (status === "fail") return "🔴";
  return "⚪";
}

export function applyAutoFixes(checks, spawnSyncFn = spawnSync) {
  const results = [];
  for (const check of checks) {
    if (!check.fixable) continue;

    if (check.id === "7zip") {
      const ok = runFixCommand("winget install --id 7zip.7zip -e --source winget --accept-package-agreements --accept-source-agreements --silent", spawnSyncFn);
      results.push({
        id: check.id,
        ok,
        details: ok ? "7-Zip install command completed." : "7-Zip install command failed.",
        fixInstructions: check.fixInstructions
      });
      continue;
    }
    if (check.id === "codex") {
      const ok = runFixCommand("npm i -g @openai/codex", spawnSyncFn);
      results.push({
        id: check.id,
        ok,
        details: ok ? "Codex CLI install command completed." : "Codex CLI install command failed.",
        fixInstructions: check.fixInstructions
      });
    }
  }
  return results;
}

export function summarizeChecks(checks) {
  const fail = checks.filter((c) => c.status === "fail").length;
  const warn = checks.filter((c) => c.status === "warn").length;
  const ok = checks.filter((c) => c.status === "ok").length;
  return { ok, warn, fail };
}
