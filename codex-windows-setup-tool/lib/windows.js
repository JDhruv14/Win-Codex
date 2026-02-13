import path from "node:path";
import { spawn } from "node:child_process";
import { DEFAULT_SHORTCUT_NAME } from "./constants.js";
import { buildShortcutPs } from "./core.js";
import fs from "node:fs";

function asWinPath(p) {
  return p.replace(/\//g, "\\");
}

export function getDefaultDesktopDir() {
  const profile = process.env.USERPROFILE || "C:\\Users\\Public";
  const oneDrive = process.env.ONEDRIVE || "";
  const candidates = [
    oneDrive ? asWinPath(path.win32.join(oneDrive, "Desktop")) : "",
    asWinPath(path.win32.join(profile, "Desktop")),
    "C:\\Users\\Public\\Desktop"
  ].filter(Boolean);

  for (const candidate of candidates) {
    if (windowsPathExists(candidate)) return candidate;
  }
  return candidates[0];
}

function windowsPathExists(winPath) {
  if (process.platform === "win32") return fs.existsSync(winPath);
  const m = /^([A-Za-z]):\\(.*)$/.exec(winPath);
  if (!m) return false;
  const drive = m[1].toLowerCase();
  const rest = m[2].replace(/\\/g, "/");
  return fs.existsSync(`/mnt/${drive}/${rest}`);
}

export function runPowerShellArgs(
  args,
  { cwd, spawnFn = spawn, onStdout = () => {}, onStderr = () => {}, inheritOutput = true } = {}
) {
  return new Promise((resolve, reject) => {
    const captureOutput = true;
    const child = spawnFn("powershell.exe", args, {
      cwd,
      stdio: captureOutput ? "pipe" : "inherit",
      shell: false
    });
    if (captureOutput) {
      if (child.stdout) {
        child.stdout.on("data", (chunk) => {
          const text = chunk.toString();
          onStdout(text);
          if (inheritOutput) process.stdout.write(chunk);
        });
      }
      if (child.stderr) {
        child.stderr.on("data", (chunk) => {
          const text = chunk.toString();
          onStderr(text);
          if (inheritOutput) process.stderr.write(chunk);
        });
      }
    }
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) return resolve();
      reject(new Error(`PowerShell exited with code ${code}`));
    });
  });
}

export async function createShortcut({ shortcutPath, workDir }, deps = {}) {
  const script = buildShortcutPs({ shortcutPath, workDir });
  const args = ["-NoProfile", "-Command", script];
  const runner = deps.runPowerShell || runPowerShellArgs;
  await runner(args, { cwd: workDir, spawnFn: deps.spawnFn });
}

export function defaultShortcutPath() {
  return asWinPath(path.win32.join(getDefaultDesktopDir(), DEFAULT_SHORTCUT_NAME));
}
