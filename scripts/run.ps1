param(
  [string]$DmgPath,
  [string]$WorkDir = (Join-Path $PSScriptRoot "..\work"),
  [string]$CodexCliPath,
  [switch]$Reuse,
  [switch]$NoLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Command([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "$Name not found."
  }
}

function Resolve-7z([string]$BaseDir) {
  $cmd = Get-Command 7z -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Path }
  $p1 = Join-Path $env:ProgramFiles "7-Zip\7z.exe"
  $p2 = Join-Path ${env:ProgramFiles(x86)} "7-Zip\7z.exe"
  if (Test-Path $p1) { return $p1 }
  if (Test-Path $p2) { return $p2 }
  $wg = Get-Command winget -ErrorAction SilentlyContinue
  if ($wg) {
    & winget install --id 7zip.7zip -e --source winget --accept-package-agreements --accept-source-agreements --silent | Out-Null
    if (Test-Path $p1) { return $p1 }
    if (Test-Path $p2) { return $p2 }
  }
  if (-not $BaseDir) { return $null }
  $tools = Join-Path $BaseDir "tools"
  New-Item -ItemType Directory -Force -Path $tools | Out-Null
  $sevenZipDir = Join-Path $tools "7zip"
  New-Item -ItemType Directory -Force -Path $sevenZipDir | Out-Null
  $home = "https://www.7-zip.org/"
  try { $html = (Invoke-WebRequest -Uri $home -UseBasicParsing).Content } catch { return $null }
  $extra = [regex]::Match($html, 'href="a/(7z[0-9]+-extra\.7z)"').Groups[1].Value
  if (-not $extra) { return $null }
  $extraUrl = "https://www.7-zip.org/a/$extra"
  $sevenRUrl = "https://www.7-zip.org/a/7zr.exe"
  $sevenR = Join-Path $tools "7zr.exe"
  $extraPath = Join-Path $tools $extra
  if (-not (Test-Path $sevenR)) { Invoke-WebRequest -Uri $sevenRUrl -OutFile $sevenR }
  if (-not (Test-Path $extraPath)) { Invoke-WebRequest -Uri $extraUrl -OutFile $extraPath }
  & $sevenR x -y $extraPath -o"$sevenZipDir" | Out-Null
  $p3 = Join-Path $sevenZipDir "7z.exe"
  if (Test-Path $p3) { return $p3 }
  return $null
}

function Resolve-CodexCliPath([string]$Explicit) {
  if ($Explicit) {
    if (Test-Path $Explicit) { return (Resolve-Path $Explicit).Path }
    throw "Codex CLI not found: $Explicit"
  }

  $envOverride = $env:CODEX_CLI_PATH
  if ($envOverride -and (Test-Path $envOverride)) {
    return (Resolve-Path $envOverride).Path
  }

  $candidates = @()

  try {
    $whereExe = & where.exe codex.exe 2>$null
    if ($whereExe) { $candidates += $whereExe }
    $whereCmd = & where.exe codex 2>$null
    if ($whereCmd) { $candidates += $whereCmd }
  } catch {}

  try {
    $npmRoot = (& $npmCmd root -g 2>$null).Trim()
    if ($npmRoot) {
      $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "aarch64-pc-windows-msvc" } else { "x86_64-pc-windows-msvc" }
      $candidates += (Join-Path $npmRoot "@openai\codex\vendor\$arch\codex\codex.exe")
      $candidates += (Join-Path $npmRoot "@openai\codex\vendor\x86_64-pc-windows-msvc\codex\codex.exe")
      $candidates += (Join-Path $npmRoot "@openai\codex\vendor\aarch64-pc-windows-msvc\codex\codex.exe")
    }
  } catch {}

  foreach ($c in $candidates) {
    if (-not $c) { continue }
    if ($c -match '\.cmd$' -and (Test-Path $c)) {
      try {
        $cmdDir = Split-Path $c -Parent
        $vendor = Join-Path $cmdDir "node_modules\@openai\codex\vendor"
        if (Test-Path $vendor) {
          $found = Get-ChildItem -Recurse -Filter "codex.exe" $vendor -ErrorAction SilentlyContinue | Select-Object -First 1
          if ($found) { return (Resolve-Path $found.FullName).Path }
        }
      } catch {}
    }
    if (Test-Path $c) {
      return (Resolve-Path $c).Path
    }
  }

  return $null
}

function Ensure-LocalCodexCli([string]$BaseDir) {
  if (-not $BaseDir) { return $null }
  $cliRoot = Join-Path $BaseDir "codex-cli"
  New-Item -ItemType Directory -Force -Path $cliRoot | Out-Null

  $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "aarch64-pc-windows-msvc" } else { "x86_64-pc-windows-msvc" }
  $modernPkg = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "@openai\codex-win32-arm64" } else { "@openai\codex-win32-x64" }
  $modernVendorExe = Join-Path $cliRoot "node_modules\$modernPkg\vendor\$arch\codex\codex.exe"
  $legacyVendorExe = Join-Path $cliRoot "node_modules\@openai\codex\vendor\$arch\codex\codex.exe"
  if (Test-Path $modernVendorExe) { return $modernVendorExe }
  if (Test-Path $legacyVendorExe) { return $legacyVendorExe }

  Push-Location $cliRoot
  try {
    if (-not (Test-Path (Join-Path $cliRoot "package.json"))) {
      & $npmCmd init -y | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "npm init failed for local codex-cli workspace." }
    }

    & $npmCmd install --no-save @openai/codex@latest | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "npm install @openai/codex@latest failed." }
  } finally {
    Pop-Location
  }

  if (Test-Path $modernVendorExe) { return $modernVendorExe }
  if (Test-Path $legacyVendorExe) { return $legacyVendorExe }
  $fallback = Get-ChildItem -Recurse -File -Path (Join-Path $cliRoot "node_modules") -Filter "codex.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($fallback) { return $fallback.FullName }
  return $null
}

function Escape-JsString([string]$Text) {
  if ($null -eq $Text) { return "" }
  return ($Text -replace '\\', '\\\\' -replace '"', '\"')
}

function Resolve-WslDefaultDistro() {
  try {
    $status = (& wsl.exe --status 2>$null | Out-String)
    $m = [regex]::Match($status, 'Default Distribution:\s*(.+)')
    if ($m.Success) {
      $name = ($m.Groups[1].Value -replace "`0", "").Trim()
      if ($name) { return $name }
    }
  } catch {}

  try {
    $list = & wsl.exe -l -q 2>$null
    foreach ($line in $list) {
      $name = ($line -replace "`0", "").Trim()
      if ($name) { return $name }
    }
  } catch {}

  return $null
}

function Resolve-WslCodexPath([string]$Distro) {
  if (-not $Distro) { return $null }
  try {
    $cmd = 'export NVM_DIR=$HOME/.nvm; [ -s $NVM_DIR/nvm.sh ] && . $NVM_DIR/nvm.sh; command -v codex || true'
    $path = (& wsl.exe -d $Distro --exec /usr/bin/env bash -lc $cmd 2>$null | Out-String).Trim()
    if (-not $path) { return $null }
    if ($path -like "/mnt/c/*") { return $null }
    return $path
  } catch {}
  return $null
}

function Write-Header([string]$Text) {
  Write-Host "`n=== $Text ===" -ForegroundColor Cyan
}

function Patch-Preload([string]$AppDir) {
  $preload = Join-Path $AppDir ".vite\build\preload.js"
  if (-not (Test-Path $preload)) { return }
  $raw = Get-Content -Raw $preload
  $processExpose = 'const P={env:process.env,platform:process.platform,versions:process.versions,arch:process.arch,cwd:()=>process.env.PWD,argv:process.argv,pid:process.pid};n.contextBridge.exposeInMainWorld("process",P);'
  if ($raw -notlike "*$processExpose*") {
    $re = 'n\.contextBridge\.exposeInMainWorld\("codexWindowType",[A-Za-z0-9_$]+\);n\.contextBridge\.exposeInMainWorld\("electronBridge",[A-Za-z0-9_$]+\);'
    $m = [regex]::Match($raw, $re)
    if (-not $m.Success) { throw "preload patch point not found." }
    $raw = $raw.Replace($m.Value, "$processExpose$m")
    Set-Content -NoNewline -Path $preload -Value $raw
  }
}

function Patch-MainSqliteFallback([string]$AppDir) {
  $mainDir = Join-Path $AppDir ".vite\build"
  if (-not (Test-Path $mainDir)) { return }
  $mainFiles = Get-ChildItem -Path $mainDir -Filter "main-*.js" -File -ErrorAction SilentlyContinue
  if (-not $mainFiles) { return }

  foreach ($mainFile in $mainFiles) {
    $raw = Get-Content -Raw $mainFile.FullName
    if ($raw -like "*better-sqlite3 unavailable; automations db disabled*") { continue }
    if ($raw -notlike "*if(!process.versions.electron)return null*") { continue }
    if ($raw -notlike '*join(n,"sqlite")*') { continue }

    $pattern = 'function (?<fn>[A-Za-z0-9_$]+)\(t\)\{if\(!process\.versions\.electron\)return null;if\((?<cache>[A-Za-z0-9_$]+)\)return \k<cache>;const e=(?<req>[A-Za-z0-9_$]+)\(\),n=(?<pathFn>[A-Za-z0-9_$]+)\(\{\}\),r=(?<pathObj>[A-Za-z0-9_$]+)\.join\(n,"sqlite"\);(?<fsObj>[A-Za-z0-9_$]+)\.mkdirSync\(r,\{recursive:!0\}\);const i=(?<dbNameFn>[A-Za-z0-9_$]+)\(\),a=\k<pathObj>\.join\(r,i\),o=new e\(a\);return (?<initFn>[A-Za-z0-9_$]+)\(o\),\k<cache>=o,o\}'
    $replacement = {
      param($m)
      $fn = $m.Groups['fn'].Value
      $cache = $m.Groups['cache'].Value
      $req = $m.Groups['req'].Value
      $pathFn = $m.Groups['pathFn'].Value
      $pathObj = $m.Groups['pathObj'].Value
      $fsObj = $m.Groups['fsObj'].Value
      $dbNameFn = $m.Groups['dbNameFn'].Value
      $initFn = $m.Groups['initFn'].Value
      return "function $fn(t){if(!process.versions.electron)return null;if($cache===!1)return null;if($cache)return $cache;try{const e=$req(),n=$pathFn({}),r=$pathObj.join(n,""sqlite"");$fsObj.mkdirSync(r,{recursive:!0});const i=$dbNameFn(),a=$pathObj.join(r,i),o=new e(a);return $initFn(o),$cache=o,o}catch(e){return console.warn(""better-sqlite3 unavailable; automations db disabled"",(e&&e.message)?e.message:e),$cache=!1,null}}"
    }

    $patched = [regex]::Replace($raw, $pattern, [System.Text.RegularExpressions.MatchEvaluator]$replacement, 1)
    if ($patched -ne $raw) {
      Set-Content -NoNewline -Path $mainFile.FullName -Value $patched
    }
  }
}

function Patch-MainCliCompat([string]$AppDir) {
  $mainDir = Join-Path $AppDir ".vite\build"
  if (-not (Test-Path $mainDir)) { return }
  $mainFile = Get-ChildItem -Path $mainDir -Filter "main-*.js" -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $mainFile) { return }

  $raw = Get-Content -Raw $mainFile.FullName
  if ($raw -notlike "*--analytics-default-enabled*") { return }
  $old = 'args:["app-server","--analytics-default-enabled"]'
  $new = 'args:["app-server"]'
  if ($raw.Contains($old)) {
    $raw = $raw.Replace($old, $new)
    Set-Content -NoNewline -Path $mainFile.FullName -Value $raw
    return
  }
}

function Patch-MainWslBackend([string]$AppDir) {
  $mainDir = Join-Path $AppDir ".vite\build"
  if (-not (Test-Path $mainDir)) { return }
  $mainFile = Get-ChildItem -Path $mainDir -Filter "main-*.js" -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $mainFile) { return }

  $distro = Resolve-WslDefaultDistro
  $linuxCodex = Resolve-WslCodexPath $distro
  if (-not $distro -or -not $linuxCodex) { return }

  $raw = Get-Content -Raw $mainFile.FullName
  $distroEsc = Escape-JsString $distro
  $wslCmd = 'export NVM_DIR=$HOME/.nvm; [ -s $NVM_DIR/nvm.sh ] && . $NVM_DIR/nvm.sh; codex app-server'
  $wslCmdEsc = Escape-JsString $wslCmd
  $new = "function bue(t){const e=t.hostConfig.codex_cli_command;if(e&&e.length>0){const[r,...i]=e;return!r||r.trim().length===0?null:{executablePath:r,args:i}}return{executablePath:`"C:/Windows/System32/wsl.exe`",args:[`"-d`",`"$distroEsc`",`"--exec`",`"/usr/bin/env`",`"bash`",`"-lc`",`"$wslCmdEsc`"],binDirectory:null}}"

  $pattern = 'function bue\(t\)\{const e=t\.hostConfig\.codex_cli_command;if\(e&&e\.length>0\)\{const\[r,\.\.\.i\]=e;return!r\|\|r\.trim\(\)\.length===0\?null:\{executablePath:r,args:i\}\}(?:const n=VB\(t\.repoRoot\);return n\?\{executablePath:n\.executablePath,args:\["app-server"\],binDirectory:n\.binDirectory\}:null|return\{executablePath:"C:\\\\Windows\\\\System32\\\\wsl\.exe",args:\[[^\]]*\],binDirectory:null\})\}'
  $replaced = [regex]::Replace($raw, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $new }, 1)
  if ($replaced -ne $raw) {
    Set-Content -NoNewline -Path $mainFile.FullName -Value $replaced
    return
  }
}


function Ensure-GitOnPath() {
  $candidates = @(
    (Join-Path $env:ProgramFiles "Git\cmd\git.exe"),
    (Join-Path $env:ProgramFiles "Git\bin\git.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Git\cmd\git.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Git\bin\git.exe")
  ) | Where-Object { $_ -and (Test-Path $_) }
  if (-not $candidates -or $candidates.Count -eq 0) { return }
  $gitDir = Split-Path $candidates[0] -Parent
  if ($env:PATH -notlike "*$gitDir*") {
    $env:PATH = "$gitDir;$env:PATH"
  }
}

function Ensure-ElectronRuntime([string]$BaseDir, [string]$ElectronVersion) {
  # Keep launch runtime separate from native-build workspace so build-time lock/corruption
  # in native modules does not break GUI startup.
  if (-not $BaseDir) { throw "WorkDir is required for Electron runtime." }
  if (-not $ElectronVersion) { throw "Electron version is required for Electron runtime." }

  $runtimeDir = Join-Path $BaseDir "electron-runtime"
  New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null

  $runtimeExe = Join-Path $runtimeDir "node_modules\electron\dist\electron.exe"
  $runtimeIcu = Join-Path $runtimeDir "node_modules\electron\dist\icudtl.dat"

  $runtimeReady = (Test-Path $runtimeExe) -and (Test-Path $runtimeIcu)
  if (-not $runtimeReady) {
    Push-Location $runtimeDir
    try {
      if (-not (Test-Path (Join-Path $runtimeDir "package.json"))) {
        & $npmCmd init -y | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "npm init failed for Electron runtime workspace." }
      }

      $electronPkg = Join-Path $runtimeDir "node_modules\electron"
      if (Test-Path $electronPkg) {
        Remove-Item -Recurse -Force $electronPkg -ErrorAction SilentlyContinue
      }

      & $npmCmd install --no-save "electron@$ElectronVersion" | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "npm install electron@$ElectronVersion failed." }
    } finally {
      Pop-Location
    }
  }

  if (-not (Test-Path $runtimeExe) -or -not (Test-Path $runtimeIcu)) {
    throw "Electron runtime is unavailable or incomplete at $runtimeDir."
  }

  return $runtimeExe
}

function Stop-LockingNativeElectronProcesses([string]$NativeDir) {
  if (-not $NativeDir) { return 0 }
  # Only kill Electron instances launched from the native-build workspace.
  # This avoids terminating unrelated desktop apps while removing EBUSY lock holders.
  $killed = 0
  $nativePrefix = $NativeDir.ToLowerInvariant()
  try {
    $procs = Get-Process -Name "electron" -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
      $path = $null
      try { $path = $p.Path } catch { $path = $null }
      if (-not $path) { continue }
      $lower = $path.ToLowerInvariant()
      if ($lower -like "$nativePrefix*") {
        try {
          Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
          $killed++
        } catch {}
      }
    }
  } catch {}
  return $killed
}

function Stop-RuntimeElectronProcesses([string]$RuntimeExePath) {
  if (-not $RuntimeExePath) { return 0 }
  $killed = 0
  $target = $RuntimeExePath.ToLowerInvariant()
  try {
    $procs = Get-Process -Name "electron" -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
      $path = $null
      try { $path = $p.Path } catch { $path = $null }
      if (-not $path) { continue }
      $normalized = $path.ToLowerInvariant()
      if ($normalized -eq $target) {
        try {
          Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
          $killed++
        } catch {}
      }
    }
  } catch {}
  return $killed
}

Ensure-Command node
$npmCmd = Join-Path $env:ProgramFiles "nodejs\npm.cmd"
if (-not (Test-Path $npmCmd)) {
  throw "npm.cmd not found at $npmCmd"
}

$npxCmd = Join-Path $env:ProgramFiles "nodejs\npx.cmd"
if (-not (Test-Path $npxCmd)) {
  throw "npx.cmd not found at $npxCmd"
}

foreach ($k in @("npm_config_runtime","npm_config_target","npm_config_disturl","npm_config_arch","npm_config_build_from_source")) {
  if (Test-Path "Env:$k") { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
}

if (-not $DmgPath) {
  $default = Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..")) "Codex.dmg"
  if (Test-Path $default) {
    $DmgPath = $default
  } else {
    $cand = Get-ChildItem -Path (Resolve-Path (Join-Path $PSScriptRoot "..")) -Filter "*.dmg" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cand) {
      $DmgPath = $cand.FullName
    } else {
      throw "No DMG found."
    }
  }
}

$DmgPath = (Resolve-Path $DmgPath).Path
$WorkDir = (Resolve-Path (New-Item -ItemType Directory -Force -Path $WorkDir)).Path

$sevenZip = Resolve-7z $WorkDir
if (-not $sevenZip) { throw "7z not found." }

$extractedDir = Join-Path $WorkDir "extracted"
$electronDir  = Join-Path $WorkDir "electron"
$appDir       = Join-Path $WorkDir "app"
$nativeDir    = Join-Path $WorkDir "native-builds"
$userDataDir  = Join-Path $WorkDir "userdata"
$cacheDir     = Join-Path $WorkDir "cache"
$repoRoot     = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$launchLogsDir = Join-Path $repoRoot "logs\runtime"

if (-not $Reuse) {
  Write-Header "Extracting DMG"
  New-Item -ItemType Directory -Force -Path $extractedDir | Out-Null
  & $sevenZip x -y $DmgPath -o"$extractedDir" | Out-Null

  Write-Header "Extracting app.asar"
  New-Item -ItemType Directory -Force -Path $electronDir | Out-Null
  $hfs = Join-Path $extractedDir "4.hfs"
  if (Test-Path $hfs) {
    & $sevenZip x -y $hfs "Codex Installer/Codex.app/Contents/Resources/app.asar" "Codex Installer/Codex.app/Contents/Resources/app.asar.unpacked" -o"$electronDir" | Out-Null
  } else {
    $directApp = Join-Path $extractedDir "Codex Installer\Codex.app\Contents\Resources\app.asar"
    if (-not (Test-Path $directApp)) {
      throw "app.asar not found."
    }
    $directUnpacked = Join-Path $extractedDir "Codex Installer\Codex.app\Contents\Resources\app.asar.unpacked"
    New-Item -ItemType Directory -Force -Path (Split-Path $directApp -Parent) | Out-Null
    $destBase = Join-Path $electronDir "Codex Installer\Codex.app\Contents\Resources"
    New-Item -ItemType Directory -Force -Path $destBase | Out-Null
    Copy-Item -Force $directApp (Join-Path $destBase "app.asar")
    if (Test-Path $directUnpacked) {
      & robocopy $directUnpacked (Join-Path $destBase "app.asar.unpacked") /E /NFL /NDL /NJH /NJS /NC /NS | Out-Null
    }
  }

  Write-Header "Unpacking app.asar"
  New-Item -ItemType Directory -Force -Path $appDir | Out-Null
  $asar = Join-Path $electronDir "Codex Installer\Codex.app\Contents\Resources\app.asar"
  if (-not (Test-Path $asar)) { throw "app.asar not found." }
  & $npxCmd --yes @electron/asar extract $asar $appDir

  Write-Header "Syncing app.asar.unpacked"
  $unpacked = Join-Path $electronDir "Codex Installer\Codex.app\Contents\Resources\app.asar.unpacked"
  if (Test-Path $unpacked) {
    & robocopy $unpacked $appDir /E /NFL /NDL /NJH /NJS /NC /NS | Out-Null
  }
}

Write-Header "Patching preload"
Patch-Preload $appDir
Patch-MainSqliteFallback $appDir
Patch-MainCliCompat $appDir
# WSL backend patching is opt-in only. Native Windows CLI path is the safe default.
if ($env:CODEX_FORCE_WSL_BACKEND -eq "1") { Patch-MainWslBackend $appDir }

Write-Header "Reading app metadata"
$pkgPath = Join-Path $appDir "package.json"
if (-not (Test-Path $pkgPath)) { throw "package.json not found." }
$pkg = Get-Content -Raw $pkgPath | ConvertFrom-Json
$electronVersion = $pkg.devDependencies.electron
$betterVersion = $pkg.dependencies."better-sqlite3"
$ptyVersion = $pkg.dependencies."node-pty"

if (-not $electronVersion) { throw "Electron version not found." }

Write-Header "Preparing native modules"
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "win32-arm64" } else { "win32-x64" }
$bsDst = Join-Path $appDir "node_modules\better-sqlite3\build\Release\better_sqlite3.node"
$ptyDstPre = Join-Path $appDir "node_modules\node-pty\prebuilds\$arch"
$skipNative = $NoLaunch -and $Reuse -and (Test-Path $bsDst) -and (Test-Path (Join-Path $ptyDstPre "pty.node"))
if ($skipNative) {
  Write-Host "Native modules already present in app. Skipping rebuild." -ForegroundColor Cyan
} else {
New-Item -ItemType Directory -Force -Path $nativeDir | Out-Null
Push-Location $nativeDir
if (-not (Test-Path (Join-Path $nativeDir "package.json"))) {
  & $npmCmd init -y | Out-Null
}

$bsSrcProbe = Join-Path $nativeDir "node_modules\better-sqlite3\build\Release\better_sqlite3.node"
$ptySrcProbe = Join-Path $nativeDir "node_modules\node-pty\prebuilds\$arch\pty.node"
$electronExe = Join-Path $nativeDir "node_modules\electron\dist\electron.exe"
$haveNative = (Test-Path $bsSrcProbe) -and (Test-Path $ptySrcProbe) -and (Test-Path $electronExe)

if (-not $haveNative) {
  $deps = @(
    "better-sqlite3@$betterVersion",
    "node-pty@$ptyVersion",
    "@electron/rebuild",
    "prebuild-install"
  )

  $installSucceeded = $false
  $installEndedWithBusyLock = $false
  $installAttempts = 3
  # Proactively clear stale native electron.exe instances that commonly lock
  # v8_context_snapshot.bin during npm rename operations.
  $killedBeforeInstall = Stop-LockingNativeElectronProcesses $nativeDir
  if ($killedBeforeInstall -gt 0) {
    Write-Host "Stopped $killedBeforeInstall stale native Electron process(es) before npm install." -ForegroundColor Yellow
    Start-Sleep -Milliseconds 600
  }
  for ($attempt = 1; $attempt -le $installAttempts; $attempt++) {
    Write-Host "Installing native dependencies (attempt $attempt/$installAttempts)..." -ForegroundColor Cyan
    # Avoid stale electron package lock contention between retries/runs.
    $electronPkg = Join-Path $nativeDir "node_modules\electron"
    if (Test-Path $electronPkg) {
      Remove-Item -Recurse -Force $electronPkg -ErrorAction SilentlyContinue
    }
    $nodeModulesDir = Join-Path $nativeDir "node_modules"
    if (Test-Path $nodeModulesDir) {
      Get-ChildItem -Path $nodeModulesDir -Filter ".electron-*" -Directory -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    $installOutput = @()
    $installExit = 1
    $prevNativeErrorPref = $null
    $hasNativePref = $null -ne (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue)
    $prevErrorActionPref = $ErrorActionPreference
    if ($hasNativePref) {
      $prevNativeErrorPref = $PSNativeCommandUseErrorActionPreference
      $PSNativeCommandUseErrorActionPreference = $false
    }
    try {
      # npm emits many expected stderr lines; keep them as output and decide by exit code.
      $ErrorActionPreference = "Continue"
      $installOutput = & $npmCmd install --no-save @deps 2>&1
      $installExit = $LASTEXITCODE
    } catch {
      $installOutput += $_
      $installExit = if ($LASTEXITCODE) { $LASTEXITCODE } else { 1 }
    } finally {
      $ErrorActionPreference = $prevErrorActionPref
      if ($hasNativePref) {
        $PSNativeCommandUseErrorActionPreference = $prevNativeErrorPref
      }
    }
    $installOutput | ForEach-Object { Write-Host $_ }

    if ($installExit -eq 0) {
      $installSucceeded = $true
      break
    }

    $installText = ($installOutput | Out-String)
    $isBusyLock = $installText -match "EBUSY|resource busy or locked"
    $installEndedWithBusyLock = $isBusyLock
    if ($attempt -lt $installAttempts -and $isBusyLock) {
      Write-Host "Detected file lock during npm install (EBUSY). Cleaning stale Electron temp dirs and retrying..." -ForegroundColor Yellow
      # Retry path: clear any lock holder that started between attempts.
      $killedDuringRetry = Stop-LockingNativeElectronProcesses $nativeDir
      if ($killedDuringRetry -gt 0) {
        Write-Host "Stopped $killedDuringRetry stale native Electron process(es) after lock detection." -ForegroundColor Yellow
      }
      Start-Sleep -Seconds (2 * $attempt)
      continue
    }

    if ($attempt -eq $installAttempts -and $isBusyLock) {
      Write-Host "Persistent EBUSY lock after retries. Continuing without native-build workspace refresh." -ForegroundColor Yellow
      break
    }

    throw "npm install failed."
  }

  if (-not $installSucceeded) {
    if ($installEndedWithBusyLock) {
      Write-Host "Native dependency install skipped due file locks; proceeding with available binaries." -ForegroundColor Yellow
    } else {
      throw "npm install failed after retries. Close running Codex/Electron/Node processes and try again."
    }
  }
} else {
  Write-Host "Native modules already present. Skipping rebuild." -ForegroundColor Cyan
}

Write-Host "Rebuilding native modules for Electron $electronVersion..." -ForegroundColor Cyan
$rebuildOk = $true
if (-not $haveNative) {
  try {
    $rebuildCli = Join-Path $nativeDir "node_modules\@electron\rebuild\lib\cli.js"
    if (-not (Test-Path $rebuildCli)) { throw "electron-rebuild not found." }
    & node $rebuildCli -v $electronVersion -w "better-sqlite3,node-pty" | Out-Null
  } catch {
    $rebuildOk = $false
    Write-Host "electron-rebuild failed: $($_.Exception.Message)" -ForegroundColor Yellow
  }
}

if (-not $rebuildOk -and -not $haveNative) {
  Write-Host "Trying prebuilt Electron binaries for better-sqlite3..." -ForegroundColor Yellow
  $bsDir = Join-Path $nativeDir "node_modules\better-sqlite3"
  if (Test-Path $bsDir) {
    Push-Location $bsDir
    $prebuildCli = Join-Path $nativeDir "node_modules\prebuild-install\bin.js"
    if (-not (Test-Path $prebuildCli)) { throw "prebuild-install not found." }
    & node $prebuildCli -r electron -t $electronVersion --tag-prefix=electron-v | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-Host "prebuild-install did not find a compatible better-sqlite3 binary." -ForegroundColor Yellow
    }
    Pop-Location
  }
}

$electronExe = Join-Path $nativeDir "node_modules\electron\dist\electron.exe"
$canVerifyBetterSqlite = Test-Path $electronExe
if (-not $canVerifyBetterSqlite) {
  Write-Host "electron.exe not found in native-build workspace. Skipping better-sqlite runtime verification." -ForegroundColor Yellow
}
$bsSrc = Join-Path $nativeDir "node_modules\better-sqlite3\build\Release\better_sqlite3.node"
$betterSqliteReady = $false
if (Test-Path (Join-Path $nativeDir "node_modules\better-sqlite3")) {
  if (-not $canVerifyBetterSqlite) {
    if (Test-Path $bsSrc) {
      $betterSqliteReady = $true
    } else {
      Write-Host "better-sqlite3 binary missing and runtime verification unavailable. Continuing without it." -ForegroundColor Yellow
    }
  } else {
  $env:ELECTRON_RUN_AS_NODE = "1"
  & $electronExe -e "try{require('./node_modules/better-sqlite3');process.exit(0)}catch(e){console.error(e);process.exit(1)}" | Out-Null
  Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
  if ($LASTEXITCODE -eq 0 -and (Test-Path $bsSrc)) {
    $betterSqliteReady = $true
  } else {
    Write-Host "better-sqlite3 is unavailable (build tools/prebuilt binary missing). Continuing without it." -ForegroundColor Yellow
  }
  }
} else {
  Write-Host "better-sqlite3 not installed. Continuing without it." -ForegroundColor Yellow
}

Pop-Location

$bsDstDir = Split-Path $bsDst -Parent
New-Item -ItemType Directory -Force -Path $bsDstDir | Out-Null
if ($betterSqliteReady) {
  Copy-Item -Force $bsSrc (Join-Path $bsDstDir "better_sqlite3.node")
} elseif (Test-Path $bsDst) {
  Remove-Item -Force $bsDst -ErrorAction SilentlyContinue
}

$ptySrcDir = Join-Path $nativeDir "node_modules\node-pty\prebuilds\$arch"
$ptyDstRel = Join-Path $appDir "node_modules\node-pty\build\Release"
New-Item -ItemType Directory -Force -Path $ptyDstPre | Out-Null
New-Item -ItemType Directory -Force -Path $ptyDstRel | Out-Null

$ptyFiles = @("pty.node", "conpty.node", "conpty_console_list.node")
foreach ($f in $ptyFiles) {
  $src = Join-Path $ptySrcDir $f
  if (Test-Path $src) {
    Copy-Item -Force $src (Join-Path $ptyDstPre $f)
    Copy-Item -Force $src (Join-Path $ptyDstRel $f)
  }
}
}

if (-not $NoLaunch) {
  Write-Header "Resolving Codex CLI"
  $cli = $null
  if ($CodexCliPath) {
    $cli = Resolve-CodexCliPath $CodexCliPath
  } else {
    $cli = Ensure-LocalCodexCli $WorkDir
    if (-not $cli) {
      if ($env:CODEX_CLI_PATH) {
        $cli = Resolve-CodexCliPath $env:CODEX_CLI_PATH
      }
      if (-not $cli) {
        $cli = Resolve-CodexCliPath $null
      }
    }
  }
  if (-not $cli) {
    throw "codex.exe not found."
  }
  Write-Host "Using Codex CLI: $cli" -ForegroundColor Cyan

  Write-Header "Launching Codex"
  $rendererUrl = (New-Object System.Uri (Join-Path $appDir "webview\index.html")).AbsoluteUri
  Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
  $env:ELECTRON_RENDERER_URL = $rendererUrl
  $env:ELECTRON_FORCE_IS_PACKAGED = "1"
  $buildNumber = if ($pkg.PSObject.Properties.Name -contains "codexBuildNumber" -and $pkg.codexBuildNumber) { $pkg.codexBuildNumber } else { "510" }
  $buildFlavor = if ($pkg.PSObject.Properties.Name -contains "codexBuildFlavor" -and $pkg.codexBuildFlavor) { $pkg.codexBuildFlavor } else { "prod" }
  $env:CODEX_BUILD_NUMBER = $buildNumber
  $env:CODEX_BUILD_FLAVOR = $buildFlavor
  $env:BUILD_FLAVOR = $buildFlavor
  $env:NODE_ENV = "production"
  $env:CODEX_CLI_PATH = $cli
  $env:PWD = $appDir
  Ensure-GitOnPath

  New-Item -ItemType Directory -Force -Path $userDataDir | Out-Null
  New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
  New-Item -ItemType Directory -Force -Path $launchLogsDir | Out-Null

  # Always launch with validated runtime Electron from work/electron-runtime.
  # This prevents immediate startup crashes caused by a broken native-build electron install.
  $runtimeElectronExe = Ensure-ElectronRuntime $WorkDir $electronVersion
  $runtimeExeResolved = (Resolve-Path $runtimeElectronExe).Path.ToLowerInvariant()

  # Relaunch behavior: close previous runtime electron.exe instances first, then
  # launch a fresh instance so build+launch always opens the app predictably.
  $stoppedRuntime = Stop-RuntimeElectronProcesses $runtimeExeResolved
  if ($stoppedRuntime -gt 0) {
    Write-Host "Stopped $stoppedRuntime existing Codex runtime process(es) before relaunch." -ForegroundColor Yellow
    Start-Sleep -Milliseconds 700
  }

  $launchStamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
  $stdoutLogPath = Join-Path $launchLogsDir ("codex-stdout-" + $launchStamp + ".log")
  $stderrLogPath = Join-Path $launchLogsDir ("codex-stderr-" + $launchStamp + ".log")
  $chromeLogPath = Join-Path $launchLogsDir ("codex-chromium-" + $launchStamp + ".log")
  $launchCacheDir = Join-Path $cacheDir ("run-" + (Get-Date -Format "yyyyMMdd-HHmmss-fff"))
  New-Item -ItemType Directory -Force -Path $launchCacheDir | Out-Null

  $env:ELECTRON_ENABLE_LOGGING = "1"
  $env:ELECTRON_LOG_FILE = $chromeLogPath
  $electronArgs = @(
    $appDir,
    "--enable-logging",
    "--log-file=`"$chromeLogPath`"",
    "--user-data-dir=`"$userDataDir`"",
    "--disk-cache-dir=`"$launchCacheDir`""
  )
  $appProc = Start-Process -FilePath $runtimeElectronExe -ArgumentList $electronArgs -PassThru -RedirectStandardOutput $stdoutLogPath -RedirectStandardError $stderrLogPath
  if (-not $appProc -or -not $appProc.Id) {
    throw "Failed to launch Codex Electron process."
  }
  Write-Host "Codex launched (PID: $($appProc.Id))." -ForegroundColor Green
  Write-Host "Runtime logs:" -ForegroundColor DarkGray
  Write-Host "  stdout: $stdoutLogPath" -ForegroundColor DarkGray
  Write-Host "  stderr: $stderrLogPath" -ForegroundColor DarkGray
  Write-Host "  chromium: $chromeLogPath" -ForegroundColor DarkGray
  Start-Sleep -Milliseconds 1500
  try {
    $stillRunning = Get-Process -Id $appProc.Id -ErrorAction SilentlyContinue
    if (-not $stillRunning) {
      Write-Host "Codex process exited immediately after launch. See runtime logs above." -ForegroundColor Yellow
      throw "Codex exited immediately after launch."
    }
  } catch {
    if ($_.Exception.Message -like "Codex exited immediately after launch.*") { throw }
  }
}
