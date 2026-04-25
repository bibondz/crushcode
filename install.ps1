# Crushcode installer for Windows — https://github.com/bibondz/crushcode
# Usage: irm https://github.com/bibondz/crushcode/raw/main/install.ps1 | iex
# Or:   ./install.ps1 [-Version X.Y.Z] [-Uninstall]

param(
    [string]$Version = "",
    [switch]$Uninstall,
    [switch]$Help
)

$Repo = "bibondz/crushcode"
$BinaryName = "crushcode"
$InstallDir = "$env:LOCALAPPDATA\crushcode"

# --- Banner ---
function Show-Banner {
    Write-Host ""
    Write-Host "  Crushcode Installer" -ForegroundColor Cyan
    Write-Host "  https://github.com/$Repo" -ForegroundColor DarkGray
    Write-Host ""
}

# --- Help ---
if ($Help) {
    Show-Banner
    Write-Host "Usage:" -ForegroundColor Yellow
    Write-Host "  irm https://github.com/$Repo/raw/main/install.ps1 | iex"
    Write-Host "  ./install.ps1 -Version 1.0.0"
    Write-Host "  ./install.ps1 -Uninstall"
    exit 0
}

# --- Uninstall ---
if ($Uninstall) {
    Show-Banner
    Write-Host "  -> Uninstalling $BinaryName..." -ForegroundColor Yellow

    $found = $false
    foreach ($dir in @($InstallDir)) {
        $path = Join-Path $dir "$BinaryName.exe"
        if (Test-Path $path) {
            Remove-Item $path -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path $path)) {
                Write-Host "  -> Removed $path" -ForegroundColor Green
                $found = $true
            }
        }
    }

    if (-not $found) {
        Write-Host "  -> $BinaryName not found in $InstallDir" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "  Uninstallation complete." -ForegroundColor Green
    Write-Host "  You may want to remove $InstallDir from your PATH." -ForegroundColor DarkGray
    Write-Host ""
    exit 0
}

# --- Main Install ---
Show-Banner

# Detect architecture
$Arch = switch ($env:PROCESSOR_ARCHITECTURE) {
    "AMD64"   { "x86_64" }
    "ARM64"   { "aarch64" }
    default   { "x86_64" }
}

$Target = "$Arch-windows-gnu"

# Build download URL
if ($Version -ne "") {
    $DownloadUrl = "https://github.com/$Repo/releases/download/v$Version/$BinaryName-$Target.exe"
} else {
    $DownloadUrl = "https://github.com/$Repo/releases/latest/download/$BinaryName-$Target.exe"
}

$DestPath = Join-Path $InstallDir "$BinaryName.exe"

Write-Host "  -> Platform: $Target" -ForegroundColor Cyan
Write-Host "  -> Installing to $DestPath" -ForegroundColor Cyan

# Create install directory
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Write-Host "  -> Created $InstallDir" -ForegroundColor DarkGray
}

# Download
Write-Host "  -> Downloading $DownloadUrl"
try {
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $DestPath -UseBasicParsing
} catch {
    Write-Host "  Error: Download failed: $_" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $DestPath)) {
    Write-Host "  Error: Downloaded file not found" -ForegroundColor Red
    exit 1
}

Write-Host "  -> Downloaded OK" -ForegroundColor Green

# --- PATH setup ---
$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($UserPath -notlike "*$InstallDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$UserPath;$InstallDir", "User")
    Write-Host "  -> Added $InstallDir to user PATH" -ForegroundColor Green
    # Update current session
    $env:Path = "$env:Path;$InstallDir"
} else {
    Write-Host "  -> $InstallDir already in PATH" -ForegroundColor DarkGray
}

# --- Done ---
Write-Host ""
Write-Host "  Installation complete!" -ForegroundColor Green
Write-Host "  Run '$BinaryName --help' to get started." -ForegroundColor Cyan
Write-Host ""

# Verify
$installed = Get-Command $BinaryName -ErrorAction SilentlyContinue
if ($installed) {
    Write-Host "  Verified: $($installed.Source)" -ForegroundColor DarkGray
} else {
    Write-Host "  Note: Restart your terminal for PATH to take effect." -ForegroundColor Yellow
}

Write-Host ""
