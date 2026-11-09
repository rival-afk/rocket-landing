# Rocket Landing 1.1.0 - release build (Windows, ASCII-only).
# Run from repo root:
#   .\build_all.ps1                # all three targets
#   .\build_all.ps1 -Target windows
#   .\build_all.ps1 -Target linux
#   .\build_all.ps1 -Target android
# Prereqs: see docs/HANDOFF.md (Godot 4.7.2 + export templates + Android SDK + JDK).
# Honors $env:GODOT_EXE if set, else finds Godot console exe near the repo.

param(
    [ValidateSet('all', 'windows', 'linux', 'android')]
    [string]$Target = 'all'
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Get-Location).Path
if (-not (Test-Path (Join-Path $RepoRoot 'game\project.godot'))) {
    throw "Run from the repo root (folder with README.md and game\)"
}
$ProjectDir = Join-Path $RepoRoot 'game'

# --- locate Godot console exe ---
$Godot = $env:GODOT_EXE
if (-not $Godot) {
    $candidates = @(
        (Join-Path (Split-Path $RepoRoot -Parent) 'godot\Godot_v4.7.2-stable_win64_console.exe'),
        (Join-Path (Split-Path $RepoRoot -Parent) 'godot\Godot_v4.7.2-stable_win64.exe'),
        (Get-Command godot -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1)
    )
    $found = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $found) { throw "Godot not found. Set `$env:GODOT_EXE to Godot_v4.7.2-stable_win64_console.exe" }
    $Godot = $found
}
Write-Host "==> Godot: $Godot"

# --- check export templates ---
$TemplatesDir = Join-Path $env:APPDATA 'Godot\export_templates\4.7.2.stable'
if (-not (Test-Path $TemplatesDir)) {
    throw "Export templates not found at $TemplatesDir - see docs/HANDOFF.md step 0"
}
Write-Host "==> Templates: $TemplatesDir"

# --- version / commit / date ---
$m = Select-String -Path (Join-Path $ProjectDir 'project.godot') -Pattern 'config/version\s*=\s*"([^"]+)"'
$Version = if ($m) { $m.Matches[0].Groups[1].Value } else { '0.0.0' }
$Commit = 'nogit'
try { $Commit = (& git -C $RepoRoot rev-parse --short HEAD).Trim() } catch { Write-Host "warn: git unavailable - COMMIT=nogit" }
$BuildDate = Get-Date -Format 'yyyy-MM-dd'
Write-Host "==> Rocket Landing v$Version ($Commit) $BuildDate - target: $Target"

# --- stamp game.gd (restored in finally) ---
$gameGd = Join-Path $ProjectDir 'game.gd'
$original = [System.IO.File]::ReadAllText($gameGd, [System.Text.Encoding]::UTF8)
$Stamped = $false
$exitCode = 0

try {
    if ($Target -in @('all', 'windows', 'linux', 'android')) {
        $t = $original
        $t = [regex]::Replace($t, 'const VERSION := "[^"]*"',  'const VERSION := "' + $Version + '"')
        $t = [regex]::Replace($t, 'const COMMIT := "[^"]*"',   'const COMMIT := "' + $Commit + '"')
        $t = [regex]::Replace($t, 'const BUILD_DATE := "[^"]*"', 'const BUILD_DATE := "' + $BuildDate + '"')
        [System.IO.File]::WriteAllText($gameGd, $t, [System.Text.Encoding]::UTF8)
        $Stamped = $true
    }

    New-Item -ItemType Directory -Force "$RepoRoot\build\windows" | Out-Null
    New-Item -ItemType Directory -Force "$RepoRoot\build\linux" | Out-Null
    New-Item -ItemType Directory -Force "$RepoRoot\build\android" | Out-Null

    if ($Target -in @('all', 'windows')) {
        Write-Host "==> [1/3] Windows Desktop -> build\windows\RocketLanding.exe"
        & $Godot --headless --path $ProjectDir --export-release "Windows Desktop" "$RepoRoot\build\windows\RocketLanding.exe" 2>&1 | Select-Object -Last 6
        if (-not (Test-Path "$RepoRoot\build\windows\RocketLanding.exe")) { throw "Windows export failed" }
    }

    if ($Target -in @('all', 'linux')) {
        Write-Host "==> [2/3] Linux (Debian) -> build\linux\RocketLanding + .tar.gz"
        & $Godot --headless --path $ProjectDir --export-release "Linux (Debian)" "$RepoRoot\build\linux\RocketLanding" 2>&1 | Select-Object -Last 6
        if (-not (Test-Path "$RepoRoot\build\linux\RocketLanding")) { throw "Linux export failed" }
        if (Test-Path "$RepoRoot\build\linux\RocketLanding-linux-x86_64.tar.gz") {
            Remove-Item "$RepoRoot\build\linux\RocketLanding-linux-x86_64.tar.gz" -Force
        }
        Push-Location "$RepoRoot\build\linux"
        try {
            & tar -czf RocketLanding-linux-x86_64.tar.gz RocketLanding RocketLanding.pck
            Write-Host "    tar.gz ok"
        } finally {
            Pop-Location
        }
    }

    if ($Target -in @('all', 'android')) {
        if ($env:ANDROID_SDK_ROOT) { Write-Host "==> ANDROID_SDK_ROOT: $($env:ANDROID_SDK_ROOT)" }
        elseif ($env:ANDROID_HOME) { Write-Host "==> ANDROID_HOME: $($env:ANDROID_HOME)" }
        else { Write-Host "warn: ANDROID_SDK_ROOT/ANDROID_HOME not set - hoping Godot finds the SDK from settings" }
        Write-Host "==> [3/3] Android -> build\android\RocketLanding.apk"
        & $Godot --headless --path $ProjectDir --export-release "Android" "$RepoRoot\build\android\RocketLanding.apk" 2>&1 | Select-Object -Last 8
        if (-not (Test-Path "$RepoRoot\build\android\RocketLanding.apk")) { throw "Android export failed" }
    }
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)"
    $exitCode = 1
}
finally {
    if ($Stamped) {
        [System.IO.File]::WriteAllText($gameGd, $original, [System.Text.Encoding]::UTF8)
    }
}

if ($exitCode -ne 0) { exit $exitCode }

Write-Host ""
Write-Host "==> artifacts:"
$artifacts = @()
$artifacts += "$RepoRoot\build\windows\RocketLanding.exe"
$artifacts += "$RepoRoot\build\windows\RocketLanding.pck"
$artifacts += "$RepoRoot\build\linux\RocketLanding"
$artifacts += "$RepoRoot\build\linux\RocketLanding.pck"
$artifacts += "$RepoRoot\build\linux\RocketLanding-linux-x86_64.tar.gz"
$artifacts += "$RepoRoot\build\android\RocketLanding.apk"
foreach ($a in $artifacts) {
    if (Test-Path $a) {
        $h = (Get-FileHash $a -Algorithm SHA256).Hash.ToLower()
        $sz = (Get-Item $a).Length
        Write-Host ("{0,10}  {1}  {2}" -f $sz, $h, $a)
    }
}
Write-Host ""
Write-Host "Next: gh release create v$Version --notes-file docs\RELEASE_NOTES_1.1.0.md <artifacts>"
