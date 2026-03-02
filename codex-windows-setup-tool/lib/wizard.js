import fs from "node:fs";
import path from "node:path";
import { nextAvailablePath } from "./flow.js";

const REC = "[Recommended]";

function label(text, recommended = false) {
  return recommended ? `${text} ${REC}` : text;
}

export function getScreen1MenuItems() {
  return [
    { value: "1", label: label("1. Select DMG path (attempt auto install first)", true) },
    { value: "2", label: label("2. Set DMG path", false) },
    { value: "3", label: label("3. Exit", false) }
  ];
}

export function getExistingDmgItems() {
  return [
    { value: "use", label: label("Use existing file", true) },
    { value: "overwrite", label: label("Overwrite existing file", false) },
    { value: "rename", label: label("Download as new file name", false) },
    { value: "back", label: label("Back", false) }
  ];
}

export function getShortcutPromptItems() {
  return [
    { value: "yes", label: label("Yes", true) },
    { value: "no", label: label("No", false) },
    { value: "back", label: label("Back", false) }
  ];
}

export function getLaunchPromptItems() {
  return [
    { value: "yes", label: label("Yes", true) },
    { value: "no", label: label("No", false) },
    { value: "back", label: label("Back", false) }
  ];
}

export async function resolveAutoInstallPlan({
  defaultDmgPath,
  prompt,
  selectMenuFn,
  askTextInputFn,
  existsSync = fs.existsSync,
  pathResolve = path.resolve
}) {
  if (!existsSync(defaultDmgPath)) {
    return { action: "download", targetPath: defaultDmgPath };
  }

  const choice = await selectMenuFn({
    items: getExistingDmgItems(),
    title: "DMG already exists",
    subtitle: defaultDmgPath,
    cancelValue: "back",
    fallbackAsk: (text) => prompt.ask(text)
  });

  if (choice === "back") return { action: "back" };
  if (choice === "use") return { action: "use", targetPath: defaultDmgPath };
  if (choice === "overwrite") return { action: "download", targetPath: defaultDmgPath };
  if (choice === "rename") {
    const suggestion = nextAvailablePath(defaultDmgPath, { existsSync });
    const answer = await askTextInputFn({
      prompt,
      title: "Download as new file",
      instructions: "Enter a new target path for downloaded DMG.",
      label: "New DMG path:",
      defaultValue: suggestion,
      allowBack: true
    });
    if (answer.back) return { action: "back" };
    return { action: "download", targetPath: pathResolve(answer.value) };
  }

  return { action: "back" };
}
