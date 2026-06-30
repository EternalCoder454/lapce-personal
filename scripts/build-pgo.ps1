<#
.SYNOPSIS
    Profile-Guided Optimization (PGO) build for Lapce Personal (Windows).

.DESCRIPTION
    Produces an optimized lapce.exe in three stages:
      1. Build an *instrumented* binary (-C profile-generate).
      2. Exercise the hot paths to collect a profile:
           - the criterion benchmarks (search + visual_line) — these exit cleanly
             so their .profraw is always written;
           - a short real editor session (closed gracefully via WM_CLOSE so the
             profiler's atexit handler flushes — a force-kill would NOT).
      3. Rebuild with -C profile-use, merging the collected profile.

    PGO is NOT part of the default build: the profile must be regenerated for it
    to stay representative, so it is a deliberate, occasional step rather than
    something baked into `cargo build`. Run this when you want a maximally tuned
    local binary.

    Requires the llvm-tools-preview component:
        rustup component add llvm-tools-preview

.PARAMETER Profile
    Cargo profile to build (default: release-lto). Use "release" for faster
    iteration while testing the PGO flow.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts/build-pgo.ps1
#>
param([string]$Profile = "release-lto")

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$env:Path = "$env:USERPROFILE\.cargo\bin;$env:Path"

$profdata = (Get-ChildItem "$env:USERPROFILE\.rustup\toolchains\*\lib\rustlib\*\bin\llvm-profdata.exe" -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
if (-not $profdata) { throw "llvm-profdata not found. Run: rustup component add llvm-tools-preview" }

# These mirror .cargo/config.toml; RUSTFLAGS replaces (not merges with) the
# config rustflags, so we must repeat crt-static + target-cpu here.
$base = "-C target-feature=+crt-static -C target-cpu=x86-64-v3"

$pgo = Join-Path $root "target\pgo-data"
Remove-Item -Recurse -Force $pgo -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $pgo | Out-Null

$exe = if ($Profile -eq "release-lto") { "target\release-lto\lapce.exe" } else { "target\release\lapce.exe" }

Write-Host "[1/4] Building instrumented binary ($Profile)..." -ForegroundColor Cyan
$env:RUSTFLAGS = "$base -C profile-generate=$pgo"
cargo build --profile $Profile --bin lapce --bin lapce-proxy
if ($LASTEXITCODE -ne 0) { throw "instrumented build failed" }

Write-Host "[2/4] Collecting profile (benchmarks + short editor session)..." -ForegroundColor Cyan
cargo bench -p lapce-proxy --bench search    | Out-Null
cargo bench -p lapce-app   --bench visual_line | Out-Null
# Real session: open the repo, let it warm up, then close gracefully so profraw flushes.
$p = Start-Process -FilePath $exe -ArgumentList "--new", "--wait", $root -PassThru
Start-Sleep -Seconds 25
$p.CloseMainWindow() | Out-Null
if (-not $p.WaitForExit(15000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
Get-Process -Name lapce, lapce-proxy -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

Write-Host "[3/4] Merging profile data..." -ForegroundColor Cyan
$merged = Join-Path $pgo "merged.profdata"
$raw = Get-ChildItem "$pgo\*.profraw"
if (-not $raw) { throw "no .profraw collected — training produced no profile" }
& $profdata merge -o $merged $raw
Write-Host "  merged $($raw.Count) raw profiles -> $merged"

Write-Host "[4/4] Building PGO-optimized binary ($Profile)..." -ForegroundColor Cyan
$env:RUSTFLAGS = "$base -C profile-use=$merged"
cargo build --profile $Profile --bin lapce --bin lapce-proxy
$code = $LASTEXITCODE
Remove-Item Env:\RUSTFLAGS
if ($code -ne 0) { throw "PGO build failed" }

Write-Host "Done. PGO-optimized binary: $exe" -ForegroundColor Green
