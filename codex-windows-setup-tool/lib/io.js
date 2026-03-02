import readline from "node:readline/promises";
import { emitKeypressEvents } from "node:readline";
import { stdin as input, stdout as output } from "node:process";

const COLOR = {
  reset: "\x1b[0m",
  dim: "\x1b[2m",
  cyan: "\x1b[36m",
  green: "\x1b[32m",
  yellow: "\x1b[33m",
  red: "\x1b[31m",
  magenta: "\x1b[35m"
};
const SPINNER_FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

export function c(text, color) {
  return `${COLOR[color] || ""}${text}${COLOR.reset}`;
}

export function banner() {
  return [
    c("╔══════════════════════════════════════════════════════╗", "cyan"),
    c("║  ⚙️  Codex DMG Runner UI                            ║", "cyan"),
    c("║  Select an option to run setup and launch flows.    ║", "cyan"),
    c("╚══════════════════════════════════════════════════════╝", "cyan")
  ].join("\n");
}

export async function createPrompter() {
  const isInteractive = input.isTTY && output.isTTY && typeof input.setRawMode === "function";

  return {
    async ask(text) {
      const rl = readline.createInterface({ input, output });
      try {
        return await rl.question(text);
      } finally {
        rl.close();
      }
    },
    async askWithDefault({ label, defaultValue, hint = "[Press Enter to use default]" }) {
      if (!isInteractive) {
        const rl = readline.createInterface({ input, output });
        try {
          const answer = await rl.question(c(`${label} ${defaultValue} ${hint}: `, "cyan"));
          return answer.trim() ? answer : defaultValue;
        } finally {
          rl.close();
        }
      }

      const suffix = hint ? ` ${c(hint, "dim")}` : "";
      let value = "";
      let usingDefault = true;

      return await new Promise((resolve, reject) => {
        const render = () => {
          const shown = usingDefault ? c(defaultValue, "dim") : value;
          output.write(`\r\x1b[2K${c(label, "cyan")} ${shown}${suffix}`);
        };

        const cleanup = () => {
          input.off("keypress", onKeypress);
          if (input.isTTY && input.setRawMode) input.setRawMode(false);
          input.pause();
          output.write("\n");
        };

        const onKeypress = (str, key) => {
          if (!key) return;

          if (key.ctrl && key.name === "c") {
            cleanup();
            reject(new Error("Prompt cancelled"));
            return;
          }

          if (key.name === "return") {
            const out = usingDefault ? defaultValue : value;
            cleanup();
            resolve(out);
            return;
          }

          if (key.name === "backspace") {
            if (usingDefault) return;
            value = value.slice(0, -1);
            if (value.length === 0) usingDefault = true;
            render();
            return;
          }

          const printable =
            typeof str === "string" &&
            str.length === 1 &&
            !key.ctrl &&
            !key.meta &&
            key.name !== "escape";

          if (!printable) return;

          if (usingDefault) {
            value = str;
            usingDefault = false;
          } else {
            value += str;
          }
          render();
        };

        emitKeypressEvents(input);
        input.setRawMode(true);
        input.resume();
        input.on("keypress", onKeypress);
        render();
      });
    },
    close() {
      // No-op: each ask call creates and closes its own interface.
    }
  };
}

export function menuText({ dmgPath }) {
  const dmgLabel = dmgPath ? c(dmgPath, "green") : c("Not set", "yellow");
  return [
    "",
    `${c("DMG:", "magenta")} ${dmgLabel}`,
    "",
    `${c("1.", "cyan")} 🚀 Full setup and launch`,
    `${c("2.", "cyan")} ♻️  Launch with -Reuse`,
    `${c("3.", "cyan")} 📦 Set DMG path`,
    `${c("4.", "cyan")} 🔗 Create shortcut`,
    `${c("5.", "cyan")} ❌ Exit`,
    ""
  ].join("\n");
}

export function moveSelection(index, key, length) {
  if (length <= 0) return 0;
  if (key === "up") return (index - 1 + length) % length;
  if (key === "down") return (index + 1) % length;
  return index;
}

export function renderMenuScreen({ dmgPath, items, selectedIndex }) {
  const lines = [banner(), ""];
  if (dmgPath !== undefined) {
    const dmgLabel = dmgPath ? c(dmgPath, "green") : c("Not set", "yellow");
    lines.push(`${c("DMG:", "magenta")} ${dmgLabel}`);
    lines.push("");
  }

  for (let i = 0; i < items.length; i += 1) {
    const item = items[i];
    const selected = i === selectedIndex;
    const marker = selected ? c("›", "green") : " ";
    const text = selected ? c(item.label, "green") : item.label;
    lines.push(`${marker} ${text}`);
  }

  lines.push("");
  lines.push(c("Keys: ↑/↓ navigate • Enter select • q quit", "dim"));
  return lines.join("\n");
}

export function renderOptionsScreen({ title, subtitle, contextLines = [], items, selectedIndex }) {
  const lines = [banner(), ""];
  if (subtitle) lines.push(c(subtitle, "dim"));
  if (contextLines.length > 0) {
    for (const line of contextLines) {
      lines.push(c(`• ${line}`, "yellow"));
    }
  }
  if (subtitle || contextLines.length > 0) lines.push("");
  if (title) lines.push(c(title, "magenta"));

  for (let i = 0; i < items.length; i += 1) {
    const item = items[i];
    const selected = i === selectedIndex;
    const marker = selected ? c("›", "green") : " ";
    const text = selected ? c(item.label, "green") : item.label;
    lines.push(`${marker} ${text}`);
  }

  lines.push("");
  lines.push(c("Keys: ↑/↓ navigate • Enter select • q quit", "dim"));
  return lines.join("\n");
}

export function clearAndWrite(text, out = output) {
  out.write("\x1b[2J\x1b[H");
  out.write(`${text}\n`);
}

export function shimmerText(text, tick) {
  if (!text) return "";
  const idx = tick % text.length;
  let out = "";
  for (let i = 0; i < text.length; i += 1) {
    if (i === idx) {
      out += `${COLOR.cyan}${text[i]}${COLOR.reset}`;
    } else {
      out += `${COLOR.dim}${text[i]}${COLOR.reset}`;
    }
  }
  return out;
}

export async function withSpinner(task, { text = "Working...", out = output, intervalMs = 80 } = {}) {
  const run = typeof task === "function" ? task : () => task;
  if (!out.isTTY) return run();

  let tick = 0;
  const timer = setInterval(() => {
    const frame = SPINNER_FRAMES[tick % SPINNER_FRAMES.length];
    out.write(`\r${c(frame, "cyan")} ${shimmerText(text, tick)}`);
    tick += 1;
  }, intervalMs);

  try {
    return await run();
  } finally {
    clearInterval(timer);
    out.write("\r\x1b[2K");
  }
}

export async function selectMenu({
  dmgPath,
  items,
  fallbackAsk,
  inStream = input,
  outStream = output,
  title,
  subtitle,
  contextLines = [],
  cancelValue = "5"
}) {
  if (!inStream.isTTY || !outStream.isTTY || !inStream.setRawMode) {
    if (!fallbackAsk) throw new Error("No fallback prompt available in non-interactive mode.");
    const raw = (await fallbackAsk(c(`Select option (1-${items.length}): `, "cyan"))).trim();
    const numeric = Number(raw);
    if (Number.isInteger(numeric) && numeric >= 1 && numeric <= items.length) {
      return items[numeric - 1]?.value ?? cancelValue;
    }
    return raw || cancelValue;
  }

  let selectedIndex = 0;
  const render = title || subtitle ? renderOptionsScreen : renderMenuScreen;
  clearAndWrite(render({ dmgPath, title, subtitle, contextLines, items, selectedIndex }), outStream);

  return await new Promise((resolve) => {
    const onKeypress = (_str, key) => {
      if (!key) return;
      if (key.ctrl && key.name === "c") {
        cleanup();
        resolve(cancelValue);
        return;
      }
      if (key.name === "q" || key.name === "escape") {
        cleanup();
        resolve(cancelValue);
        return;
      }
      if (key.name === "up" || key.name === "down") {
        selectedIndex = moveSelection(selectedIndex, key.name, items.length);
        clearAndWrite(render({ dmgPath, title, subtitle, contextLines, items, selectedIndex }), outStream);
        return;
      }
      if (key.name === "return") {
        const value = items[selectedIndex]?.value ?? "5";
        cleanup();
        resolve(value);
      }
    };

    const cleanup = () => {
      inStream.off("keypress", onKeypress);
      if (inStream.isTTY && inStream.setRawMode) {
        inStream.setRawMode(false);
      }
      inStream.pause();
      outStream.write("\n");
    };

    emitKeypressEvents(inStream);
    inStream.setRawMode(true);
    inStream.resume();
    inStream.on("keypress", onKeypress);
  });
}
