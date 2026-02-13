# Codex Windows Setup

Run the macOS Codex app DMG on Windows by extracting, patching, and launching it with Windows-compatible native modules.

This project provides a Windows-first setup flow for users who have a Codex DMG and need a repeatable local runner. It includes a PowerShell pipeline (`scripts/run.ps1`) and an interactive terminal wizard (`codex-windows-setup-tool`) for guided setup, shortcut creation, and optional launch behavior. The repository is focused on local tooling and does not redistribute OpenAI application binaries.

## Key Features
- Extracts and prepares a Codex DMG into a runnable Windows workdir.
- Rebuilds/patches native modules for Electron compatibility.
- Interactive wizard with arrow-key navigation and back/exit flow.
- Optional automatic DMG download attempt from OpenAI static hosting.
- Optional desktop shortcut generation.
- Unit tests plus an opt-in Windows integration shortcut test.

## Quick Start
### Prerequisites
- Windows 10 or Windows 11
- Node.js (includes `npm`)
- PowerShell
- 7-Zip (`7z`) in `PATH` or installable via `winget`
- Codex CLI installed globally:

```powershell
npm i -g @openai/codex
```

### Fast Path
From the repository root:

```powershell
npm install
npm run codex-windows-setup
```

Debug mode:
```powershell
npm run codex-windows-setup:debug
```

In the wizard:
1. (Recommended) Run verification first:
   - `npm run codex-windows-setup:verify`
2. Then run wizard:
   - `npm run codex-windows-setup`
3. In wizard choose `Select DMG path (attempt auto install first)`.
4. If auto-download fails, use `Set DMG path` and point to your DMG.
5. Choose shortcut options and launch behavior.

Quick status summary:
- Recommended path: native Windows CLI mode (wizard + `scripts/run.ps1`).
- Optional path: WSL-backed workflows (manual verification required).

## Installation
### Clone
```powershell
git clone <REPO_URL>
cd Codex-app-mac
```

`TODO(maintainers): what is the canonical clone URL for this project?`

### Install dependencies
```powershell
npm install
```

## Usage
### Interactive Wizard (recommended)
```powershell
npm run codex-windows-setup
```

Debug logging mode:
```powershell
npm run codex-windows-setup:debug
```

When debug mode is enabled:
- wizard logs include exact per-screen selections/inputs
- PowerShell build/launch stdout/stderr is captured
- build/launch errors are written with stack/message details
- log file is created at `logs/wizard-debug-<timestamp>.log`
- latest runtime app logs (`logs/runtime/*.log`) are tailed into the debug log with `APP-*` markers

Runtime crash/startup logs are always enabled (debug and non-debug):
- `logs/runtime/codex-stdout-<timestamp>.log`
- `logs/runtime/codex-stderr-<timestamp>.log`
- `logs/runtime/codex-chromium-<timestamp>.log`

Wizard flow:
- Screen 1:
  - `Select DMG path (attempt auto install first) [Recommended]`
    - if no DMG exists at default target, auto-download starts
    - if DMG already exists, prompts:
      - `Use existing file`
      - `Overwrite existing file`
      - `Download as new file name`
      - `Back`
    - on success/failure, displays explicit status and selected DMG path
    - while downloading/installing, shows a spinner with shimmering status text
    - then automatically continues to the next step (no extra Enter prompt)
  - `Set DMG path`
    - text input shows default as inline gray placeholder (for example `DMG path: .\Codex.dmg [Press Enter to use default]`)
    - first typed character replaces the default placeholder value
    - manual-download instruction points to `https://developers.openai.com/codex/app`
    - confirms when path is successfully set
  - `Exit`
- Verification command (separate from wizard):
  - `npm run codex-windows-setup:verify`
    - runs prerequisite checks and reports status for each item
    - each result includes a `Where:` location to show where to validate/fix
    - for warnings/failures, prints concrete fix instructions
    - when available, prompts:
      - `Run auto-fix now [Recommended]`
      - `Skip auto-fix`
      - `Back`
    - after auto-fix, runs post-fix verification and summary
- Follow-up screens:
  - previous-step context is shown above each current prompt (for example, selected DMG path and prior choices)
  - prompt text is rendered directly above option choices
  - `Do you want to create a shortcut?` (`Yes [Recommended]` / `No` / `Back`)
  - Shortcut directory input with inline default placeholder (for example `Shortcut directory: C:\Users\<user>\Desktop [Press Enter to use default]`), with confirmation
  - Shortcut name input with inline default placeholder (for example `Shortcut name: CodexApp [Press Enter to use default]`), with confirmation
  - `Do you want to launch after build?` (`Yes [Recommended]` / `No` / `Back`)
    - launch preference is confirmed before build
  - Build status screen summarizes selected settings
  - Completion screen reports success/failure and shortcut result
  - text-input screens (for example shortcut directory/name) remain in the wizard flow and should not exit the tool

If launch is disabled, build runs with `-NoLaunch`.

### Compatibility / Verification Matrix
Legend: `🟢 working` · `🟡 partially working` · `🔴 not working` · `⚪ not tested`

| Area | Status | Where to test | How to verify | Notes |
|---|---|---|---|---|
| Wizard navigation and flow | 🟢 | Any terminal on Windows 10/11 | `npm test` | Covers wizard decision logic, menu behavior, and text-input/back flows. |
| Environment verification flow | 🟢 | Any terminal on Windows 10/11 | `npm test`, then run `npm run codex-windows-setup:verify` | Includes check rendering, fix instructions, auto-fix prompt, and post-fix summary. |
| DMG auto-install logic | 🟢 | Any terminal on Windows 10/11 | `npm test` | Includes success/failure download paths and existing-file conflict handling. |
| Windows shortcut generation | 🟢 | Real Windows 10/11 host (not WSL-only shell) | `npm run test:integration` | Verified on Windows with integration path and real shortcut creation. |
| Core build/launch script (`run.ps1`) | 🟢 | Real Windows 10 and Windows 11 machines | `.\scripts\run.ps1 -NoLaunch` then `.\scripts\run.ps1` | Verified working on tested hosts with current setup flow. |
| Login/account flow in app | 🟢 | Built app on Windows 10/11 | Build with wizard, launch app, complete sign-in | Verified working with tested app/CLI protocol pairing. |
| Git repository detection in app | 🟢 | Built app on Windows 10/11 with local and `\\wsl.localhost` repos | Open a known git repo and verify metadata loads without false “create repository” prompts | Verified working for tested local and WSL-backed repos. |
| Thread persistence | 🟢 | Built app on Windows 10/11 across restarts | Create a thread, restart app, and confirm thread history/list remains | Verified working across restart cycles in tested setup. |
| WSL availability (optional path) | 🟢 | Windows host shell | `wsl --status` | Verified in tested optional-path environment. |
| WSL can execute required tooling (optional path) | 🟢 | Inside target WSL distro | `wsl -e bash -lc "command -v node && node -v"` | Verified in tested optional-path environment. |
| WSL Codex CLI presence (optional path) | 🟢 | Inside target WSL distro | `wsl -e bash -lc "command -v codex && codex --version"` | Verified in tested optional-path environment. |

### Direct PowerShell Runner
```powershell
.\scripts\run.ps1
```

Common options:
```powershell
.\scripts\run.ps1 -DmgPath .\Codex.dmg
.\scripts\run.ps1 -Reuse
.\scripts\run.ps1 -NoLaunch
```

### Shortcut Launcher
```cmd
run.cmd
```

Launch behavior:
- `run.ps1` closes stale Codex runtime Electron processes before launch, then starts a fresh GUI process and prints the launched PID.
- Runtime startup/crash logs are always written to `logs/runtime/` (stdout/stderr/chromium log files).
- If the process exits immediately, the script throws and points to runtime log files.

## Configuration
### Important Paths
- `scripts/run.ps1`: core extraction/build/launch pipeline
- `codex-windows-setup-tool/index.js`: interactive wizard entrypoint
- `work/`: generated runtime/build workspace (ignored by git)

### Notable Inputs
- DMG input path (`-DmgPath`)
- Reuse mode (`-Reuse`)
- Build-only mode (`-NoLaunch`)

### Download Sources Used by Wizard
- Auto-attempt DMG URL:
  - `https://persistent.oaistatic.com/codex-app-prod/Codex.dmg`
- Manual-download guidance URL:
  - `https://developers.openai.com/codex/app`

## Troubleshooting
### Wizard exits during text input screens
- Symptom: wizard exits around shortcut directory/name prompts.
- Current behavior: text-input prompts should remain in-flow.
- Action: rerun `npm run codex-windows-setup` and report exact terminal output if it still exits.

### `better-sqlite3` rebuild fails
- Symptom: Visual Studio / `node-gyp` errors while preparing native modules.
- Cause: missing C++ build toolchain for native module rebuilds.
- Action: install Visual Studio Build Tools (Desktop C++ workload), then rerun setup.

### `npm install` fails with `EBUSY` / `resource busy or locked`
- Symptom: native module install fails while touching `work\native-builds\node_modules\electron\...`.
- Cause: file lock from another process (for example existing Codex/Electron/Node process, indexer, or antivirus scan).
- Current behavior: runner retries install automatically with Electron temp cleanup and avoids mandatory local Electron package install during native preparation.
- Fallback behavior: if lock persists after retries, build continues using available binaries (some native features may be reduced).
- Action if it still fails: close running Codex/Electron/Node processes and rerun.

### App shows `Invalid request` / threads not persisting
- Symptom: repeated `-32600 Invalid request` and missing thread history.
- Cause: Codex app-server protocol mismatch between desktop app build and CLI/app-server binary.
- Action: use a matching Codex CLI/app-server version for the DMG build and verify startup args compatibility.

### WSL path / `node: not found` errors
- Symptom: app-server launch failures when using WSL-backed execution.
- Cause: WSL environment missing Node/Codex on PATH.
- Default behavior: runner now stays on native Windows CLI path for compatibility.
- Optional behavior: set `CODEX_FORCE_WSL_BACKEND=1` only if your WSL Node+Codex toolchain is verified.

### Shortcut created but not visible on Desktop
- Symptom: setup reports shortcut created but you do not see it on Desktop.
- Cause: Desktop may be redirected (for example OneDrive Desktop vs local profile Desktop).
- Action: check the exact `shortcutPath` in `logs/wizard-debug-*.log`, and also check OneDrive Desktop.

## Development
### Setup
```powershell
npm install
npm test
```

### Scripts
- `npm run codex-windows-setup`: launch interactive setup wizard
- `npm run codex-windows-setup:debug`: launch wizard with debug logging to `logs/`
- `npm run codex-windows-setup:verify`: run prerequisite verification only
- `npm run codex-windows-setup:verify:debug`: run prerequisite verification with debug logging
- `npm test`: run all tests
- `npm run test:unit`: run unit tests (skip integration)
- `npm run test:integration`: run tests with integration gate enabled

### Project Structure
- `scripts/`: PowerShell runtime pipeline
- `codex-windows-setup-tool/`: Node.js interactive CLI + helpers + tests
- `docs/`: project documentation index

## Docs
- Documentation index: [`docs/README.md`](docs/README.md)
- Wizard screen reference: [`docs/wizard-screens.md`](docs/wizard-screens.md)
- Main runner script: [`scripts/run.ps1`](scripts/run.ps1)
- Wizard entrypoint: [`codex-windows-setup-tool/index.js`](codex-windows-setup-tool/index.js)

## Roadmap
`TODO(maintainers): publish roadmap milestones (for example: issue tracker labels or a ROADMAP.md).`

## Contributing
See [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Security
See [`SECURITY.md`](SECURITY.md) for vulnerability reporting.

## Governance
- Code of Conduct: [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)
- Contribution guide: [`CONTRIBUTING.md`](CONTRIBUTING.md)
- `TODO(maintainers): document maintainers and release decision process.`

## License
This repository is licensed under the MIT License. See [`LICENSE`](LICENSE).

## Acknowledgements
- OpenAI Codex app and CLI ecosystem.
- Electron and Node.js tooling used in the build pipeline.
