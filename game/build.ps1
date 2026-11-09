# Rocket Landing - build script (ASCII-only; paths computed from current location).
# Run from the project root (…\rocket-landing):
#   powershell -ExecutionPolicy Bypass -File .\build.ps1

$ErrorActionPreference = 'Stop'

$ProjectDir  = (Get-Location).Path                      # must be …\rocket-landing
if (-not (Test-Path (Join-Path $ProjectDir 'project.godot'))) {
    throw "Run from the project root (…\rocket-landing)"
}
$IvanoDir    = Split-Path -Parent $ProjectDir           # must contain godot\ and rocket-ai\
$GodotDir    = Join-Path $IvanoDir 'godot'
$GodotExe    = Join-Path $GodotDir 'Godot_v4.7.2-stable_win64.exe'
$GodotConsole= Join-Path $GodotDir 'Godot_v4.7.2-stable_win64_console.exe'
$RocketAi    = Join-Path $IvanoDir 'rocket-ai'
$BuildDir    = Join-Path $ProjectDir 'build\RocketLanding'

if (-not (Test-Path $GodotExe)) { throw "Godot runtime not found: $GodotExe" }
if (-not (Test-Path $GodotConsole)) { throw "Godot console not found: $GodotConsole" }
if (-not (Test-Path $RocketAi)) { throw "rocket-ai folder not found: $RocketAi" }

# --- version ---
$m = Select-String -Path (Join-Path $ProjectDir 'project.godot') -Pattern 'config/version\s*=\s*"([^"]+)"'
$Version = if ($m) { $m.Matches[0].Groups[1].Value } else { '0.0.0' }

# --- commit ---
$Commit = 'nogit'
try {
    $Commit = (& git -C $ProjectDir rev-parse --short HEAD).Trim()
} catch {
    Write-Host "warn: git unavailable - COMMIT=nogit"
}
$BuildDate = Get-Date -Format 'yyyy-MM-dd'
Write-Host "==> building Rocket Landing v$Version ($Commit) $BuildDate"

# --- stamp game.gd ---
$gameGd = Join-Path $ProjectDir 'game.gd'
$original = [System.IO.File]::ReadAllText($gameGd, [System.Text.Encoding]::UTF8)
try {
    $t = $original
    $t = [regex]::Replace($t, 'const VERSION := "[^"]*"',    'const VERSION := "' + $Version + '"')
    $t = [regex]::Replace($t, 'const COMMIT := "[^"]*"',       'const COMMIT := "' + $Commit + '"')
    $t = [regex]::Replace($t, 'const BUILD_DATE := "[^"]*"',   'const BUILD_DATE := "' + $BuildDate + '"')
    [System.IO.File]::WriteAllText($gameGd, $t, [System.Text.Encoding]::UTF8)

    New-Item -ItemType Directory -Force $BuildDir | Out-Null
    & $GodotConsole --headless --path $ProjectDir --export-pack "Windows Desktop" (Join-Path $BuildDir 'RocketLanding.pck') 2>&1 | Select-Object -Last 4
}
finally {
    # restore original sources so the repo is not dirtied by stamping
    [System.IO.File]::WriteAllText($gameGd, $original, [System.Text.Encoding]::UTF8)
}

Copy-Item $GodotExe (Join-Path $BuildDir 'RocketLanding.exe') -Force

# --- copy release into rocket-ai ---
Copy-Item (Join-Path $BuildDir 'RocketLanding.exe') (Join-Path $RocketAi 'RocketLanding.exe') -Force
Copy-Item (Join-Path $BuildDir 'RocketLanding.pck') (Join-Path $RocketAi 'RocketLanding.pck') -Force
Copy-Item (Join-Path $ProjectDir 'API_README.md')   (Join-Path $RocketAi 'API_README.md')   -Force

Write-Host ""
Write-Host "==> done. artifacts:"
Write-Host "   $BuildDir\RocketLanding.exe"
Write-Host "   $BuildDir\RocketLanding.pck"
Write-Host "   $RocketAi\RocketLanding.exe (copied)"
Write-Host "   $RocketAi\RocketLanding.pck (copied)"
Write-Host "   $RocketAi\API_README.md   (copied)"
