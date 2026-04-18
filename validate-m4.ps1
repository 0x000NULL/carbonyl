<#
.SYNOPSIS
  End-to-end validation for the M4 Windows Chromium runtime build.

.DESCRIPTION
  Drives the full pipeline documented in the M4 plan:
    1. Preflight (tools, disk, VS install, long paths)
    2. Submodule init
    3. gclient sync (~1-3 hours, ~100 GB)
    4. patches.sh apply
    5. Write args.gn + gn gen (skips the interactive editor prompt)
    6. build.sh (~1-3 hours)
    7. Verify expected outputs
    8. Smoke test via run.sh

  Each stage is gated and can be skipped for retries. Full transcript is
  written to build-m4.log in the repo root.

.PARAMETER SkipSync
  Skip gclient sync. Use when the Chromium tree is already fetched.

.PARAMETER SkipPatches
  Skip patches.sh apply. Use when patches are already applied.

.PARAMETER SkipBuild
  Stop after gn gen. Useful for validating the configure step alone.

.PARAMETER SkipSmokeTest
  Skip the final run.sh smoke test (which is interactive).

.PARAMETER Target
  Chromium build target subdirectory name under chromium/src/out/.
  Default: win-x64.

.PARAMETER Url
  URL to load in the smoke test. Default: https://example.com.

.EXAMPLE
  .\validate-m4.ps1
  # Full run from scratch.

.EXAMPLE
  .\validate-m4.ps1 -SkipSync
  # Retry after a failed patches/build stage without re-fetching Chromium.

.EXAMPLE
  .\validate-m4.ps1 -SkipSync -SkipPatches -SkipSmokeTest
  # Iterate on build-only failures.
#>
[CmdletBinding()]
param(
    [switch]$SkipSync,
    [switch]$SkipPatches,
    [switch]$SkipBuild,
    [switch]$SkipSmokeTest,
    [string]$Target = "win-x64",
    [string]$Url = "https://example.com"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$carbonylRoot = (Resolve-Path $scriptDir).Path
$logPath      = Join-Path $carbonylRoot 'build-m4.log'
$gitBash      = $null   # set during preflight

Push-Location $carbonylRoot

# Start fresh transcript (Stop any running transcript first so -Force works on PS 5.1)
try { Stop-Transcript | Out-Null } catch {}
Start-Transcript -Path $logPath -Force | Out-Null

function Write-Stage {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ("=" * 72) -ForegroundColor Cyan
}

function Invoke-Bash {
    param([string]$Command, [string]$Label)
    if (-not $script:gitBash) {
        throw "Git Bash path not resolved (preflight should have set it)."
    }
    Write-Host ""
    Write-Host "> $Label" -ForegroundColor Yellow
    Write-Host "  $Command" -ForegroundColor DarkGray
    & $script:gitBash -c $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed (bash exit $LASTEXITCODE)"
    }
}

function Resolve-GitBash {
    # On a stock Windows install with both WSL and Git for Windows, `bash`
    # on PATH resolves to WSL's C:\Windows\System32\bash.exe first, which
    # cannot run depot_tools (a Windows-native toolchain). Prefer Git Bash
    # explicitly.
    $candidates = @(
        (Join-Path $env:ProgramFiles        'Git\bin\bash.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'),
        'C:\Program Files\Git\bin\bash.exe',
        'C:\Program Files (x86)\Git\bin\bash.exe'
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }

    # Last resort: `git --exec-path` lives inside the Git for Windows tree,
    # so bash.exe is typically two levels up under bin/.
    $gitExec = (& git --exec-path 2>$null)
    if ($gitExec) {
        $guess = Join-Path (Split-Path -Parent (Split-Path -Parent $gitExec)) 'bin\bash.exe'
        if (Test-Path $guess) { return $guess }
    }

    return $null
}

function Assert-Tool {
    param([string]$Name, [string]$Hint)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required tool '$Name' is not on PATH. $Hint"
    }
    $path = (Get-Command $Name).Source
    Write-Host ("  [OK] {0,-10} {1}" -f $Name, $path) -ForegroundColor Green
}

try {
    # ---- Stage 0: preflight ------------------------------------------------
    Write-Stage "Stage 0: preflight"

    Assert-Tool 'git'    "Install Git for Windows."
    Assert-Tool 'python' "Install Python 3 and add it to PATH."
    Assert-Tool 'cargo'  "Install Rust via rustup-init.exe from https://rustup.rs."

    # Resolve Git Bash (NOT WSL bash). On stock Windows both WSL's bash.exe
    # and Git Bash are often installed; the PATH usually picks WSL first.
    $script:gitBash = Resolve-GitBash
    if (-not $script:gitBash) {
        throw "Git Bash (bash.exe from Git for Windows) not found. Install Git for Windows from https://gitforwindows.org."
    }
    Write-Host ("  [OK] {0,-10} {1}" -f 'git-bash', $script:gitBash) -ForegroundColor Green

    # Flag WSL bash on PATH so the user knows why we bypass it
    $pathBash = (Get-Command bash -ErrorAction SilentlyContinue)
    if ($pathBash -and $pathBash.Source -like '*System32\bash.exe') {
        Write-Host "  [INFO] PATH 'bash' is WSL ($($pathBash.Source)); using Git Bash explicitly instead." -ForegroundColor Yellow
    }

    # Long paths (git + filesystem)
    $longPathsGit = (& git config --global --get core.longpaths) 2>$null
    if ($longPathsGit -ne 'true') {
        Write-Host "  Setting git config --global core.longpaths true" -ForegroundColor Yellow
        & git config --global core.longpaths true
    } else {
        Write-Host "  [OK] git core.longpaths = true" -ForegroundColor Green
    }

    $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
    $longPathsFs = (Get-ItemProperty -Path $regPath -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled
    if ($longPathsFs -ne 1) {
        Write-Warning "Windows LongPathsEnabled is not set. Chromium paths may exceed MAX_PATH."
        Write-Warning "Fix (admin PowerShell): Set-ItemProperty '$regPath' LongPathsEnabled 1"
    } else {
        Write-Host "  [OK] Windows LongPathsEnabled = 1" -ForegroundColor Green
    }

    # Disk space
    $driveLetter = (Split-Path -Qualifier $carbonylRoot).TrimEnd(':')
    $drive = Get-PSDrive $driveLetter -ErrorAction SilentlyContinue
    if ($drive) {
        $freeGb = [math]::Round($drive.Free / 1GB, 1)
        if ($drive.Free -lt 120GB) {
            Write-Warning "Only $freeGb GB free on ${driveLetter}: drive. Chromium needs ~100 GB + margin."
        } else {
            Write-Host "  [OK] $freeGb GB free on ${driveLetter}:" -ForegroundColor Green
        }
    }

    # Visual Studio with C++ workload
    $vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vsWhere) {
        $vsJson = & $vsWhere -latest -products '*' -requires 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' -format json 2>$null
        if ($vsJson) {
            $vsInfo = $vsJson | ConvertFrom-Json
            if ($vsInfo -and $vsInfo.Count -gt 0) {
                Write-Host "  [OK] Visual Studio: $($vsInfo[0].displayName) @ $($vsInfo[0].installationPath)" -ForegroundColor Green
            } else {
                Write-Warning "No VS install with 'Desktop development with C++' workload found."
            }
        }
    } else {
        Write-Warning "vswhere.exe not found at $vsWhere -- can't auto-verify VS install."
    }

    # Env for depot_tools (non-Googlers)
    $env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'
    Write-Host "  [OK] DEPOT_TOOLS_WIN_TOOLCHAIN=0" -ForegroundColor Green

    # Shell script line endings. Git for Windows defaults to core.autocrlf=true
    # which converts *.sh to CRLF on checkout; that breaks `#!/usr/bin/env bash`
    # under msys because env looks for a program named literally `bash\r`.
    $autocrlf = (& git config --get core.autocrlf) 2>$null
    if ($autocrlf -eq 'true' -or $autocrlf -eq 'input') {
        Write-Host "  Disabling core.autocrlf locally (was: $autocrlf)" -ForegroundColor Yellow
        & git config core.autocrlf false
    } else {
        Write-Host "  [OK] core.autocrlf=$autocrlf" -ForegroundColor Green
    }

    $fixed = 0
    Get-ChildItem -Path (Join-Path $carbonylRoot 'scripts') -Filter *.sh -File | ForEach-Object {
        $bytes = [IO.File]::ReadAllBytes($_.FullName)
        if ($bytes -contains 13) {
            $text = [Text.Encoding]::UTF8.GetString($bytes) -replace "`r`n", "`n"
            [IO.File]::WriteAllBytes($_.FullName, [Text.Encoding]::UTF8.GetBytes($text))
            $fixed++
        }
    }
    if ($fixed -gt 0) {
        Write-Host "  Normalized CRLF -> LF in $fixed shell script(s) under scripts/" -ForegroundColor Yellow
        Write-Host "  (These will show as modified in 'git status'; that's expected.)" -ForegroundColor DarkGray
    } else {
        Write-Host "  [OK] scripts/*.sh already have LF line endings" -ForegroundColor Green
    }

    # Branch
    $branch = (& git rev-parse --abbrev-ref HEAD).Trim()
    Write-Host "  Branch: $branch"
    if ($branch -ne 'feat/windows-chromium-runtime') {
        Write-Host "  Switching to feat/windows-chromium-runtime..." -ForegroundColor Yellow
        & git fetch origin
        & git checkout feat/windows-chromium-runtime
        & git pull --ff-only origin feat/windows-chromium-runtime
    }

    # ---- Stage 1: submodules ----------------------------------------------
    Write-Stage "Stage 1: init submodules (depot_tools)"
    Invoke-Bash "git submodule update --init --recursive" "git submodule update"

    # ---- Stage 2: gclient sync --------------------------------------------
    if ($SkipSync) {
        Write-Stage "Stage 2: gclient sync [SKIPPED]"
    } else {
        Write-Stage "Stage 2: gclient sync (~1-3 hours, ~100 GB)"
        Write-Host "Safe to step away. Re-run with -SkipSync if it completes and a later stage fails." -ForegroundColor Yellow
        Invoke-Bash "./scripts/gclient.sh sync" "gclient sync"
    }

    # ---- Stage 3: patches -------------------------------------------------
    if ($SkipPatches) {
        Write-Stage "Stage 3: patches.sh apply [SKIPPED]"
    } else {
        Write-Stage "Stage 3: patches.sh apply"
        Write-Host "This resets chromium/src, third_party/skia, third_party/webrtc to the" -ForegroundColor Yellow
        Write-Host "pinned upstream SHAs and runs git am over the Carbonyl patch stack." -ForegroundColor Yellow
        Invoke-Bash "./scripts/patches.sh apply" "patches.sh apply"
    }

    # ---- Stage 4: configure (write args.gn + gn gen) ----------------------
    Write-Stage "Stage 4: configure (gn gen)"
    $chromiumSrc = Join-Path $carbonylRoot 'chromium\src'
    $outDir      = Join-Path $chromiumSrc "out\$Target"
    if (-not (Test-Path $chromiumSrc)) {
        throw "chromium/src not found at $chromiumSrc -- did gclient sync complete?"
    }
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null

    $argsGnBody = @'
import("//carbonyl/src/browser/args.gn")

target_cpu = "x64"

# MSVC / Windows knobs
use_lld = true
symbol_level = 1
is_win_fastlink = false

is_debug = false
is_official_build = true
'@
    Set-Content -Path (Join-Path $outDir 'args.gn') -Value $argsGnBody -Encoding ASCII
    Write-Host "  Wrote $outDir\args.gn"
    Invoke-Bash "./scripts/gn.sh gen out/$Target" "gn gen out/$Target"

    # ---- Stage 5: build ---------------------------------------------------
    if ($SkipBuild) {
        Write-Stage "Stage 5: build [SKIPPED]"
    } else {
        Write-Stage "Stage 5: build (~1-3 hours)"
        Write-Host "Ninja builds incrementally, so if this is interrupted just re-run the script." -ForegroundColor Yellow
        Invoke-Bash "./scripts/build.sh $Target amd64" "build.sh $Target amd64"
    }

    # ---- Stage 6: verify expected outputs --------------------------------
    Write-Stage "Stage 6: verify outputs"
    $expected = @(
        'headless_shell.exe',
        'carbonyl.dll',
        'carbonyl.dll.lib',
        'libEGL.dll',
        'libGLESv2.dll',
        'icudtl.dat'
    )
    $missing = @()
    foreach ($name in $expected) {
        $f = Join-Path $outDir $name
        if (Test-Path $f) {
            $mb = [math]::Round((Get-Item $f).Length / 1MB, 2)
            Write-Host ("  [OK] {0,-22} ({1,7} MB)" -f $name, $mb) -ForegroundColor Green
        } else {
            Write-Host "  [MISSING] $f" -ForegroundColor Red
            $missing += $name
        }
    }
    # Optional but nice to have
    $optional = @('v8_context_snapshot.bin')
    foreach ($name in $optional) {
        $f = Join-Path $outDir $name
        if (Test-Path $f) {
            $mb = [math]::Round((Get-Item $f).Length / 1MB, 2)
            Write-Host ("  [OK] {0,-22} ({1,7} MB)" -f $name, $mb) -ForegroundColor Green
        } else {
            # Sometimes emitted with a prefix (e.g. v8_context_snapshot.x86_64.bin)
            $glob = Get-ChildItem -Path $outDir -Filter 'v8_context_snapshot*.bin' -ErrorAction SilentlyContinue
            if ($glob) {
                Write-Host ("  [OK] v8_context_snapshot*.bin matched {0}" -f $glob[0].Name) -ForegroundColor Green
            } else {
                Write-Warning "  [?] $name not found (may be non-fatal depending on Chromium version)"
            }
        }
    }

    if ($missing.Count -gt 0) {
        throw "$($missing.Count) required output(s) missing -- build likely failed. See $logPath."
    }

    # ---- Stage 7: smoke test ---------------------------------------------
    if ($SkipSmokeTest) {
        Write-Stage "Stage 7: smoke test [SKIPPED]"
    } else {
        Write-Stage "Stage 7: smoke test"
        Write-Host "About to launch: ./scripts/run.sh $Target $Url" -ForegroundColor Yellow
        Write-Host "This runs headless_shell.exe in Windows Terminal. Quit with Ctrl+C when the page renders." -ForegroundColor Yellow
        $response = Read-Host "Press Enter to continue, or type 'skip' then Enter to skip"
        if ($response -ne 'skip') {
            Invoke-Bash "./scripts/run.sh $Target $Url" "run.sh"
        }
    }

    Write-Stage "SUCCESS"
    Write-Host "All M4 validation stages passed." -ForegroundColor Green
    Write-Host "Full log: $logPath" -ForegroundColor DarkGray
}
catch {
    Write-Host ""
    Write-Host "FAILED: $_" -ForegroundColor Red
    Write-Host "Full log: $logPath" -ForegroundColor Red
    Write-Host "Resume options:" -ForegroundColor Yellow
    Write-Host "  .\validate-m4.ps1 -SkipSync                # re-run from patches onward"
    Write-Host "  .\validate-m4.ps1 -SkipSync -SkipPatches   # re-run from configure onward"
    Write-Host "  .\validate-m4.ps1 -SkipSync -SkipPatches -SkipSmokeTest"
    exit 1
}
finally {
    Stop-Transcript | Out-Null
    Pop-Location
}
