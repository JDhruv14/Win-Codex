param(
  [string]$DmgPath,
  [string]$WorkDir = (Join-Path $PSScriptRoot "..\work"),
  [string]$CodexCliPath,
  [switch]$Reuse,
  [switch]$NoLaunch,
  [switch]$BuildExe
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
    Write-Host "7-Zip not found. Trying to install with winget..." -ForegroundColor Yellow
    try {
      & winget install --id 7zip.7zip -e --source winget --accept-package-agreements --accept-source-agreements --silent | Out-Null
    } catch {}
    if (Test-Path $p1) { return $p1 }
    if (Test-Path $p2) { return $p2 }
    $cmd = Get-Command 7z -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Path }
  }

  throw @"
7z not found.
Install 7-Zip with:
  winget install --id 7zip.7zip -e
If winget is unavailable, install 7-Zip manually and rerun this script.
"@
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
    $npmRoot = (& npm root -g 2>$null).Trim()
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

function Patch-MainForPortable([string]$AppDir, [string]$BuildNumber, [string]$BuildFlavor) {
  $mainJs = Join-Path $AppDir ".vite\build\main.js"
  if (-not (Test-Path $mainJs)) { return }
  $raw = Get-Content -Raw $mainJs
  $marker = "/* CODEX-PORTABLE-SHIM */"
  if ($raw -like "*$marker*") { return }
  $shim = @"
/* CODEX-PORTABLE-SHIM */
(function(){
  const path=require("node:path"),url=require("node:url");
  if(!process.env.ELECTRON_RENDERER_URL){
    const webview=path.join(__dirname,"..","..","webview","index.html");
    try{require("node:fs").accessSync(webview)}catch(e){
      const res=process.resourcesPath||path.join(__dirname,"..","..","..");
      const alt=path.join(res,"app","webview","index.html");
      try{require("node:fs").accessSync(alt);process.env.ELECTRON_RENDERER_URL=url.pathToFileURL(alt).toString()}catch(e2){}
    }
    if(!process.env.ELECTRON_RENDERER_URL){
      process.env.ELECTRON_RENDERER_URL=url.pathToFileURL(webview).toString();
    }
  }
  if(!process.env.ELECTRON_FORCE_IS_PACKAGED)process.env.ELECTRON_FORCE_IS_PACKAGED="1";
  if(!process.env.CODEX_BUILD_NUMBER)process.env.CODEX_BUILD_NUMBER="$BuildNumber";
  if(!process.env.CODEX_BUILD_FLAVOR)process.env.CODEX_BUILD_FLAVOR="$BuildFlavor";
  if(!process.env.BUILD_FLAVOR)process.env.BUILD_FLAVOR="$BuildFlavor";
  if(!process.env.NODE_ENV)process.env.NODE_ENV="production";
  if(!process.env.PWD)process.env.PWD=process.cwd();
})();
"@
  $raw = $shim + "`n" + $raw
  Set-Content -NoNewline -Path $mainJs -Value $raw
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

Ensure-Command node
Ensure-Command npm
Ensure-Command npx

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
if (-not $sevenZip) {
  throw @"
7z not found.
Install 7-Zip with:
  winget install --id 7zip.7zip -e
If winget is unavailable, install 7-Zip manually and rerun this script.
"@
}

$extractedDir = Join-Path $WorkDir "extracted"
$electronDir  = Join-Path $WorkDir "electron"
$appDir       = Join-Path $WorkDir "app"
$nativeDir    = Join-Path $WorkDir "native-builds"
$packagedDir  = Join-Path $WorkDir "packaged"
$userDataDir  = Join-Path $WorkDir "userdata"
$cacheDir     = Join-Path $WorkDir "cache"

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
  & npx --yes @electron/asar extract $asar $appDir

  Write-Header "Syncing app.asar.unpacked"
  $unpacked = Join-Path $electronDir "Codex Installer\Codex.app\Contents\Resources\app.asar.unpacked"
  if (Test-Path $unpacked) {
    & robocopy $unpacked $appDir /E /NFL /NDL /NJH /NJS /NC /NS | Out-Null
  }
}

Write-Header "Patching preload"
Patch-Preload $appDir

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
  & npm init -y | Out-Null
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
    "prebuild-install",
    "electron@$electronVersion"
  )
  & npm install --no-save @deps
  if ($LASTEXITCODE -ne 0) { throw "npm install failed." }
  $electronExe = Join-Path $nativeDir "node_modules\electron\dist\electron.exe"
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
  $prebuildCli = Join-Path $nativeDir "node_modules\prebuild-install\bin.js"
  if (-not (Test-Path $prebuildCli)) { throw "prebuild-install not found." }
  Write-Host "Trying prebuilt Electron binaries for better-sqlite3..." -ForegroundColor Yellow
  $bsDir = Join-Path $nativeDir "node_modules\better-sqlite3"
  if (Test-Path $bsDir) {
    Push-Location $bsDir
    & node $prebuildCli -r electron -t $electronVersion --tag-prefix=electron-v | Out-Null
    Pop-Location
  }
  Write-Host "Trying prebuilt Electron binaries for node-pty..." -ForegroundColor Yellow
  $ptyDir = Join-Path $nativeDir "node_modules\node-pty"
  if (Test-Path $ptyDir) {
    Push-Location $ptyDir
    & node $prebuildCli -r electron -t $electronVersion --tag-prefix=electron-v 2>$null | Out-Null
    Pop-Location
  }
}

$env:ELECTRON_RUN_AS_NODE = "1"
if (-not (Test-Path $electronExe)) { throw "electron.exe not found." }
if (-not (Test-Path (Join-Path $nativeDir "node_modules\better-sqlite3"))) {
  throw "better-sqlite3 not installed."
}
& $electronExe -e "try{require('./node_modules/better-sqlite3');process.exit(0)}catch(e){console.error(e);process.exit(1)}" | Out-Null
Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
if ($LASTEXITCODE -ne 0) { throw "better-sqlite3 failed to load." }

Pop-Location

$bsSrc = Join-Path $nativeDir "node_modules\better-sqlite3\build\Release\better_sqlite3.node"
if (-not (Test-Path $bsSrc)) {
  $bsPrebuildDir = Join-Path $nativeDir "node_modules\better-sqlite3\prebuilds\$arch"
  $bsPrebuild = Get-ChildItem -Path $bsPrebuildDir -Filter "better_sqlite3.node" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($bsPrebuild) { $bsSrc = $bsPrebuild.FullName }
}
$bsDstDir = Split-Path $bsDst -Parent
New-Item -ItemType Directory -Force -Path $bsDstDir | Out-Null
if (-not (Test-Path $bsSrc)) { throw "better_sqlite3.node not found (rebuild failed; install Visual Studio Build Tools or use a machine with prebuilds)." }
Copy-Item -Force $bsSrc (Join-Path $bsDstDir "better_sqlite3.node")

$ptySrcDir = Join-Path $nativeDir "node_modules\node-pty\prebuilds\$arch"
if (-not (Test-Path (Join-Path $ptySrcDir "pty.node"))) {
  $ptyPrebuildDir = Join-Path $nativeDir "node_modules\node-pty\prebuilds"
  $found = Get-ChildItem -Path $ptyPrebuildDir -Filter "pty.node" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($found) { $ptySrcDir = Split-Path $found.FullName -Parent }
}
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

$packagedExe = $null
if ($BuildExe) {
  Write-Header "Packaging Codex.exe"
  $packagerArch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
  $electronDistDir = Join-Path $nativeDir "node_modules\electron\dist"
  if (-not (Test-Path $electronDistDir)) { throw "Electron dist not found for packaging." }

  $outputDir = Join-Path $packagedDir "Codex-win32-$packagerArch"
  if (Test-Path $outputDir) { Remove-Item -Recurse -Force $outputDir }
  New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

  Write-Host "Copying Electron runtime..." -ForegroundColor Cyan
  & robocopy $electronDistDir $outputDir /E /NFL /NDL /NJH /NJS /NC /NS | Out-Null

  $srcExe = Join-Path $outputDir "electron.exe"
  $dstExe = Join-Path $outputDir "Codex.exe"
  if (Test-Path $srcExe) {
    Rename-Item -Path $srcExe -NewName "Codex.exe"
  } elseif (-not (Test-Path $dstExe)) {
    throw "electron.exe not found in Electron dist."
  }

  Write-Host "Copying app files to resources\app..." -ForegroundColor Cyan
  $resourcesDir = Join-Path $outputDir "resources"
  New-Item -ItemType Directory -Force -Path $resourcesDir | Out-Null
  $appDstDir = Join-Path $resourcesDir "app"
  & robocopy $appDir $appDstDir /E /NFL /NDL /NJH /NJS /NC /NS | Out-Null
  # Remove default_app.asar so Electron loads our app/ directory
  $defaultAsar = Join-Path $resourcesDir "default_app.asar"
  if (Test-Path $defaultAsar) { Remove-Item -Force $defaultAsar }

  # Patch main.js so the app auto-configures env vars (portable mode)
  Write-Host "Patching main.js for portable mode..." -ForegroundColor Cyan
  $pBuildNumber = if ($pkg.PSObject.Properties.Name -contains "codexBuildNumber" -and $pkg.codexBuildNumber) { $pkg.codexBuildNumber } else { "510" }
  $pBuildFlavor = if ($pkg.PSObject.Properties.Name -contains "codexBuildFlavor" -and $pkg.codexBuildFlavor) { $pkg.codexBuildFlavor } else { "prod" }
  Patch-MainForPortable $appDstDir $pBuildNumber $pBuildFlavor

  # Bundle the Codex CLI binary into resources/ so the app finds it automatically
  Write-Header "Bundling Codex CLI"
  $cli = Resolve-CodexCliPath $CodexCliPath
  if (-not $cli) {
    throw "codex.exe not found. Install with: npm i -g @openai/codex"
  }
  $cliSrcDir = Split-Path $cli -Parent
  Copy-Item -Force $cli (Join-Path $resourcesDir "codex.exe")
  # Also copy sibling DLLs / support files the CLI may need
  $cliSiblings = Get-ChildItem -Path $cliSrcDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne (Split-Path $cli -Leaf) }
  foreach ($sf in $cliSiblings) {
    Copy-Item -Force $sf.FullName (Join-Path $resourcesDir $sf.Name)
  }
  Write-Host "Bundled CLI from: $cli" -ForegroundColor Cyan

  # Create a Desktop shortcut pointing to Codex.exe
  Write-Header "Creating Desktop shortcut"
  $desktopPath = [Environment]::GetFolderPath("Desktop")
  $shortcutPath = Join-Path $desktopPath "Codex.lnk"
  try {
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($shortcutPath)
    $sc.TargetPath = $dstExe
    $sc.WorkingDirectory = $outputDir
    $sc.Description = "Codex"
    $sc.Save()
    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($ws) | Out-Null
    Write-Host "Shortcut created: $shortcutPath" -ForegroundColor Cyan
  } catch {
    Write-Host "Could not create Desktop shortcut: $($_.Exception.Message)" -ForegroundColor Yellow
  }

  $packagedExe = $dstExe
  if (-not (Test-Path $packagedExe)) { throw "Packaged exe not found: $packagedExe" }
  Write-Host ""
  Write-Host "=============================================" -ForegroundColor Green
  Write-Host "  Codex packaged successfully!" -ForegroundColor Green
  Write-Host "  Output: $outputDir" -ForegroundColor Green
  Write-Host "" -ForegroundColor Green
  Write-Host "  A Desktop shortcut has been created." -ForegroundColor Green
  Write-Host "  Double-click 'Codex' on your Desktop to launch." -ForegroundColor Green
  Write-Host "" -ForegroundColor Green
  Write-Host "  IMPORTANT: Do NOT move Codex.exe by itself." -ForegroundColor Green
  Write-Host "  Move the ENTIRE folder if you want to relocate." -ForegroundColor Green
  Write-Host "=============================================" -ForegroundColor Green
}

if (-not $NoLaunch) {
  Write-Header "Resolving Codex CLI"
  if ($packagedExe) {
    $cli = Join-Path (Split-Path $packagedExe -Parent) "resources\codex.exe"
    if (-not (Test-Path $cli)) {
      $cli = Resolve-CodexCliPath $CodexCliPath
    }
  } else {
    $cli = Resolve-CodexCliPath $CodexCliPath
  }
  if (-not $cli) {
    throw "codex.exe not found."
  }

  Write-Header "Launching Codex"
  Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
  $env:ELECTRON_FORCE_IS_PACKAGED = "1"
  $buildNumber = if ($pkg.PSObject.Properties.Name -contains "codexBuildNumber" -and $pkg.codexBuildNumber) { $pkg.codexBuildNumber } else { "510" }
  $buildFlavor = if ($pkg.PSObject.Properties.Name -contains "codexBuildFlavor" -and $pkg.codexBuildFlavor) { $pkg.codexBuildFlavor } else { "prod" }
  $env:CODEX_BUILD_NUMBER = $buildNumber
  $env:CODEX_BUILD_FLAVOR = $buildFlavor
  $env:BUILD_FLAVOR = $buildFlavor
  $env:NODE_ENV = "production"
  $env:CODEX_CLI_PATH = $cli
  Ensure-GitOnPath

  if ($packagedExe) {
    Start-Process -FilePath $packagedExe -ArgumentList "--enable-logging" -NoNewWindow -Wait
  } else {
    $rendererUrl = (New-Object System.Uri (Join-Path $appDir "webview\index.html")).AbsoluteUri
    $env:ELECTRON_RENDERER_URL = $rendererUrl
    $env:PWD = $appDir
    New-Item -ItemType Directory -Force -Path $userDataDir | Out-Null
    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    Start-Process -FilePath $electronExe -ArgumentList "$appDir","--enable-logging","--user-data-dir=`"$userDataDir`"","--disk-cache-dir=`"$cacheDir`"" -NoNewWindow -Wait
  }
}
