BeforeAll {
  $script:ScriptPath = Join-Path $PSScriptRoot "..\scripts\run-superset.ps1"
  $script:TestDataDir = Join-Path $PSScriptRoot "test-data"

  # Parse the script AST for structural tests
  $tokens = $null
  $errors = $null
  $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $script:ScriptPath, [ref]$tokens, [ref]$errors
  )
  $script:ParseErrors = $errors
  $script:Tokens = $tokens

  # Extract all function definitions
  $script:Functions = $script:Ast.FindAll(
    { param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] },
    $false
  )

  # Dot-source the functions for unit testing by extracting them from the script
  # We create a temporary module scope with mocked commands so the top-level code doesn't execute
  $scriptContent = Get-Content -Raw $script:ScriptPath

  # Extract function blocks for isolated testing
  $script:FunctionBodies = @{}
  foreach ($fn in $script:Functions) {
    $script:FunctionBodies[$fn.Name] = $fn.Extent.Text
  }
}

Describe "Script Syntax and Structure" {
  It "parses without syntax errors" {
    $script:ParseErrors.Count | Should -Be 0
  }

  It "has non-zero token count" {
    $script:Tokens.Count | Should -BeGreaterThan 100
  }

  It "has no PSScriptAnalyzer errors" {
    $results = Invoke-ScriptAnalyzer -Path $script:ScriptPath -Severity Error
    $results.Count | Should -Be 0
  }

  It "declares all expected parameters" {
    $params = $script:Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
    $params | Should -Contain "DmgPath"
    $params | Should -Contain "WorkDir"
    $params | Should -Contain "ElectronVersion"
    $params | Should -Contain "Reuse"
    $params | Should -Contain "NoLaunch"
    $params | Should -Contain "BuildExe"
  }

  It "has ElectronVersion as a string parameter" {
    $evParam = $script:Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq "ElectronVersion" }
    $evParam | Should -Not -BeNullOrEmpty
    $evParam.StaticType.Name | Should -Be "String"
  }
}

Describe "Required Functions" {
  BeforeAll {
    $script:FnNames = @($script:Functions | ForEach-Object { $_.Name })
  }

  It "defines Ensure-Command" { $script:FnNames | Should -Contain "Ensure-Command" }
  It "defines Write-Header" { $script:FnNames | Should -Contain "Write-Header" }
  It "defines Resolve-7z" { $script:FnNames | Should -Contain "Resolve-7z" }
  It "defines Ensure-GitOnPath" { $script:FnNames | Should -Contain "Ensure-GitOnPath" }
  It "defines Find-AsarPath" { $script:FnNames | Should -Contain "Find-AsarPath" }
  It "defines Find-ElectronVersion" { $script:FnNames | Should -Contain "Find-ElectronVersion" }
  It "defines Find-ExtraResources" { $script:FnNames | Should -Contain "Find-ExtraResources" }
  It "defines Patch-MainForPortable" { $script:FnNames | Should -Contain "Patch-MainForPortable" }
  It "defines Patch-PlatformReferences" { $script:FnNames | Should -Contain "Patch-PlatformReferences" }
}

Describe "Find-AsarPath" {
  BeforeAll {
    Invoke-Expression $script:FunctionBodies["Find-AsarPath"]
  }

  It "returns null for empty directory" {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "superset-test-empty-$(Get-Random)"
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    try {
      Find-AsarPath $tempDir | Should -BeNullOrEmpty
    } finally {
      Remove-Item -Recurse -Force $tempDir
    }
  }

  It "finds app.asar in standard Electron-builder DMG structure" {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "superset-test-asar-$(Get-Random)"
    $asarDir = Join-Path $tempDir "Superset 1.0.4-arm64" "Superset.app" "Contents" "Resources"
    New-Item -ItemType Directory -Force -Path $asarDir | Out-Null
    Set-Content -Path (Join-Path $asarDir "app.asar") -Value "fake"
    try {
      $result = Find-AsarPath $tempDir
      $result | Should -Not -BeNullOrEmpty
      $result | Should -BeLike "*Contents*Resources*app.asar"
    } finally {
      Remove-Item -Recurse -Force $tempDir
    }
  }

  It "finds app.asar even without standard Contents/Resources path" {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "superset-test-asar2-$(Get-Random)"
    $asarDir = Join-Path $tempDir "SomeDir"
    New-Item -ItemType Directory -Force -Path $asarDir | Out-Null
    Set-Content -Path (Join-Path $asarDir "app.asar") -Value "fake"
    try {
      $result = Find-AsarPath $tempDir
      $result | Should -Not -BeNullOrEmpty
      $result | Should -BeLike "*app.asar"
    } finally {
      Remove-Item -Recurse -Force $tempDir
    }
  }

  It "prefers Contents/Resources path over other locations" {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "superset-test-asar3-$(Get-Random)"
    $preferredDir = Join-Path $tempDir "App.app" "Contents" "Resources"
    $otherDir = Join-Path $tempDir "other"
    New-Item -ItemType Directory -Force -Path $preferredDir | Out-Null
    New-Item -ItemType Directory -Force -Path $otherDir | Out-Null
    Set-Content -Path (Join-Path $preferredDir "app.asar") -Value "preferred"
    Set-Content -Path (Join-Path $otherDir "app.asar") -Value "other"
    try {
      $result = Find-AsarPath $tempDir
      $result | Should -BeLike "*Contents*Resources*app.asar"
    } finally {
      Remove-Item -Recurse -Force $tempDir
    }
  }
}

Describe "Find-ElectronVersion" {
  BeforeAll {
    Invoke-Expression $script:FunctionBodies["Find-ElectronVersion"]
  }

  It "returns version from Info.plist CFBundleVersion" {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "superset-test-ev-$(Get-Random)"
    $fwDir = Join-Path $tempDir "App.app" "Contents" "Frameworks" "Electron Framework.framework" "Versions" "A" "Resources"
    New-Item -ItemType Directory -Force -Path $fwDir | Out-Null
    $plistContent = @"
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>CFBundleVersion</key>
  <string>40.2.1</string>
</dict>
</plist>
"@
    Set-Content -Path (Join-Path $fwDir "Info.plist") -Value $plistContent
    try {
      $result = Find-ElectronVersion $tempDir $null
      $result | Should -Be "40.2.1"
    } finally {
      Remove-Item -Recurse -Force $tempDir
    }
  }

  It "returns explicit version when provided" {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "superset-test-ev2-$(Get-Random)"
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    try {
      $result = Find-ElectronVersion $tempDir "35.0.0"
      $result | Should -Be "35.0.0"
    } finally {
      Remove-Item -Recurse -Force $tempDir
    }
  }

  It "strips caret from package version" {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "superset-test-ev3-$(Get-Random)"
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    try {
      $result = Find-ElectronVersion $tempDir "^40.2.1"
      $result | Should -Be "40.2.1"
    } finally {
      Remove-Item -Recurse -Force $tempDir
    }
  }

  It "returns null when no plist and no explicit version" {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "superset-test-ev4-$(Get-Random)"
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    try {
      $result = Find-ElectronVersion $tempDir $null
      $result | Should -BeNullOrEmpty
    } finally {
      Remove-Item -Recurse -Force $tempDir
    }
  }
}

Describe "Find-ExtraResources" {
  BeforeAll {
    Invoke-Expression $script:FunctionBodies["Find-ExtraResources"]
  }

  It "finds migrations directory in standard location" {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "superset-test-er-$(Get-Random)"
    $migDir = Join-Path $tempDir "App.app" "Contents" "Resources" "resources" "migrations" "meta"
    New-Item -ItemType Directory -Force -Path $migDir | Out-Null
    Set-Content -Path (Join-Path $migDir "0001.sql") -Value "test"
    try {
      $result = Find-ExtraResources $tempDir
      $result | Should -Not -BeNullOrEmpty
      $result | Should -BeLike "*resources"
    } finally {
      Remove-Item -Recurse -Force $tempDir
    }
  }

  It "ignores migrations inside app.asar.unpacked" {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "superset-test-er2-$(Get-Random)"
    $asarMig = Join-Path $tempDir "Contents" "Resources" "app.asar.unpacked" "resources" "migrations"
    $realMig = Join-Path $tempDir "Contents" "Resources" "resources" "migrations"
    New-Item -ItemType Directory -Force -Path $asarMig | Out-Null
    New-Item -ItemType Directory -Force -Path $realMig | Out-Null
    try {
      $result = Find-ExtraResources $tempDir
      $result | Should -Not -BeLike "*app.asar*"
    } finally {
      Remove-Item -Recurse -Force $tempDir
    }
  }
}

Describe "Patch-MainForPortable" {
  BeforeAll {
    Invoke-Expression $script:FunctionBodies["Patch-MainForPortable"]
  }

  It "patches dist/main/index.js with portable shim" {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "superset-test-pm-$(Get-Random)"
    $mainDir = Join-Path $tempDir "dist" "main"
    New-Item -ItemType Directory -Force -Path $mainDir | Out-Null
    Set-Content -Path (Join-Path $mainDir "index.js") -Value "const app = require('electron');"
    try {
      Patch-MainForPortable $tempDir
      $content = Get-Content -Raw (Join-Path $mainDir "index.js")
      $content | Should -BeLike "*SUPERSET-PORTABLE-SHIM*"
      $content | Should -BeLike "*ELECTRON_FORCE_IS_PACKAGED*"
      $content | Should -BeLike "*ELECTRON_RENDERER_URL*"
      $content | Should -BeLike "*const app = require*"
    } finally {
      Remove-Item -Recurse -Force $tempDir
    }
  }

  It "is idempotent — does not double-patch" {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "superset-test-pm2-$(Get-Random)"
    $mainDir = Join-Path $tempDir "dist" "main"
    New-Item -ItemType Directory -Force -Path $mainDir | Out-Null
    Set-Content -Path (Join-Path $mainDir "index.js") -Value "const x = 1;"
    try {
      Patch-MainForPortable $tempDir
      $firstPatch = Get-Content -Raw (Join-Path $mainDir "index.js")
      Patch-MainForPortable $tempDir
      $secondPatch = Get-Content -Raw (Join-Path $mainDir "index.js")
      $firstPatch | Should -Be $secondPatch
    } finally {
      Remove-Item -Recurse -Force $tempDir
    }
  }

  It "skips gracefully when main.js does not exist" {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "superset-test-pm3-$(Get-Random)"
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    try {
      { Patch-MainForPortable $tempDir } | Should -Not -Throw
    } finally {
      Remove-Item -Recurse -Force $tempDir
    }
  }
}

Describe "Patch-PlatformReferences" {
  BeforeAll {
    Invoke-Expression $script:FunctionBodies["Patch-PlatformReferences"]
  }

  It "patches files referencing /bin/zsh with COMSPEC fallback" {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "superset-test-ppr-$(Get-Random)"
    $mainDir = Join-Path $tempDir "dist" "main"
    New-Item -ItemType Directory -Force -Path $mainDir | Out-Null
    Set-Content -Path (Join-Path $mainDir "index.js") -Value 'const shell = "/bin/zsh";'
    try {
      Patch-PlatformReferences $tempDir
      $content = Get-Content -Raw (Join-Path $mainDir "index.js")
      $content | Should -BeLike "*SUPERSET-SHELL-PATCH*"
      $content | Should -BeLike "*COMSPEC*"
    } finally {
      Remove-Item -Recurse -Force $tempDir
    }
  }

  It "is idempotent" {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "superset-test-ppr2-$(Get-Random)"
    $mainDir = Join-Path $tempDir "dist" "main"
    New-Item -ItemType Directory -Force -Path $mainDir | Out-Null
    Set-Content -Path (Join-Path $mainDir "index.js") -Value 'const s = "/bin/zsh";'
    try {
      Patch-PlatformReferences $tempDir
      $first = Get-Content -Raw (Join-Path $mainDir "index.js")
      Patch-PlatformReferences $tempDir
      $second = Get-Content -Raw (Join-Path $mainDir "index.js")
      $first | Should -Be $second
    } finally {
      Remove-Item -Recurse -Force $tempDir
    }
  }

  It "does not modify files without /bin/zsh reference" {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "superset-test-ppr3-$(Get-Random)"
    $mainDir = Join-Path $tempDir "dist" "main"
    New-Item -ItemType Directory -Force -Path $mainDir | Out-Null
    $original = 'const shell = process.env.SHELL;'
    Set-Content -Path (Join-Path $mainDir "index.js") -Value $original
    try {
      Patch-PlatformReferences $tempDir
      $content = Get-Content -Raw (Join-Path $mainDir "index.js")
      $content.Trim() | Should -Be $original
    } finally {
      Remove-Item -Recurse -Force $tempDir
    }
  }
}

Describe "Real DMG Integration" -Tag "Integration" {
  BeforeAll {
    $script:RealExtractDir = "/workspace/test-extract"
    $script:RealAppDir = "/workspace/test-extract/app"
    $script:RealDmgExtractDir = "/workspace/test-extract/Superset 1.0.4-arm64"

    foreach ($fn in $script:Functions) {
      Invoke-Expression $fn.Extent.Text
    }
  }

  It "Find-AsarPath locates asar in real extracted DMG"  {
    $result = Find-AsarPath $script:RealDmgExtractDir
    $result | Should -Not -BeNullOrEmpty
    $result | Should -BeLike "*Superset.app*Contents*Resources*app.asar"
  }

  It "Find-ElectronVersion detects 40.2.1 from real DMG plist"  {
    $result = Find-ElectronVersion $script:RealDmgExtractDir $null
    $result | Should -Be "40.2.1"
  }

  It "Find-ExtraResources locates migrations in real DMG"  {
    $result = Find-ExtraResources $script:RealDmgExtractDir
    $result | Should -Not -BeNullOrEmpty
    Test-Path (Join-Path $result "migrations") | Should -BeTrue
  }

  It "Real app package.json has expected fields"  {
    $pkg = Get-Content -Raw (Join-Path $script:RealAppDir "package.json") | ConvertFrom-Json
    $pkg.productName | Should -Be "Superset"
    $pkg.version | Should -Be "1.0.4"
    $pkg.main | Should -Be "./dist/main/index.js"
    $pkg.dependencies."better-sqlite3" | Should -Be "12.6.2"
    $pkg.dependencies."node-pty" | Should -Be "1.1.0"
    $pkg.dependencies.libsql | Should -Be "0.5.22"
  }

  It "Real app has NO devDependencies (bug regression check)"  {
    $pkg = Get-Content -Raw (Join-Path $script:RealAppDir "package.json") | ConvertFrom-Json
    $pkg.PSObject.Properties.Name | Should -Not -Contain "devDependencies"
  }

  It "Real app has dist/main/index.js"  {
    Test-Path (Join-Path $script:RealAppDir "dist" "main" "index.js") | Should -BeTrue
  }

  It "Real app has dist/renderer/index.html"  {
    Test-Path (Join-Path $script:RealAppDir "dist" "renderer" "index.html") | Should -BeTrue
  }

  It "Real app has dist/preload (no standalone preload.js at root)"  {
    Test-Path (Join-Path $script:RealAppDir "dist" "preload") | Should -BeTrue
    Test-Path (Join-Path $script:RealAppDir "preload.js") | Should -BeFalse
  }

  It "Real app has correct node_modules for native modules"  {
    Test-Path (Join-Path $script:RealAppDir "node_modules" "better-sqlite3") | Should -BeTrue
    Test-Path (Join-Path $script:RealAppDir "node_modules" "node-pty") | Should -BeTrue
    Test-Path (Join-Path $script:RealAppDir "node_modules" "@ast-grep") | Should -BeTrue
    Test-Path (Join-Path $script:RealAppDir "node_modules" "@libsql") | Should -BeTrue
    Test-Path (Join-Path $script:RealAppDir "node_modules" "libsql") | Should -BeTrue
  }

  It "node-pty ships with win32-x64 prebuilds in DMG"  {
    $ptyPrebuilds = Join-Path $script:RealDmgExtractDir "Superset.app" "Contents" "Resources" "app.asar.unpacked" "node_modules" "node-pty" "prebuilds" "win32-x64"
    Test-Path $ptyPrebuilds | Should -BeTrue
    Test-Path (Join-Path $ptyPrebuilds "pty.node") | Should -BeTrue
    Test-Path (Join-Path $ptyPrebuilds "conpty.node") | Should -BeTrue
    Test-Path (Join-Path $ptyPrebuilds "conpty_console_list.node") | Should -BeTrue
    Test-Path (Join-Path $ptyPrebuilds "winpty.dll") | Should -BeTrue
    Test-Path (Join-Path $ptyPrebuilds "winpty-agent.exe") | Should -BeTrue
  }

  It "node-pty ships with win32-x64 conpty subdirectory"  {
    $conptyDir = Join-Path $script:RealDmgExtractDir "Superset.app" "Contents" "Resources" "app.asar.unpacked" "node_modules" "node-pty" "prebuilds" "win32-x64" "conpty"
    Test-Path $conptyDir | Should -BeTrue
    Test-Path (Join-Path $conptyDir "conpty.dll") | Should -BeTrue
    Test-Path (Join-Path $conptyDir "OpenConsole.exe") | Should -BeTrue
  }

  It "node-pty ships with win32-arm64 prebuilds in DMG"  {
    $ptyPrebuilds = Join-Path $script:RealDmgExtractDir "Superset.app" "Contents" "Resources" "app.asar.unpacked" "node_modules" "node-pty" "prebuilds" "win32-arm64"
    Test-Path $ptyPrebuilds | Should -BeTrue
    Test-Path (Join-Path $ptyPrebuilds "pty.node") | Should -BeTrue
  }

  It "@ast-grep has darwin-arm64 platform package (to be replaced on Windows)"  {
    $darwinPkg = Join-Path $script:RealDmgExtractDir "Superset.app" "Contents" "Resources" "app.asar.unpacked" "node_modules" "@ast-grep" "napi-darwin-arm64"
    Test-Path $darwinPkg | Should -BeTrue
  }

  It "@libsql has darwin-arm64 platform package (to be replaced on Windows)"  {
    $darwinPkg = Join-Path $script:RealDmgExtractDir "Superset.app" "Contents" "Resources" "app.asar.unpacked" "node_modules" "@libsql" "darwin-arm64"
    Test-Path $darwinPkg | Should -BeTrue
  }

  It "Renderer index.html loads correct assets"  {
    $html = Get-Content -Raw (Join-Path $script:RealAppDir "dist" "renderer" "index.html")
    $html | Should -BeLike "*<app></app>*"
    $html | Should -BeLike "*assets/index-*"
    $html | Should -BeLike "*theme-boot.js*"
  }

  It "Main bundle is substantial (>10MB, confirming full build)"  {
    $mainJs = Get-Item (Join-Path $script:RealAppDir "dist" "main" "index.js")
    $mainJs.Length | Should -BeGreaterThan 10000000
  }
}

Describe "Electron Version Fallback Logic" {
  BeforeAll {
    foreach ($fn in $script:Functions) {
      Invoke-Expression $fn.Extent.Text
    }
  }

  It "falls back to plist when devDependencies is absent" {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "superset-test-evf-$(Get-Random)"
    $fwDir = Join-Path $tempDir "Electron Framework.framework" "Versions" "A" "Resources"
    New-Item -ItemType Directory -Force -Path $fwDir | Out-Null
    Set-Content -Path (Join-Path $fwDir "Info.plist") -Value @"
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleVersion</key><string>38.0.0</string>
</dict></plist>
"@
    try {
      $result = Find-ElectronVersion $tempDir $null
      $result | Should -Be "38.0.0"
    } finally {
      Remove-Item -Recurse -Force $tempDir
    }
  }
}

Describe "Script Logic — DMG Path Resolution" {
  It "script contains Superset*.dmg fallback pattern" {
    $content = Get-Content -Raw $script:ScriptPath
    $content | Should -BeLike "*Superset*.dmg*"
  }

  It "script references GitHub releases URL in error message" {
    $content = Get-Content -Raw $script:ScriptPath
    $content | Should -BeLike "*github.com/superset-sh/superset/releases*"
  }
}

Describe "Script Logic — Native Module Handling" {
  It "handles all four native modules" {
    $content = Get-Content -Raw $script:ScriptPath
    $content | Should -BeLike "*better-sqlite3*"
    $content | Should -BeLike "*node-pty*"
    $content | Should -BeLike "*@ast-grep/napi*"
    $content | Should -BeLike "*libsql*"
  }

  It "installs correct Windows platform packages" {
    $content = Get-Content -Raw $script:ScriptPath
    $content | Should -BeLike "*napi-win32-x64-msvc*"
    $content | Should -BeLike "*napi-win32-arm64-msvc*"
    $content | Should -BeLike "*@libsql/win32-x64-msvc*"
    $content | Should -BeLike "*@libsql/win32-arm64-msvc*"
  }

  It "removes macOS platform packages after copying Windows ones" {
    $content = Get-Content -Raw $script:ScriptPath
    $content | Should -BeLike "*napi-darwin-*"
    $content | Should -BeLike "*darwin-*" 
    $content | Should -BeLike "*Remove-Item*"
  }

  It "removes linux platform packages" {
    $content = Get-Content -Raw $script:ScriptPath
    $content | Should -BeLike "*napi-linux-*"
    $content | Should -BeLike "*linux-*"
  }

  It "handles node-pty conpty subdirectory and winpty files" {
    $content = Get-Content -Raw $script:ScriptPath
    $content | Should -BeLike "*conptySrc*"
    $content | Should -BeLike "*conptyDst*"
    $content | Should -BeLike "*winpty.dll*"
    $content | Should -BeLike "*winpty-agent.exe*"
  }

  It "checks for existing DMG prebuilds before npm install" {
    $content = Get-Content -Raw $script:ScriptPath
    $content | Should -BeLike "*existingPtyPrebuilds*"
    $content | Should -BeLike "*using existing DMG prebuilds*"
  }
}

Describe "Script Logic — Portable Build" {
  It "copies extraResources in BuildExe mode" {
    $content = Get-Content -Raw $script:ScriptPath
    $content | Should -BeLike "*extra-resources*"
    $content | Should -BeLike "*migrations*"
  }

  It "creates Desktop shortcut" {
    $content = Get-Content -Raw $script:ScriptPath
    $content | Should -BeLike "*WScript.Shell*"
    $content | Should -BeLike "*CreateShortcut*"
  }

  It "removes default_app.asar from Electron dist" {
    $content = Get-Content -Raw $script:ScriptPath
    $content | Should -BeLike "*default_app.asar*"
  }
}
