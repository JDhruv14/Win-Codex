import fs from "node:fs";
import path from "node:path";
import { pipeline } from "node:stream/promises";
import { DMG_HELP_URL } from "./constants.js";
import { c } from "./io.js";

export async function resolveDmgInteractively({
  prompt,
  currentPath,
  existsSync = fs.existsSync,
  pathResolve = path.resolve,
  log = console.log,
  helpUrl = DMG_HELP_URL
}) {
  let dmgPath = currentPath;
  while (!dmgPath || !existsSync(dmgPath)) {
    if (!dmgPath) {
      log(c("No DMG found automatically.", "yellow"));
    } else {
      log(c(`DMG not found: ${dmgPath}`, "red"));
    }
    log(`${c("Get DMG:", "magenta")} ${helpUrl}`);
    const answer = (await prompt.ask(c("Enter DMG path: ", "cyan"))).trim();
    dmgPath = answer ? pathResolve(answer) : null;
  }
  return dmgPath;
}

export async function downloadDmgToPath({
  url,
  destinationPath,
  fetchImpl = fetch,
  fsModule = fs
}) {
  const res = await fetchImpl(url);
  if (!res.ok || !res.body) {
    throw new Error(`Download failed (${res.status})`);
  }

  fsModule.mkdirSync(path.dirname(destinationPath), { recursive: true });
  const tmp = `${destinationPath}.download`;
  const ws = fsModule.createWriteStream(tmp);
  await pipeline(res.body, ws);
  fsModule.renameSync(tmp, destinationPath);
  return destinationPath;
}

export function nextAvailablePath(preferredPath, { existsSync = fs.existsSync } = {}) {
  if (!existsSync(preferredPath)) return preferredPath;

  const dir = path.dirname(preferredPath);
  const ext = path.extname(preferredPath);
  const base = path.basename(preferredPath, ext);

  let n = 2;
  while (true) {
    const candidate = path.join(dir, `${base}-${n}${ext}`);
    if (!existsSync(candidate)) return candidate;
    n += 1;
  }
}
