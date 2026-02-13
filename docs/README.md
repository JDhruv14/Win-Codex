# Documentation

This directory is the entrypoint for deeper documentation beyond the root README.

## Current Docs
- Runtime pipeline: [`../scripts/run.ps1`](../scripts/run.ps1)
- Interactive wizard: [`../codex-windows-setup-tool/index.js`](../codex-windows-setup-tool/index.js)
- Wizard screen-by-screen behavior: [`wizard-screens.md`](wizard-screens.md)
- Test suite: [`../codex-windows-setup-tool/test`](../codex-windows-setup-tool/test)
- Verification logic (prereq checks + auto-fix): [`../codex-windows-setup-tool/lib/verify.js`](../codex-windows-setup-tool/lib/verify.js)
- Debug run command: `npm run codex-windows-setup:debug` (writes `logs/wizard-debug-*.log`)
- Verification run command: `npm run codex-windows-setup:verify`
- Verification debug command: `npm run codex-windows-setup:verify:debug` (writes `logs/wizard-debug-*.log`)

## TODO
- `TODO(maintainers): add troubleshooting docs (common Windows/WSL/node-gyp issues).`
- `TODO(maintainers): add release/versioning policy docs.`
