# Contributing

Thanks for contributing to Codex Windows Setup.

## Prerequisites
- Node.js + npm
- Windows PowerShell environment for runtime validation

## Setup
```powershell
npm install
npm test
```

## Development Workflow
1. Create a focused branch.
2. Make changes with tests/docs updates.
3. Run validation commands:
   - `npm test`
4. Open a PR with:
   - Problem statement
   - Summary of changes
   - Validation results
   - Known limitations/TODOs

## Coding Notes
- Keep setup behavior deterministic and scriptable.
- Avoid introducing hardcoded machine-specific paths.
- Update `README.md` and `docs/README.md` when flows/commands change.
