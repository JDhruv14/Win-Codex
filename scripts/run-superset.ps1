param(
  [string]$DmgPath,
  [string]$WorkDir = (Join-Path $PSScriptRoot "..\work-superset"),
  [string]$ElectronVersion,
  [switch]$Reuse,
  [switch]$NoLaunch,
  [switch]$BuildExe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Utility helpers ──────────────────────────────────────────────────────────

function Ensure-Command([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "$Name not found. Please install it and try again."
  }
}

function Write-Header([string]$Text) {
  Write-Host "`n=== $Text ===" -ForegroundColor Cyan
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
  $szHome = "https://www.7-zip.org/"
  try { $html = (Invoke-WebRequest -Uri $szHome -UseBasicParsing).Content } catch { return $null }
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

# ── App & Electron discovery ─────────────────────────────────────────────────

function Find-AsarPath([string]$SearchRoot) {
  $found = Get-ChildItem -Path $SearchRoot -Filter "app.asar" -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -like "*Contents*Resources*" } |
    Select-Object -First 1
  if ($found) { return $found.FullName }

  $anyAsar = Get-ChildItem -Path $SearchRoot -Filter "app.asar" -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($anyAsar) { return $anyAsar.FullName }

  return $null
}

function Find-ElectronVersion([string]$ExtractedDir, [string]$PkgElectronVer) {
  if ($PkgElectronVer) { return $PkgElectronVer -replace '^\^','' }

  $plists = Get-ChildItem -Path $ExtractedDir -Filter "Info.plist" -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -like "*Electron Framework*" }
  foreach ($plist in $plists) {
    $content = Get-Content -Raw $plist.FullName
    $m = [regex]::Match($content, '<key>CFBundleVersion</key>\s*<string>([^<]+)</string>')
    if ($m.Success) { return $m.Groups[1].Value }
  }

  return $null
}

function Find-ExtraResources([string]$ExtractedDir) {
  $migrations = Get-ChildItem -Path $ExtractedDir -Filter "migrations" -Directory -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -like "*Resources*resources*migrations" -and $_.FullName -notlike "*app.asar*" } |
    Select-Object -First 1
  if ($migrations) { return (Split-Path $migrations.FullName -Parent) }
  return $null
}

# ── Patching ─────────────────────────────────────────────────────────────────

function Patch-MainForPortable([string]$AppDir) {
  $candidates = @(
    (Join-Path $AppDir "dist\main\index.js"),
    (Join-Path $AppDir ".vite\build\main.js")
  )
  $mainJs = $null
  foreach ($c in $candidates) {
    if (Test-Path $c) { $mainJs = $c; break }
  }
  if (-not $mainJs) {
    Write-Host "  main.js not found for patching (skipping)" -ForegroundColor Yellow
    return
  }

  $raw = Get-Content -Raw $mainJs
  $marker = "/* SUPERSET-PORTABLE-SHIM */"
  if ($raw -like "*$marker*") { return }

  $shim = @"
$marker
(function(){
  const path=require("node:path"),url=require("node:url"),fs=require("node:fs");
  if(!process.env.ELECTRON_FORCE_IS_PACKAGED)process.env.ELECTRON_FORCE_IS_PACKAGED="1";
  if(!process.env.NODE_ENV)process.env.NODE_ENV="production";
  if(!process.env.PWD)process.env.PWD=process.cwd();

  // Resolve renderer URL for portable mode
  if(!process.env.ELECTRON_RENDERER_URL){
    const candidates=[
      path.join(__dirname,"..","renderer","index.html"),
      path.join(__dirname,"..","..","dist","renderer","index.html"),
      path.join(process.resourcesPath||path.join(__dirname,"..","..",".."),
        "app","dist","renderer","index.html")
    ];
    for(const c of candidates){
      try{fs.accessSync(c);process.env.ELECTRON_RENDERER_URL=url.pathToFileURL(c).toString();break}catch(e){}
    }
  }
})();
"@
  $raw = $shim + "`n" + $raw
  Set-Content -NoNewline -Path $mainJs -Value $raw
  Write-Host "  Patched: $mainJs" -ForegroundColor Green
}

function Patch-PlatformReferences([string]$AppDir) {
  $candidates = @(
    (Join-Path $AppDir "dist\main\index.js"),
    (Join-Path $AppDir "dist\preload\index.js")
  )
  foreach ($file in $candidates) {
    if (-not (Test-Path $file)) { continue }
    $raw = Get-Content -Raw $file
    $patched = $false

    if ($raw -match '["'']\/bin\/zsh["'']' -and $raw -notlike "*SUPERSET-SHELL-PATCH*") {
      $raw = "/* SUPERSET-SHELL-PATCH */`n" +
        "if(!process.env.COMSPEC)process.env.COMSPEC=process.env.SystemRoot?process.env.SystemRoot+'\\System32\\cmd.exe':'C:\\Windows\\System32\\cmd.exe';`n" +
        $raw
      $patched = $true
    }

    if ($patched) {
      Set-Content -NoNewline -Path $file -Value $raw
      Write-Host "  Patched platform refs: $(Split-Path $file -Leaf)" -ForegroundColor Green
    }
  }
}

# ── Prerequisites ────────────────────────────────────────────────────────────

Ensure-Command node
Ensure-Command npm
Ensure-Command npx

foreach ($k in @("npm_config_runtime","npm_config_target","npm_config_disturl","npm_config_arch","npm_config_build_from_source")) {
  if (Test-Path "Env:$k") { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
}

# ── Resolve DMG ──────────────────────────────────────────────────────────────

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

if (-not $DmgPath) {
  $default = Join-Path $repoRoot "Superset.dmg"
  if (Test-Path $default) {
    $DmgPath = $default
  } else {
    $cand = Get-ChildItem -Path $repoRoot -Filter "Superset*.dmg" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cand) {
      $DmgPath = $cand.FullName
    } else {
      $cand2 = Get-ChildItem -Path $repoRoot -Filter "*.dmg" -File -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($cand2) {
        $DmgPath = $cand2.FullName
      } else {
        throw "No DMG found. Download the Superset DMG from https://github.com/superset-sh/superset/releases and place it in the repo root."
      }
    }
  }
}

$DmgPath = (Resolve-Path $DmgPath).Path
$WorkDir = (Resolve-Path (New-Item -ItemType Directory -Force -Path $WorkDir)).Path
Write-Host "DMG: $DmgPath" -ForegroundColor Green
Write-Host "Work directory: $WorkDir" -ForegroundColor Green

$sevenZip = Resolve-7z $WorkDir
if (-not $sevenZip) { throw "7-Zip not found and could not be installed." }

# ── Directory layout ─────────────────────────────────────────────────────────

$extractedDir = Join-Path $WorkDir "extracted"
$electronDir  = Join-Path $WorkDir "electron"
$appDir       = Join-Path $WorkDir "app"
$nativeDir    = Join-Path $WorkDir "native-builds"
$packagedDir  = Join-Path $WorkDir "packaged"
$userDataDir  = Join-Path $WorkDir "userdata"
$cacheDir     = Join-Path $WorkDir "cache"

# ── Extract DMG & app.asar ──────────────────────────────────────────────────

$extraResourcesDir = $null
if (-not $Reuse) {
  Write-Header "Extracting DMG"
  if (Test-Path $extractedDir) { Remove-Item -Recurse -Force $extractedDir }
  New-Item -ItemType Directory -Force -Path $extractedDir | Out-Null
  & $sevenZip x -y $DmgPath -o"$extractedDir" | Out-Null

  # On Windows, 7z may leave HFS partitions as files that need a second extraction
  $hfsFiles = Get-ChildItem -Path $extractedDir -Filter "*.hfs" -File -ErrorAction SilentlyContinue
  foreach ($hfs in $hfsFiles) {
    Write-Host "  Extracting HFS partition: $($hfs.Name)" -ForegroundColor Cyan
    & $sevenZip x -y $hfs.FullName -o"$extractedDir" | Out-Null
  }

  Write-Header "Locating app.asar"
  $asarPath = Find-AsarPath $extractedDir
  if (-not $asarPath) { throw "app.asar not found in extracted DMG. Check that this is a valid Superset DMG." }
  Write-Host "  Found: $asarPath" -ForegroundColor Green

  $asarDir = Split-Path $asarPath -Parent
  $unpackedPath = Join-Path $asarDir "app.asar.unpacked"

  # Detect Electron version from the Electron Framework plist inside the DMG
  if (-not $ElectronVersion) {
    $ElectronVersion = Find-ElectronVersion $extractedDir $null
    if ($ElectronVersion) {
      Write-Host "  Detected Electron version from framework: $ElectronVersion" -ForegroundColor Green
    }
  }

  # Locate extraResources (migrations etc.) placed outside the asar by electron-builder
  $extraResourcesDir = Find-ExtraResources $extractedDir
  if ($extraResourcesDir) {
    $savedExtraRes = Join-Path $WorkDir "extra-resources"
    if (Test-Path $savedExtraRes) { Remove-Item -Recurse -Force $savedExtraRes }
    & robocopy $extraResourcesDir $savedExtraRes /E /NFL /NDL /NJH /NJS /NC /NS | Out-Null
    Write-Host "  Saved extraResources: $extraResourcesDir" -ForegroundColor Green
  }

  if (Test-Path $electronDir) { Remove-Item -Recurse -Force $electronDir }
  New-Item -ItemType Directory -Force -Path $electronDir | Out-Null
  Copy-Item -Force $asarPath (Join-Path $electronDir "app.asar")
  if (Test-Path $unpackedPath) {
    & robocopy $unpackedPath (Join-Path $electronDir "app.asar.unpacked") /E /NFL /NDL /NJH /NJS /NC /NS | Out-Null
  }

  Write-Header "Unpacking app.asar"
  if (Test-Path $appDir) { Remove-Item -Recurse -Force $appDir }
  New-Item -ItemType Directory -Force -Path $appDir | Out-Null
  & npx --yes @electron/asar extract (Join-Path $electronDir "app.asar") $appDir

  Write-Header "Syncing app.asar.unpacked"
  $localUnpacked = Join-Path $electronDir "app.asar.unpacked"
  if (Test-Path $localUnpacked) {
    & robocopy $localUnpacked $appDir /E /NFL /NDL /NJH /NJS /NC /NS | Out-Null
  }
}

# ── Read app metadata ────────────────────────────────────────────────────────

Write-Header "Reading app metadata"
$pkgPath = Join-Path $appDir "package.json"
if (-not (Test-Path $pkgPath)) { throw "package.json not found in extracted app." }
$pkg = Get-Content -Raw $pkgPath | ConvertFrom-Json

# Electron version: parameter > devDependencies > plist detection > default
if (-not $ElectronVersion) {
  if ($pkg.PSObject.Properties.Name -contains "devDependencies" -and $pkg.devDependencies.PSObject.Properties.Name -contains "electron") {
    $ElectronVersion = $pkg.devDependencies.electron -replace '^\^',''
  }
}
if (-not $ElectronVersion) {
  $ElectronVersion = Find-ElectronVersion $extractedDir $null
}
if (-not $ElectronVersion) {
  $ElectronVersion = "40.2.1"
  Write-Host "  Warning: Electron version not detected, using default $ElectronVersion" -ForegroundColor Yellow
}

$betterSqliteVer = if ($pkg.dependencies."better-sqlite3") { $pkg.dependencies."better-sqlite3" } else { "12.6.2" }
$nodePtyVer      = if ($pkg.dependencies."node-pty")       { $pkg.dependencies."node-pty" }       else { "1.1.0" }
$astGrepVer      = if ($pkg.dependencies."@ast-grep/napi") { $pkg.dependencies."@ast-grep/napi" -replace '^\^','' } else { "0.41.0" }
$libsqlVer       = if ($pkg.dependencies."libsql")         { $pkg.dependencies."libsql" }         else { "0.5.22" }

$appName    = if ($pkg.productName) { $pkg.productName } else { "Superset" }
$appVersion = if ($pkg.version) { $pkg.version } else { "0.0.0" }

Write-Host "  App: $appName v$appVersion"
Write-Host "  Electron: $ElectronVersion"
Write-Host "  better-sqlite3: $betterSqliteVer"
Write-Host "  node-pty: $nodePtyVer"
Write-Host "  @ast-grep/napi: $astGrepVer"
Write-Host "  libsql: $libsqlVer"

# ── Rebuild native modules for Windows ───────────────────────────────────────

Write-Header "Preparing native modules for Windows"
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "win32-arm64" } else { "win32-x64" }
$npmArch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }

$bsDst     = Join-Path $appDir "node_modules\better-sqlite3\build\Release\better_sqlite3.node"
$ptyDstPre = Join-Path $appDir "node_modules\node-pty\prebuilds\$arch"

# node-pty ships with Windows prebuilds inside the DMG — check if they already exist
$existingPtyPrebuilds = Test-Path (Join-Path $ptyDstPre "pty.node")

$skipNative = $NoLaunch -and $Reuse -and (Test-Path $bsDst) -and $existingPtyPrebuilds
if ($skipNative) {
  Write-Host "Native modules already present. Skipping rebuild." -ForegroundColor Cyan
} else {
  New-Item -ItemType Directory -Force -Path $nativeDir | Out-Null
  Push-Location $nativeDir

  if (-not (Test-Path (Join-Path $nativeDir "package.json"))) {
    & npm init -y | Out-Null
  }

  $electronExe = Join-Path $nativeDir "node_modules\electron\dist\electron.exe"
  $bsSrcProbe = Join-Path $nativeDir "node_modules\better-sqlite3\build\Release\better_sqlite3.node"
  $haveNative = (Test-Path $bsSrcProbe) -and (Test-Path $electronExe)

  if (-not $haveNative) {
    Write-Host "Installing native modules and Electron $ElectronVersion..." -ForegroundColor Cyan

    $deps = @(
      "better-sqlite3@$betterSqliteVer",
      "@electron/rebuild",
      "prebuild-install",
      "electron@$ElectronVersion"
    )

    # Only install node-pty from npm if the DMG didn't ship usable prebuilds
    if (-not $existingPtyPrebuilds) {
      $deps += "node-pty@$nodePtyVer"
    }

    & npm install --no-save @deps
    if ($LASTEXITCODE -ne 0) { throw "npm install failed for native modules." }

    # Install platform-specific packages for ast-grep and libsql
    $platformPkgs = @()
    if ($npmArch -eq "x64") {
      $platformPkgs += "@ast-grep/napi-win32-x64-msvc@$astGrepVer"
      $platformPkgs += "@libsql/win32-x64-msvc"
    } else {
      $platformPkgs += "@ast-grep/napi-win32-arm64-msvc@$astGrepVer"
      $platformPkgs += "@libsql/win32-arm64-msvc"
    }
    $platformPkgs += "@ast-grep/napi@$astGrepVer"
    $platformPkgs += "libsql@$libsqlVer"

    foreach ($ppkg in $platformPkgs) {
      Write-Host "  Installing $ppkg..." -ForegroundColor Cyan
      & npm install --no-save $ppkg 2>$null
      if ($LASTEXITCODE -ne 0) {
        Write-Host "  Warning: could not install $ppkg (may not be available for this platform)" -ForegroundColor Yellow
      }
    }

    $electronExe = Join-Path $nativeDir "node_modules\electron\dist\electron.exe"
  } else {
    Write-Host "Native modules already built. Skipping install." -ForegroundColor Cyan
  }

  # Rebuild better-sqlite3 for Electron's Node ABI
  $rebuildModules = "better-sqlite3"
  if (-not $existingPtyPrebuilds) { $rebuildModules = "better-sqlite3,node-pty" }

  Write-Host "Rebuilding $rebuildModules for Electron $ElectronVersion..." -ForegroundColor Cyan
  $rebuildOk = $true
  if (-not $haveNative) {
    try {
      $rebuildCli = Join-Path $nativeDir "node_modules\@electron\rebuild\lib\cli.js"
      if (-not (Test-Path $rebuildCli)) { throw "electron-rebuild not found." }
      & node $rebuildCli -v $ElectronVersion -w $rebuildModules | Out-Null
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
      & node $prebuildCli -r electron -t $ElectronVersion --tag-prefix=electron-v | Out-Null
      Pop-Location
    }
    if (-not $existingPtyPrebuilds) {
      Write-Host "Trying prebuilt Electron binaries for node-pty..." -ForegroundColor Yellow
      $ptyDir = Join-Path $nativeDir "node_modules\node-pty"
      if (Test-Path $ptyDir) {
        Push-Location $ptyDir
        & node $prebuildCli -r electron -t $ElectronVersion --tag-prefix=electron-v 2>$null | Out-Null
        Pop-Location
      }
    }
  }

  # Validate better-sqlite3 loads in Electron
  $env:ELECTRON_RUN_AS_NODE = "1"
  if (Test-Path $electronExe) {
    & $electronExe -e "try{require('./node_modules/better-sqlite3');process.exit(0)}catch(e){console.error(e);process.exit(1)}" | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-Host "Warning: better-sqlite3 failed load check (may work at runtime)" -ForegroundColor Yellow
    }
  }
  Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue

  Pop-Location

  # ── Copy native binaries into app ──────────────────────────────────────────

  Write-Header "Copying native modules into app"

  # better-sqlite3
  $bsSrc = Join-Path $nativeDir "node_modules\better-sqlite3\build\Release\better_sqlite3.node"
  if (-not (Test-Path $bsSrc)) {
    $bsPrebuildDir = Join-Path $nativeDir "node_modules\better-sqlite3\prebuilds\$arch"
    $bsPrebuild = Get-ChildItem -Path $bsPrebuildDir -Filter "better_sqlite3.node" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($bsPrebuild) { $bsSrc = $bsPrebuild.FullName }
  }
  if (Test-Path $bsSrc) {
    $bsDstDir = Split-Path $bsDst -Parent
    New-Item -ItemType Directory -Force -Path $bsDstDir | Out-Null
    Copy-Item -Force $bsSrc (Join-Path $bsDstDir "better_sqlite3.node")
    Write-Host "  better-sqlite3 -> OK" -ForegroundColor Green
  } else {
    throw "better_sqlite3.node not found. Install Visual Studio Build Tools or use a machine with prebuilds."
  }

  # node-pty — use DMG prebuilds if available, otherwise copy from npm install
  if ($existingPtyPrebuilds) {
    Write-Host "  node-pty -> OK (using existing DMG prebuilds for $arch)" -ForegroundColor Green
  } else {
    $ptySrcDir = Join-Path $nativeDir "node_modules\node-pty\prebuilds\$arch"
    if (-not (Test-Path (Join-Path $ptySrcDir "pty.node"))) {
      $ptyPrebuildDir = Join-Path $nativeDir "node_modules\node-pty\prebuilds"
      $found = Get-ChildItem -Path $ptyPrebuildDir -Filter "pty.node" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($found) { $ptySrcDir = Split-Path $found.FullName -Parent }
    }
    $ptyDstRel = Join-Path $appDir "node_modules\node-pty\build\Release"
    New-Item -ItemType Directory -Force -Path $ptyDstPre | Out-Null
    New-Item -ItemType Directory -Force -Path $ptyDstRel | Out-Null

    # Copy all prebuild files including conpty subdirectory
    if (Test-Path $ptySrcDir) {
      Get-ChildItem -Path $ptySrcDir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $relPath = $_.FullName.Substring($ptySrcDir.Length)
        $dstFile = Join-Path $ptyDstPre $relPath
        New-Item -ItemType Directory -Force -Path (Split-Path $dstFile -Parent) | Out-Null
        Copy-Item -Force $_.FullName $dstFile
        # Also copy .node files to build/Release for fallback module loading
        if ($_.Extension -eq ".node") {
          Copy-Item -Force $_.FullName (Join-Path $ptyDstRel $_.Name)
        }
      }
      Write-Host "  node-pty -> OK (rebuilt from npm)" -ForegroundColor Green
    } else {
      Write-Host "  node-pty: prebuilds not found (terminal features may not work)" -ForegroundColor Yellow
    }
  }

  # Remove macOS/Linux prebuilds from node-pty to save space and avoid confusion
  $ptyPrebuildsBase = Join-Path $appDir "node_modules\node-pty\prebuilds"
  if (Test-Path $ptyPrebuildsBase) {
    Get-ChildItem -Path $ptyPrebuildsBase -Directory -Filter "darwin-*" -ErrorAction SilentlyContinue |
      ForEach-Object { Remove-Item -Recurse -Force $_.FullName }
    Get-ChildItem -Path $ptyPrebuildsBase -Directory -Filter "linux-*" -ErrorAction SilentlyContinue |
      ForEach-Object { Remove-Item -Recurse -Force $_.FullName }
  }

  # Copy winpty/conpty supporting files to build/Release for node-pty
  $ptyWinFiles = @("winpty.dll", "winpty-agent.exe")
  $ptyDstRel = Join-Path $appDir "node_modules\node-pty\build\Release"
  foreach ($wf in $ptyWinFiles) {
    $src = Join-Path $ptyDstPre $wf
    if (Test-Path $src) {
      Copy-Item -Force $src (Join-Path $ptyDstRel $wf)
    }
  }
  # Copy conpty subdirectory to build/Release if it exists
  $conptySrc = Join-Path $ptyDstPre "conpty"
  $conptyDst = Join-Path $ptyDstRel "conpty"
  if (Test-Path $conptySrc) {
    New-Item -ItemType Directory -Force -Path $conptyDst | Out-Null
    Get-ChildItem -Path $conptySrc -File -ErrorAction SilentlyContinue | ForEach-Object {
      Copy-Item -Force $_.FullName (Join-Path $conptyDst $_.Name)
    }
  }

  # @ast-grep/napi — copy platform-specific package into app
  $astGrepAppDir = Join-Path $appDir "node_modules\@ast-grep"
  if (Test-Path $astGrepAppDir) {
    $astGrepPlatPkg = if ($npmArch -eq "x64") { "napi-win32-x64-msvc" } else { "napi-win32-arm64-msvc" }
    $astGrepSrc = Join-Path $nativeDir "node_modules\@ast-grep\$astGrepPlatPkg"
    if (Test-Path $astGrepSrc) {
      $astGrepDst = Join-Path $astGrepAppDir $astGrepPlatPkg
      if (Test-Path $astGrepDst) { Remove-Item -Recurse -Force $astGrepDst }
      & robocopy $astGrepSrc $astGrepDst /E /NFL /NDL /NJH /NJS /NC /NS | Out-Null
      Get-ChildItem -Path $astGrepAppDir -Directory -Filter "napi-darwin-*" -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -Recurse -Force $_.FullName }
      Get-ChildItem -Path $astGrepAppDir -Directory -Filter "napi-linux-*" -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -Recurse -Force $_.FullName }
      Write-Host "  @ast-grep/napi -> OK ($astGrepPlatPkg)" -ForegroundColor Green
    } else {
      Write-Host "  @ast-grep/napi: Windows platform package not found (code analysis may not work)" -ForegroundColor Yellow
    }
  }

  # libsql / @libsql — copy platform-specific package into app
  $libsqlAppDir = Join-Path $appDir "node_modules\@libsql"
  if (Test-Path $libsqlAppDir) {
    $libsqlPlatPkg = if ($npmArch -eq "x64") { "win32-x64-msvc" } else { "win32-arm64-msvc" }
    $libsqlSrc = Join-Path $nativeDir "node_modules\@libsql\$libsqlPlatPkg"
    if (Test-Path $libsqlSrc) {
      $libsqlDst = Join-Path $libsqlAppDir $libsqlPlatPkg
      if (Test-Path $libsqlDst) { Remove-Item -Recurse -Force $libsqlDst }
      & robocopy $libsqlSrc $libsqlDst /E /NFL /NDL /NJH /NJS /NC /NS | Out-Null
      Get-ChildItem -Path $libsqlAppDir -Directory -Filter "darwin-*" -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -Recurse -Force $_.FullName }
      Get-ChildItem -Path $libsqlAppDir -Directory -Filter "linux-*" -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -Recurse -Force $_.FullName }
      Write-Host "  @libsql -> OK ($libsqlPlatPkg)" -ForegroundColor Green
    } else {
      Write-Host "  @libsql: Windows platform package not found (libsql features may not work)" -ForegroundColor Yellow
    }
  }
}

# ── Patch for Windows ────────────────────────────────────────────────────────

Write-Header "Patching for Windows"
Patch-PlatformReferences $appDir
Patch-MainForPortable $appDir

# ── Build portable exe ───────────────────────────────────────────────────────

$packagedExe = $null
if ($BuildExe) {
  Write-Header "Packaging $appName.exe"
  $packagerArch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
  $electronDistDir = Join-Path $nativeDir "node_modules\electron\dist"
  if (-not (Test-Path $electronDistDir)) { throw "Electron dist not found for packaging." }

  $outputDir = Join-Path $packagedDir "$appName-win32-$packagerArch"
  if (Test-Path $outputDir) { Remove-Item -Recurse -Force $outputDir }
  New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

  Write-Host "Copying Electron runtime..." -ForegroundColor Cyan
  & robocopy $electronDistDir $outputDir /E /NFL /NDL /NJH /NJS /NC /NS | Out-Null

  $srcExe = Join-Path $outputDir "electron.exe"
  $dstExe = Join-Path $outputDir "$appName.exe"
  if (Test-Path $srcExe) {
    Rename-Item -Path $srcExe -NewName "$appName.exe"
  } elseif (-not (Test-Path $dstExe)) {
    throw "electron.exe not found in Electron dist."
  }

  Write-Host "Copying app files to resources\app..." -ForegroundColor Cyan
  $resourcesDir = Join-Path $outputDir "resources"
  New-Item -ItemType Directory -Force -Path $resourcesDir | Out-Null
  $appDstDir = Join-Path $resourcesDir "app"
  & robocopy $appDir $appDstDir /E /NFL /NDL /NJH /NJS /NC /NS | Out-Null

  # Copy extraResources (migrations) alongside the app
  $savedExtraRes = Join-Path $WorkDir "extra-resources"
  if (Test-Path $savedExtraRes) {
    & robocopy $savedExtraRes (Join-Path $resourcesDir "resources") /E /NFL /NDL /NJH /NJS /NC /NS | Out-Null
    Write-Host "  Copied extraResources (migrations)" -ForegroundColor Green
  }

  $defaultAsar = Join-Path $resourcesDir "default_app.asar"
  if (Test-Path $defaultAsar) { Remove-Item -Force $defaultAsar }

  Write-Host "Patching main.js for portable mode..." -ForegroundColor Cyan
  Patch-MainForPortable $appDstDir

  # Create Desktop shortcut
  Write-Header "Creating Desktop shortcut"
  $desktopPath = [Environment]::GetFolderPath("Desktop")
  $shortcutPath = Join-Path $desktopPath "$appName.lnk"
  try {
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($shortcutPath)
    $sc.TargetPath = $dstExe
    $sc.WorkingDirectory = $outputDir
    $sc.Description = $appName
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
  Write-Host "  $appName packaged successfully!" -ForegroundColor Green
  Write-Host "  Output: $outputDir" -ForegroundColor Green
  Write-Host "" -ForegroundColor Green
  Write-Host "  A Desktop shortcut has been created." -ForegroundColor Green
  Write-Host "  Double-click '$appName' on your Desktop to launch." -ForegroundColor Green
  Write-Host "" -ForegroundColor Green
  Write-Host "  IMPORTANT: Do NOT move $appName.exe by itself." -ForegroundColor Green
  Write-Host "  Move the ENTIRE folder if you want to relocate." -ForegroundColor Green
  Write-Host "=============================================" -ForegroundColor Green
}

# ── Launch ───────────────────────────────────────────────────────────────────

if (-not $NoLaunch) {
  Write-Header "Launching $appName"
  Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
  $env:ELECTRON_FORCE_IS_PACKAGED = "1"
  $env:NODE_ENV = "production"
  Ensure-GitOnPath

  if ($packagedExe) {
    Start-Process -FilePath $packagedExe -ArgumentList "--enable-logging" -NoNewWindow -Wait
  } else {
    $electronExe = Join-Path $nativeDir "node_modules\electron\dist\electron.exe"
    if (-not (Test-Path $electronExe)) { throw "electron.exe not found. Run without -Reuse first." }

    $rendererCandidates = @(
      (Join-Path $appDir "dist\renderer\index.html"),
      (Join-Path $appDir "renderer\index.html")
    )
    foreach ($rc in $rendererCandidates) {
      if (Test-Path $rc) {
        $env:ELECTRON_RENDERER_URL = (New-Object System.Uri $rc).AbsoluteUri
        break
      }
    }

    $env:PWD = $appDir
    New-Item -ItemType Directory -Force -Path $userDataDir | Out-Null
    New-Item -ItemType Directory -Force -Path $cacheDir   | Out-Null
    Start-Process -FilePath $electronExe -ArgumentList "$appDir","--enable-logging","--user-data-dir=`"$userDataDir`"","--disk-cache-dir=`"$cacheDir`"" -NoNewWindow -Wait
  }
}
