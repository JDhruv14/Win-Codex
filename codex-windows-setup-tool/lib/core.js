import fs from "node:fs";
import path from "node:path";
import { DEFAULT_DMG_NAME } from "./constants.js";

export function findDmgCandidates(repoRoot) {
  const direct = path.join(repoRoot, DEFAULT_DMG_NAME);
  const candidates = [];
  if (fs.existsSync(direct)) candidates.push(direct);

  const entries = fs.readdirSync(repoRoot, { withFileTypes: true });
  for (const entry of entries) {
    if (!entry.isFile()) continue;
    if (!entry.name.toLowerCase().endsWith(".dmg")) continue;
    const full = path.join(repoRoot, entry.name);
    if (!candidates.includes(full)) candidates.push(full);
  }
  return candidates;
}

export function pickDefaultDmg(candidates) {
  if (!Array.isArray(candidates) || candidates.length === 0) return null;
  const codexNamed = candidates.find((p) => path.basename(p).toLowerCase() === DEFAULT_DMG_NAME.toLowerCase());
  return codexNamed || candidates[0];
}

export function makeRunScriptArgs({ dmgPath, reuse, noLaunch }) {
  const args = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "scripts/run.ps1"];
  if (dmgPath) args.push("-DmgPath", dmgPath);
  if (reuse) args.push("-Reuse");
  if (noLaunch) args.push("-NoLaunch");
  return args;
}

export function escapePsSingleQuoted(value) {
  return String(value).replace(/'/g, "''");
}

export function buildShortcutPs({ shortcutPath, workDir }) {
  const escapedShortcut = escapePsSingleQuoted(shortcutPath);
  const escapedWorkDir = escapePsSingleQuoted(workDir);
  const runScript = `${workDir}\\scripts\\run.ps1`.replace(/\\/g, "\\\\");
  return [
    "$ws = New-Object -ComObject WScript.Shell",
    `$s = $ws.CreateShortcut('${escapedShortcut}')`,
    "$s.TargetPath = 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe'",
    `$s.Arguments = '-NoProfile -ExecutionPolicy Bypass -File \"${runScript}\" -Reuse'`,
    `$s.WorkingDirectory = '${escapedWorkDir}'`,
    "$s.Description = 'Launch Codex DMG runner UI'",
    "$s.Save()",
    "Write-Output 'shortcut-created'"
  ].join("; ");
}
