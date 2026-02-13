# Wizard Screen Reference

This document defines the expected screen flow for `npm run codex-windows-setup`.

## Screen 1: DMG Setup
Options:
- `Select DMG path (attempt auto install first) [Recommended]`
- `Set DMG path`
- `Exit`

Expected behavior:
- Shows current selected DMG path.
- `Exit` leaves the tool cleanly.

## Verification Screens (Standalone Command)
Run from repository root:
- `npm run codex-windows-setup:verify`

Expected behavior:
- Displays prerequisite checks with status icons.
- Each check includes a `Where:` location.
- `warn` / `fail` checks include fix instructions.
- If auto-fixable checks exist, show:
  - `Run auto-fix now [Recommended]`
  - `Skip auto-fix`
  - `Back`
- After auto-fix, post-fix verification runs automatically.

## Auto-Install Decision Screen
From Screen 1 -> `Select DMG path (attempt auto install first)` when default DMG already exists.

Options:
- `Use existing file [Recommended]`
- `Overwrite existing file`
- `Download as new file name`
- `Back`

Expected behavior:
- If download succeeds, DMG path is set and success messaging is shown.
- If download fails, manual DMG path flow is offered.

## Set DMG Path Screen
From Screen 1 -> `Set DMG path`, or from auto-install failure.

Expected behavior:
- Text input shows default DMG path as inline gray placeholder.
- Example: `DMG path: C:\Codex-app-mac\Codex.dmg [Press Enter to use default]`.
- First typed character replaces the placeholder value.
- Guidance includes `https://developers.openai.com/codex/app`.
- `back` returns to previous menu.

## Create Shortcut Screen
Prompt:
- `Do you want to create a shortcut?`

Options:
- `Yes [Recommended]`
- `No`
- `Back`

Expected layout:
- Any supporting context/help text appears above the prompt.
- The prompt line appears directly above the options list (no explanatory text between prompt and options).

## Shortcut Directory Screen (if Yes)
Expected behavior:
- Text input shows default desktop directory as inline gray placeholder.
- First typed character replaces the placeholder value.
- `back` returns to create-shortcut prompt.

## Shortcut Name Screen (if Yes)
Expected behavior:
- Text input shows `CodexApp` as inline gray placeholder.
- First typed character replaces the placeholder value.
- `back` returns to shortcut directory screen.

## Launch Prompt Screen
Prompt:
- `Do you want to launch after build?`

Options:
- `Yes [Recommended]`
- `No`
- `Back`

Expected layout:
- Any supporting context/help text appears above the prompt.
- The prompt line appears directly above the options list (no explanatory text between prompt and options).

## Build + Completion Screens
Expected behavior:
- Build summary screen shows DMG path and selected options.
- Completion screen reports success/failure and shortcut result.
- On failure, error details are shown and tool returns to menu after continue.

## Test Coverage Map
- Screen option structure and back/exit coverage:
  - `codex-windows-setup-tool/test/wizard.test.js`
- DMG path, auto-install flow logic, and rename path handling:
  - `codex-windows-setup-tool/test/flow.test.js`
  - `codex-windows-setup-tool/test/wizard.test.js`
- Verification checks and auto-fix behavior:
  - `codex-windows-setup-tool/test/verify.test.js`
- Prompt/menu rendering and navigation behavior:
  - `codex-windows-setup-tool/test/io.test.js`
- Windows-specific process + shortcut integration:
  - `codex-windows-setup-tool/test/windows.spawn.test.js`
  - `codex-windows-setup-tool/test/windows.integration.test.js`

## Debug Logging
Run:
- `npm run codex-windows-setup:debug`
- `npm run codex-windows-setup:verify:debug`

Behavior:
- Creates a timestamped log file in `logs/`.
- Logs exact screen selections and captured text inputs.
- Captures PowerShell stdout/stderr for build/launch steps.
- Persists build/launch errors to the same log file.
- Includes lock-related install errors (for example `EBUSY`) so retry behavior can be audited.
- Runtime launch/crash logs are always emitted to `logs/runtime/` (stdout, stderr, chromium).
- In debug mode, the latest runtime logs are tailed into the wizard debug log using `APP-OUT`, `APP-ERR`, and `APP-CHROME` markers.
