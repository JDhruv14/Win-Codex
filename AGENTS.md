# AGENTS.md

## Cursor Cloud specific instructions

### Project Overview

This is **Codex for Windows** — a Windows-only PowerShell project that repackages the official macOS Codex desktop app (Electron) to run on Windows. The entire codebase is two files:

- `scripts/run.ps1` — main build/run PowerShell script (extraction, patching, native module rebuild, packaging)
- `run.cmd` — thin batch wrapper

There is no `package.json`, no automated test suite, no CI/CD pipeline, and no cross-platform tooling.

### Platform Constraint

The script targets **Windows 10/11 only**. It uses Windows-specific tools (`robocopy`, `where.exe`, `winget`, COM objects for shortcuts, etc.) and cannot be executed end-to-end on Linux. On the Linux Cloud VM, development work is limited to **static analysis and linting**.

### Linting

PowerShell Core (`pwsh`) and PSScriptAnalyzer are installed on the VM. To lint:

```bash
pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path scripts/run.ps1 -Severity Error,Warning,Information"
```

To check syntax only (parse without executing):

```bash
pwsh -NoProfile -Command "\$t=\$null;\$e=\$null; [System.Management.Automation.Language.Parser]::ParseFile('scripts/run.ps1',[ref]\$t,[ref]\$e) | Out-Null; Write-Host \"Errors: \$(\$e.Count)\""
```

### Known Lint Findings (baseline)

- 1 **Error**: `PSAvoidAssignmentToAutomaticVariable` (line 37 — `$home` variable shadowed inside `Resolve-7z`)
- ~31 **Warnings**: mostly `PSAvoidUsingWriteHost` (expected for an interactive script) and `PSUseApprovedVerbs` (custom function names like `Ensure-Command`, `Patch-Preload`)
- 1 **Information**: `PSAvoidUsingPositionalParameters`

These are pre-existing in the repo and are acceptable for a user-facing interactive script.

### No Automated Tests

There are no unit or integration tests. Validation is manual on a Windows machine with a Codex `.dmg` file.

### Running the Application

The application cannot be run on this Linux VM. It requires Windows + a Codex `.dmg` file placed in the repo root. See the `README.md` **Getting Started** section for Windows setup instructions.
