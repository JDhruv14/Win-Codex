#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  DEFAULT_DMG_NAME,
  DEFAULT_SHORTCUT_BASENAME,
  DMG_AUTO_INSTALL_URL,
  DMG_HELP_URL
} from "./lib/constants.js";
import { findDmgCandidates, makeRunScriptArgs, pickDefaultDmg } from "./lib/core.js";
import { c, clearAndWrite, createPrompter, selectMenu, withSpinner } from "./lib/io.js";
import { downloadDmgToPath } from "./lib/flow.js";
import { createShortcut, getDefaultDesktopDir, runPowerShellArgs } from "./lib/windows.js";
import {
  getLaunchPromptItems,
  getScreen1MenuItems,
  getShortcutPromptItems,
  resolveAutoInstallPlan
} from "./lib/wizard.js";
import { applyAutoFixes, runEnvironmentChecks, statusIcon, summarizeChecks } from "./lib/verify.js";

const repoRoot = path.resolve(path.join(path.dirname(fileURLToPath(import.meta.url)), ".."));
const debugEnabled = process.argv.includes("--debug") || process.env.CODEX_SETUP_DEBUG === "1";
const verifyOnly = process.argv.includes("--verify");

function timestampForFilename(date = new Date()) {
  const yyyy = String(date.getFullYear());
  const mm = String(date.getMonth() + 1).padStart(2, "0");
  const dd = String(date.getDate()).padStart(2, "0");
  const hh = String(date.getHours()).padStart(2, "0");
  const mi = String(date.getMinutes()).padStart(2, "0");
  const ss = String(date.getSeconds()).padStart(2, "0");
  return `${yyyy}${mm}${dd}-${hh}${mi}${ss}`;
}

function createDebugLogger({ enabled, baseDir }) {
  if (!enabled) {
    return {
      enabled: false,
      logPath: null,
      info() {},
      error() {},
      stdout() {},
      stderr() {},
      appStdout() {},
      appStderr() {},
      appChromium() {}
    };
  }

  const logsDir = path.join(baseDir, "logs");
  fs.mkdirSync(logsDir, { recursive: true });
  const logPath = path.join(logsDir, `wizard-debug-${timestampForFilename()}.log`);
  fs.writeFileSync(logPath, `Codex wizard debug log started ${new Date().toISOString()}\n`, "utf8");

  const write = (level, message) => {
    fs.appendFileSync(logPath, `[${new Date().toISOString()}] [${level}] ${message}\n`, "utf8");
  };

  return {
    enabled: true,
    logPath,
    info(event, payload = null) {
      write("INFO", payload ? `${event} ${JSON.stringify(payload)}` : event);
    },
    error(event, payload = null) {
      if (payload && payload instanceof Error) {
        write("ERROR", `${event} ${payload.stack || payload.message}`);
        return;
      }
      write("ERROR", payload ? `${event} ${JSON.stringify(payload)}` : event);
    },
    stdout(text) {
      const lines = String(text).replace(/\r/g, "").split("\n");
      for (const line of lines) {
        if (line.trim().length > 0) write("PS-OUT", line);
      }
    },
    stderr(text) {
      const lines = String(text).replace(/\r/g, "").split("\n");
      for (const line of lines) {
        if (line.trim().length > 0) write("PS-ERR", line);
      }
    },
    appStdout(text) {
      const lines = String(text).replace(/\r/g, "").split("\n");
      for (const line of lines) {
        if (line.trim().length > 0) write("APP-OUT", line);
      }
    },
    appStderr(text) {
      const lines = String(text).replace(/\r/g, "").split("\n");
      for (const line of lines) {
        if (line.trim().length > 0) write("APP-ERR", line);
      }
    },
    appChromium(text) {
      const lines = String(text).replace(/\r/g, "").split("\n");
      for (const line of lines) {
        if (line.trim().length > 0) write("APP-CHROME", line);
      }
    }
  };
}
const debugLogger = createDebugLogger({ enabled: debugEnabled, baseDir: repoRoot });

function normalizeWinPath(p) {
  return p.replace(/\//g, "\\");
}

function wizardBanner() {
  return [
    c("╔══════════════════════════════════════════════════════╗", "cyan"),
    c("║  ⚙️  Codex Windows Setup Tool                       ║", "cyan"),
    c("╚══════════════════════════════════════════════════════╝", "cyan")
  ].join("\n");
}

function pushContext(context, line) {
  if (!line) return context;
  const next = [...context, line];
  return next.slice(-4);
}

function renderCheckLines(checks) {
  const lines = [];
  for (const check of checks) {
    lines.push(
      `${statusIcon(check.status)} ${check.label} | Where: ${check.where} | ${check.details}${check.fixable ? " | Auto-fix available" : ""}`
    );
    if ((check.status === "fail" || check.status === "warn") && check.fixInstructions) {
      lines.push(`   Fix: ${check.fixInstructions}`);
    }
  }
  return lines;
}

function renderStatusScreen({ title, lines = [], color = "magenta" }) {
  return [
    wizardBanner(),
    "",
    c(title, color),
    ...lines.map((line) => c(line, "dim")),
    ""
  ].join("\n");
}

async function runBuild({ dmgPath, launchAfterBuild, logger }) {
  const args = makeRunScriptArgs({
    dmgPath: normalizeWinPath(dmgPath),
    reuse: false,
    noLaunch: !launchAfterBuild
  });
  logger.info("build_start", { dmgPath, launchAfterBuild, args });
  await runPowerShellArgs(args, {
    cwd: repoRoot,
    onStdout: (text) => logger.stdout(text),
    onStderr: (text) => logger.stderr(text)
  });
  if (logger.enabled) {
    ingestRuntimeLogsIntoDebug(logger);
  }
  logger.info("build_complete", { dmgPath, launchAfterBuild });
}

function readTail(filePath, maxBytes = 24 * 1024) {
  const stat = fs.statSync(filePath);
  const size = stat.size;
  const start = Math.max(0, size - maxBytes);
  const fd = fs.openSync(filePath, "r");
  try {
    const buffer = Buffer.alloc(size - start);
    fs.readSync(fd, buffer, 0, buffer.length, start);
    return buffer.toString("utf8");
  } finally {
    fs.closeSync(fd);
  }
}

function newestByPrefix(dir, prefix) {
  const files = fs.readdirSync(dir, { withFileTypes: true })
    .filter((d) => d.isFile() && d.name.startsWith(prefix) && d.name.endsWith(".log"))
    .map((d) => path.join(dir, d.name));
  if (files.length === 0) return null;
  files.sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs);
  return files[0];
}

function ingestRuntimeLogsIntoDebug(logger) {
  try {
    const runtimeDir = path.join(repoRoot, "logs", "runtime");
    if (!fs.existsSync(runtimeDir)) return;

    const stdoutLog = newestByPrefix(runtimeDir, "codex-stdout-");
    const stderrLog = newestByPrefix(runtimeDir, "codex-stderr-");
    const chromeLog = newestByPrefix(runtimeDir, "codex-chromium-");
    logger.info("runtime_log_paths", { stdoutLog, stderrLog, chromeLog });

    if (stdoutLog) logger.appStdout(readTail(stdoutLog));
    if (stderrLog) logger.appStderr(readTail(stderrLog));
    if (chromeLog) logger.appChromium(readTail(chromeLog));
  } catch (err) {
    logger.error("runtime_log_ingest_failed", err);
  }
}

async function pause(prompt, message = "Press Enter to continue...") {
  try {
    await prompt.ask(c(`${message} `, "dim"));
  } catch {}
}

async function askTextInput({
  prompt,
  title,
  instructions,
  label,
  defaultValue,
  allowBack = true
}) {
  clearAndWrite(
    [
      wizardBanner(),
      "",
      c(title, "magenta"),
      instructions ? c(instructions, "dim") : "",
      "",
      c("Press Enter to use the default shown in the input.", "dim"),
      allowBack ? c("Type 'back' to return.", "dim") : ""
    ].filter(Boolean).join("\n")
  );

  const raw = (
    await (prompt.askWithDefault
      ? prompt.askWithDefault({ label, defaultValue, hint: "[Press Enter to use default]" })
      : prompt.ask(c(`${label} ${defaultValue} [Press Enter to use default]: `, "cyan")))
  ).trim();
  if (allowBack && raw.toLowerCase() === "back") return { back: true };
  return { value: raw ? raw : defaultValue };
}

async function setDmgPathScreen({ prompt, currentPath }) {
  const fallbackPath = path.resolve(path.join(repoRoot, DEFAULT_DMG_NAME));
  const defaultPath = currentPath || fallbackPath;

  while (true) {
    const answer = await askTextInput({
      prompt,
      title: "Set DMG Path",
      instructions: `Download from ${DMG_HELP_URL}`,
      label: "DMG path:",
      defaultValue: defaultPath,
      allowBack: true
    });
    if (answer.back) {
      debugLogger.info("screen_set_dmg_path", { action: "back" });
      return { back: true };
    }

    const resolved = path.resolve(answer.value);
    if (fs.existsSync(resolved)) {
      debugLogger.info("screen_set_dmg_path", { value: resolved });
      return { dmgPath: resolved };
    }
    debugLogger.error("screen_set_dmg_path_invalid", { value: resolved });

    clearAndWrite(
      [
        wizardBanner(),
        "",
        c("DMG file not found.", "red"),
        c(`Path: ${resolved}`, "yellow"),
        c(`Download link: ${DMG_HELP_URL}`, "magenta"),
        ""
      ].join("\n")
    );
    await pause(prompt);
  }
}

async function configureAndBuild({ prompt, dmgPath, initialContextLines = [] }) {
  const state = {
    createShortcut: false,
    shortcutDir: path.resolve(getDefaultDesktopDir()),
    shortcutName: DEFAULT_SHORTCUT_BASENAME,
    launchAfterBuild: true
  };
  let contextLines = [...initialContextLines];

  let step = "shortcutPrompt";
  while (true) {
    if (step === "shortcutPrompt") {
      const choice = await selectMenu({
        items: getShortcutPromptItems(),
        title: "Do you want to create a shortcut?",
        subtitle: "Choose shortcut behavior",
        contextLines,
        cancelValue: "back",
        fallbackAsk: (text) => prompt.ask(text)
      });

      if (choice === "back") return { back: true };
      debugLogger.info("screen_shortcut_prompt", { choice });
      state.createShortcut = choice === "yes";
      contextLines = pushContext(contextLines, `Create shortcut: ${state.createShortcut ? "Yes" : "No"}`);
      step = state.createShortcut ? "shortcutDir" : "launchPrompt";
      continue;
    }

    if (step === "shortcutDir") {
      const answer = await askTextInput({
        prompt,
        title: "Set Shortcut Directory",
        instructions: "Enter folder path for the shortcut.",
        label: "Shortcut directory:",
        defaultValue: state.shortcutDir,
        allowBack: true
      });
      if (answer.back) {
        debugLogger.info("screen_shortcut_directory", { action: "back" });
        step = "shortcutPrompt";
        continue;
      }
      state.shortcutDir = path.resolve(answer.value);
      debugLogger.info("screen_shortcut_directory", { value: state.shortcutDir });
      contextLines = pushContext(contextLines, `Shortcut directory: ${state.shortcutDir}`);
      step = "shortcutName";
      continue;
    }

    if (step === "shortcutName") {
      const answer = await askTextInput({
        prompt,
        title: "Set Shortcut Name",
        instructions: "Name only (without .lnk is fine).",
        label: "Shortcut name:",
        defaultValue: state.shortcutName,
        allowBack: true
      });
      if (answer.back) {
        debugLogger.info("screen_shortcut_name", { action: "back" });
        step = "shortcutDir";
        continue;
      }
      state.shortcutName = answer.value;
      debugLogger.info("screen_shortcut_name", { value: state.shortcutName });
      contextLines = pushContext(contextLines, `Shortcut name: ${state.shortcutName}`);
      step = "launchPrompt";
      continue;
    }

    if (step === "launchPrompt") {
      const choice = await selectMenu({
        items: getLaunchPromptItems(),
        title: "Do you want to launch after build?",
        subtitle: "If No, build runs with -NoLaunch.",
        contextLines,
        cancelValue: "back",
        fallbackAsk: (text) => prompt.ask(text)
      });

      if (choice === "back") {
        debugLogger.info("screen_launch_prompt", { action: "back" });
        step = state.createShortcut ? "shortcutName" : "shortcutPrompt";
        continue;
      }
      state.launchAfterBuild = choice === "yes";
      debugLogger.info("screen_launch_prompt", { choice, launchAfterBuild: state.launchAfterBuild });
      contextLines = pushContext(contextLines, `Launch after build: ${state.launchAfterBuild ? "Yes" : "No"}`);
      step = "build";
      continue;
    }

    if (step === "build") {
      clearAndWrite(
        renderStatusScreen({
          title: "Building...",
          lines: [
            `DMG: ${dmgPath}`,
            `Create shortcut: ${state.createShortcut ? "Yes" : "No"}`,
            state.createShortcut ? `Shortcut dir: ${state.shortcutDir}` : "",
            state.createShortcut ? `Shortcut name: ${state.shortcutName}` : "",
            `Launch after build: ${state.launchAfterBuild ? "Yes" : "No"}`
          ].filter(Boolean)
        })
      );

      try {
        let shortcutPath = null;
        if (state.createShortcut) {
          fs.mkdirSync(state.shortcutDir, { recursive: true });
          const base = state.shortcutName.endsWith(".lnk") ? state.shortcutName : `${state.shortcutName}.lnk`;
          shortcutPath = path.join(state.shortcutDir, base);
          await createShortcut({
            shortcutPath: normalizeWinPath(shortcutPath),
            workDir: normalizeWinPath(repoRoot)
          }, {
            runPowerShell: (args, options = {}) =>
              runPowerShellArgs(args, {
                ...options,
                onStdout: (text) => debugLogger.stdout(text),
                onStderr: (text) => debugLogger.stderr(text)
              })
          });
          debugLogger.info("shortcut_created", { shortcutPath });
        }

        await runBuild({ dmgPath, launchAfterBuild: state.launchAfterBuild, logger: debugLogger });

        clearAndWrite(
          renderStatusScreen({
            title: "Build completed successfully.",
            color: "green",
            lines: [
              state.createShortcut && shortcutPath ? `Shortcut created: ${shortcutPath}` : "Shortcut: not created",
              state.createShortcut && shortcutPath
                ? "If not visible on Desktop, check your OneDrive Desktop folder."
                : "",
              state.launchAfterBuild
                ? "Launch mode: stale Codex processes were stopped before fresh relaunch."
                : "Launch mode: build-only (no launch).",
              `Launch after build: ${state.launchAfterBuild ? "Yes" : "No"}`
            ].filter(Boolean)
          })
        );
      } catch (err) {
        debugLogger.error("build_failed", err);
        clearAndWrite(
          renderStatusScreen({
            title: "Build failed.",
            color: "red",
            lines: [err.message]
          })
        );
      }

      await pause(prompt);
      return { done: true };
    }
  }
}

async function runVerificationFlow({ prompt }) {
  let checks = runEnvironmentChecks({ repoRoot });
  let summary = summarizeChecks(checks);
  clearAndWrite(
    renderStatusScreen({
      title: "Environment verification",
      color: summary.fail > 0 ? "red" : summary.warn > 0 ? "yellow" : "green",
      lines: [
        `Summary: ok=${summary.ok}, warn=${summary.warn}, fail=${summary.fail}`,
        ...renderCheckLines(checks)
      ]
    })
  );

  const fixable = checks.filter((c) => c.fixable);
  debugLogger.info("screen_verify_environment", {
    summary,
    fixableIds: fixable.map((f) => f.id)
  });
  if (fixable.length === 0) {
    await pause(prompt);
    return;
  }

  const choice = await selectMenu({
    items: [
      { value: "yes", label: "Run auto-fix now [Recommended]" },
      { value: "no", label: "Skip auto-fix" },
      { value: "back", label: "Back" }
    ],
    title: "Auto-fix available",
    subtitle: `${fixable.length} check(s) can be auto-fixed.`,
    contextLines: fixable.map((f) => f.label),
    cancelValue: "back",
    fallbackAsk: (text) => prompt.ask(text)
  });
  debugLogger.info("screen_verify_autofix", { choice });

  if (choice !== "yes") return;

  const fixResults = applyAutoFixes(fixable);
  debugLogger.info("screen_verify_autofix_results", { fixResults });
  const lines = fixResults.flatMap((f) => {
    const out = [`${f.ok ? "🟢" : "🔴"} ${f.id}: ${f.details}`];
    if (!f.ok && f.fixInstructions) out.push(`   Fix: ${f.fixInstructions}`);
    return out;
  });
  clearAndWrite(
    renderStatusScreen({
      title: "Auto-fix completed",
      color: fixResults.every((x) => x.ok) ? "green" : "yellow",
      lines
    })
  );

  checks = runEnvironmentChecks({ repoRoot });
  summary = summarizeChecks(checks);
  clearAndWrite(
    renderStatusScreen({
      title: "Post-fix verification",
      color: summary.fail > 0 ? "red" : summary.warn > 0 ? "yellow" : "green",
      lines: [
        `Summary: ok=${summary.ok}, warn=${summary.warn}, fail=${summary.fail}`,
        ...renderCheckLines(checks)
      ]
    })
  );
  await pause(prompt);
}

async function safeConfigureAndBuild({ prompt, dmgPath, initialContextLines = [] }) {
  try {
    await configureAndBuild({ prompt, dmgPath, initialContextLines });
  } catch (err) {
    debugLogger.error("configure_and_build_failed", err);
    clearAndWrite(
      renderStatusScreen({
        title: "Wizard step failed.",
        color: "red",
        lines: [err?.message || String(err), "Returning to main menu..."]
      })
    );
    await pause(prompt);
  }
}

async function main() {
  const candidates = findDmgCandidates(repoRoot);
  const defaultDmgPath = path.resolve(path.join(repoRoot, DEFAULT_DMG_NAME));
  let dmgPath = pickDefaultDmg(candidates) || defaultDmgPath;

  const prompt = await createPrompter();
  debugLogger.info("wizard_start", { repoRoot, initialDmgPath: dmgPath, debugEnabled: debugLogger.enabled });
  if (debugLogger.enabled && debugLogger.logPath) {
    console.log(c(`Debug logging enabled: ${debugLogger.logPath}`, "yellow"));
  }
  if (verifyOnly) {
    debugLogger.info("verify_only_start");
    try {
      await runVerificationFlow({ prompt });
    } finally {
      debugLogger.info("verify_only_end");
      prompt.close();
    }
    return;
  }

  try {
    while (true) {
      const choice = await selectMenu({
        items: getScreen1MenuItems(),
        title: "Screen 1: DMG Setup",
        subtitle: `Current DMG path: ${dmgPath}`,
        contextLines: [`Selected DMG: ${dmgPath}`],
        cancelValue: "3",
        fallbackAsk: (text) => prompt.ask(text)
      });

      if (choice === "1") {
        debugLogger.info("screen_main_menu", { choice: "select_dmg_auto", dmgPath });
        clearAndWrite(
          [
            wizardBanner(),
            "",
            c("Attempting auto-install...", "magenta"),
            c(`Source: ${DMG_AUTO_INSTALL_URL}`, "dim"),
            c(`Target: ${defaultDmgPath}`, "dim"),
            ""
          ].join("\n")
        );

        const autoInstallPlan = await resolveAutoInstallPlan({
          prompt,
          defaultDmgPath,
          selectMenuFn: selectMenu,
          askTextInputFn: askTextInput
        });
        debugLogger.info("screen_auto_install_plan", autoInstallPlan);
        if (autoInstallPlan.action === "back") continue;
        let installContext = [];

        try {
          if (autoInstallPlan.action === "use") {
            dmgPath = autoInstallPlan.targetPath;
            installContext = [
              "Source: Existing file",
              `DMG path set: ${dmgPath}`
            ];
            clearAndWrite(
              renderStatusScreen({
                title: "Using existing DMG.",
                color: "green",
                lines: [`DMG path set to: ${dmgPath}`, "Continuing to next step..."]
              })
            );
          } else {
            await withSpinner(
              () =>
                downloadDmgToPath({
                  url: DMG_AUTO_INSTALL_URL,
                  destinationPath: autoInstallPlan.targetPath
                }),
              { text: "Installing Codex DMG..." }
            );
            dmgPath = autoInstallPlan.targetPath;
            installContext = [
              "Source: Auto-install",
              `DMG path set: ${dmgPath}`
            ];
            clearAndWrite(
              renderStatusScreen({
                title: "Auto-install succeeded.",
                color: "green",
                lines: [
                  `Downloaded to: ${dmgPath}`,
                  "DMG path has been set automatically.",
                  "Continuing to next step..."
                ]
              })
            );
          }
          debugLogger.info("screen_auto_install_result", { dmgPath, action: autoInstallPlan.action });
        } catch (err) {
          debugLogger.error("screen_auto_install_failed", err);
          clearAndWrite(
            renderStatusScreen({
              title: "Auto-install failed.",
              color: "yellow",
              lines: [
                err.message || "Download failed.",
                `Please download manually: ${DMG_HELP_URL}`
              ]
            })
          );
          await pause(prompt);

          const manual = await setDmgPathScreen({ prompt, currentPath: dmgPath });
          if (manual.back) continue;
          dmgPath = manual.dmgPath;
          debugLogger.info("screen_manual_dmg_after_auto_failure", { dmgPath });
          installContext = [
            "Source: Manual path after auto-install failure",
            `DMG path set: ${dmgPath}`
          ];
        }

        await safeConfigureAndBuild({ prompt, dmgPath, initialContextLines: installContext });
        continue;
      }

      if (choice === "2") {
        debugLogger.info("screen_main_menu", { choice: "set_dmg_path", dmgPath });
        const manual = await setDmgPathScreen({ prompt, currentPath: dmgPath });
        if (manual.back) continue;
        dmgPath = manual.dmgPath;
        debugLogger.info("screen_manual_dmg", { dmgPath });

        await safeConfigureAndBuild({
          prompt,
          dmgPath,
          initialContextLines: [
            "Source: Manual path",
            `DMG path set: ${dmgPath}`
          ]
        });
        continue;
      }

      if (choice === "3") {
        debugLogger.info("screen_main_menu", { choice: "exit", dmgPath });
        console.log(c("Bye.", "dim"));
        break;
      }
    }
  } finally {
    debugLogger.info("wizard_end");
    prompt.close();
  }
}

main().catch((err) => {
  console.error(c(`Error: ${err.message}`, "red"));
  process.exitCode = 1;
});
