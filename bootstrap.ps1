<# 
    Synced PowerShell Bootstrap (Hardened)
    --------------------------------------
    - Run from Windows PowerShell 5.1 or PowerShell 7+
    - Ensures latest PowerShell 7 is installed (silent)
    - Ensures Git for Windows is installed (silent, defaults)
    - Clones/repairs https://github.com/tylerhjames/powershell-profile.git
    - Writes loader to PS7 profile: $PROFILE.CurrentUserCurrentHost
    - Safe to run repeatedly: fixes partial installs
#>

# --- TLS hardening (for PS 5.1) ----------------------------------------------
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.SecurityProtocolType]::Tls12 `
        -bor [Net.SecurityProtocolType]::Tls13
} catch { }

# --- basic helpers -----------------------------------------------------------
function Write-Info { param([string]$Message) Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "[ OK ] $Message"   -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[WARN] $Message"   -ForegroundColor Yellow }
function Write-Err  { param([string]$Message) Write-Host "[FAIL] $Message"   -ForegroundColor Red }

function Test-IsAdmin {
    try {
        $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pri = New-Object Security.Principal.WindowsPrincipal($id)
        return $pri.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
    } catch { return $false }
}

if (-not (Test-IsAdmin)) {
    Write-Warn "Bootstrap is not running elevated. Installing PS7/Git system-wide may fail."
    Write-Warn "If you hit errors, run this again in an elevated PowerShell window."
}

$bootstrapUrl = "https://raw.githubusercontent.com/tylerhjames/powershell-profile/main/bootstrap.ps1"

# --- Ensure PowerShell 7 ------------------------------------------------------
function Ensure-PowerShell7 {
    param([switch]$RelaunchIfNeeded)

    $currentMajor = $PSVersionTable.PSVersion.Major
    if ($currentMajor -ge 7) {
        Write-Ok "Already running under PowerShell $($PSVersionTable.PSVersion)."
        return
    }

    $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $pwshCmd) {
        Write-Info "PowerShell 7 not found. Downloading latest PowerShell 7 MSI..."

        try {
            $release = Invoke-RestMethod -Uri "https://api.github.com/repos/PowerShell/PowerShell/releases/latest" -UseBasicParsing
            $asset   = $release.assets | Where-Object { $_.name -like "*win-x64.msi" } | Select-Object -First 1
            if (-not $asset) { throw "No suitable PowerShell 7 MSI asset found." }

            $msiPath = Join-Path $env:TEMP "pwsh7-latest.msi"
            Write-Info "Downloading $($asset.browser_download_url)"
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $msiPath -UseBasicParsing

            Write-Info "Installing PowerShell 7 silently..."
            $args = "/i `"$msiPath`" /qn ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1 ENABLE_PSREMOTING=1"
            Start-Process msiexec.exe -ArgumentList $args -Wait
            Write-Ok "PowerShell 7 installation completed."
        } catch {
            Write-Err "Failed to download or install PowerShell 7. $_"
            return
        }
    } else {
        Write-Ok "PowerShell 7 is already installed on this system."
    }

    if ($RelaunchIfNeeded -and $currentMajor -lt 7) {
        Write-Info "Relaunching bootstrap under PowerShell 7..."
        try {
            & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "iwr '$bootstrapUrl' -UseBasicParsing | iex"
        } catch {
            Write-Err "Failed to relaunch bootstrap under PowerShell 7. $_"
        }
        exit
    }
}

Ensure-PowerShell7 -RelaunchIfNeeded

# --- Ensure Git for Windows ---------------------------------------------------
function Ensure-Git {
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if ($gitCmd) {
        Write-Ok "Git already installed: $($gitCmd.Source)"
        return
    }

    Write-Info "Git not found. Downloading latest Git for Windows (64-bit)..."

    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/git-for-windows/git/releases/latest" -UseBasicParsing
        $asset   = $release.assets | Where-Object { $_.name -like "*64-bit.exe" } | Select-Object -First 1
        if (-not $asset) { throw "No suitable Git for Windows installer found." }

        $gitExe = Join-Path $env:TEMP "git-latest-64bit.exe"
        Write-Info "Downloading $($asset.browser_download_url)"
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $gitExe -UseBasicParsing

        Write-Info "Installing Git for Windows silently with default options..."
        $args = "/VERYSILENT /NORESTART"
        Start-Process $gitExe -ArgumentList $args -Wait
        Write-Ok "Git installation completed."
    } catch {
        Write-Err "Failed to download or install Git for Windows. $_"
    }
}

Ensure-Git

# --- Ensure profile repo exists & is healthy ----------------------------------
$profileRepoRoot = Join-Path $HOME "Documents\Git"
$profileRepoPath = Join-Path $profileRepoRoot "powershell-profile"
$profileRepoUrl  = "https://github.com/tylerhjames/powershell-profile.git"

if (-not (Test-Path $profileRepoRoot)) {
    Write-Info "Creating Git root folder at $profileRepoRoot"
    New-Item -ItemType Directory -Path $profileRepoRoot -Force | Out-Null
}

if (-not (Test-Path $profileRepoPath)) {
    Write-Info "Cloning profile repository from $profileRepoUrl"
    try {
        git clone $profileRepoUrl $profileRepoPath
        Write-Ok "Repository cloned to $profileRepoPath"
    } catch {
        Write-Err "Failed to clone repository. $_"
    }
} else {
    # Check if this looks like a valid git repo
    if (-not (Test-Path (Join-Path $profileRepoPath ".git"))) {
        $brokenPath = "$profileRepoPath.broken.$((Get-Date).ToString('yyyyMMddHHmmss'))"
        Write-Warn "Existing folder at $profileRepoPath is not a Git repo. Renaming to $brokenPath"
        Rename-Item -Path $profileRepoPath -NewName $brokenPath
        Write-Info "Cloning clean repository..."
        git clone $profileRepoUrl $profileRepoPath
        Write-Ok "Repository re-cloned to $profileRepoPath"
    } else {
        Write-Info "Profile repository exists. Checking for updates..."
        try {
            Push-Location $profileRepoPath
            git fetch --all | Out-Null
            git pull --ff-only
            Write-Ok "Repository is up to date."
        } catch {
            Write-Warn "Could not update repository (may be offline or have local changes)."
        } finally {
            Pop-Location
        }
    }
}

# --- Ensure PS7 loader profile is correct ------------------------------------
# We want PS7's host-specific profile: e.g. Microsoft.PowerShell_profile.ps1
$loaderPath = $PROFILE.CurrentUserCurrentHost
$loaderDir  = Split-Path $loaderPath -Parent

if (-not (Test-Path $loaderDir)) {
    Write-Info "Creating profile directory at $loaderDir"
    New-Item -ItemType Directory -Path $loaderDir -Force | Out-Null
}

$loaderContent = @"
# Synced PowerShell profile loader (managed by bootstrap.ps1)
# Do not edit this file directly; edit the Git-based Profile.ps1 instead.

\$profileRepo = "$profileRepoPath"
\$profileFile = Join-Path \$profileRepo "Profile.ps1"

if (-not (Test-Path \$profileFile)) {
    Write-Host "⚠ Git-based profile not found at \$profileFile" -ForegroundColor Yellow
} else {
    . \$profileFile
}
"@

Write-Info "Writing loader profile to $loaderPath"
$loaderContent | Set-Content -Path $loaderPath -Encoding UTF8

# Optional: clean up old/legacy loader in this folder if it matches our marker
$legacyPath = Join-Path $loaderDir "profile.ps1"
if (Test-Path $legacyPath) {
    $firstLine = (Get-Content $legacyPath -TotalCount 1 -ErrorAction SilentlyContinue)
    if ($firstLine -like "*Synced PowerShell profile loader*") {
        Write-Info "Removing legacy loader profile at $legacyPath"
        Remove-Item $legacyPath -Force -ErrorAction SilentlyContinue
    }
}

# --- Final status -------------------------------------------------------------
Write-Host ""
Write-Ok "Synced PowerShell environment is ready on this machine."
Write-Ok "Repo   : $profileRepoPath"
Write-Ok "Loader : $loaderPath"
Write-Host ""
Write-Info "Close this window and open a new PowerShell 7 session to start using your roaming profile."
Write-Host ""
