<# 
    Synced PowerShell Bootstrap
    ---------------------------
    - Can be run from Windows PowerShell 5.1 or PowerShell 7+
    - Installs latest PowerShell 7 (if needed)
    - Installs latest Git for Windows (if needed)
    - Clones / updates https://github.com/tylerhjames/powershell-profile
    - Installs core modules
    - Writes loader to $PROFILE.CurrentUserAllHosts (replacing any existing loader)
    - Intended for MSP tech machines with auto-update enabled
#>

# region helpers ----------------------------------------------------------------

# Make sure TLS 1.2+ is enabled (needed for GitHub API / downloads on PS5)
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol `
        -bor [Net.SecurityProtocolType]::Tls12 `
        -bor [Net.SecurityProtocolType]::Tls13
} catch { }

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[ OK ] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Message)
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function Test-IsAdmin {
    try {
        $current = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($current)
        return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
    } catch {
        return $false
    }
}

# endregion helpers -------------------------------------------------------------

# region elevation check --------------------------------------------------------

if (-not (Test-IsAdmin)) {
    Write-Warn "This bootstrap is best run in an elevated PowerShell session (Run as Administrator)."
    Write-Warn "Installing PowerShell 7 and Git system-wide typically requires admin rights."
    Write-Warn "If installation fails, please reopen PowerShell as Administrator and run the one-liner again."
}

# endregion elevation check -----------------------------------------------------

# region ensure PowerShell 7 ----------------------------------------------------

$bootstrapUrl = "https://raw.githubusercontent.com/tylerhjames/powershell-profile/main/bootstrap.ps1"

function Ensure-PowerShell7 {
    param(
        [switch]$RelaunchIfNeeded
    )

    $currentMajor = $PSVersionTable.PSVersion.Major
    $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue

    if ($currentMajor -ge 7) {
        Write-Ok "PowerShell $($PSVersionTable.PSVersion) already running."
        return
    }

    if (-not $pwshCmd) {
        Write-Info "PowerShell 7 not found. Attempting to download and install latest PowerShell 7..."

        try {
            $release = Invoke-RestMethod -Uri "https://api.github.com/repos/PowerShell/PowerShell/releases/latest" -UseBasicParsing
            $asset = $release.assets | Where-Object { $_.name -like "*win-x64.msi" } | Select-Object -First 1

            if (-not $asset) {
                Write-Err "Could not find a suitable PowerShell 7 MSI asset."
                return
            }

            $msiPath = Join-Path $env:TEMP "pwsh7-latest.msi"
            Write-Info "Downloading PowerShell 7 from $($asset.browser_download_url)"
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $msiPath -UseBasicParsing

            Write-Info "Installing PowerShell 7 (this may take a moment)..."
            $args = "/i `"$msiPath`" /qn ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1 ENABLE_PSREMOTING=1"
            Start-Process msiexec.exe -ArgumentList $args -Wait

            Write-Ok "PowerShell 7 installation completed."
        } catch {
            Write-Err "Failed to download or install PowerShell 7. $_"
            return
        }
    } else {
        Write-Ok "PowerShell 7 is already installed (pwsh available)."
    }

    if ($RelaunchIfNeeded -and $currentMajor -lt 7) {
        Write-Info "Relaunching bootstrap under PowerShell 7..."
        try {
            & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "iwr '$bootstrapUrl' -UseBasicParsing | iex"
        } catch {
            Write-Err "Failed to relaunch bootstrap under PowerShell 7. $_"
        }
        # After relaunch, exit this PS5 instance
        exit
    }
}

Ensure-PowerShell7 -RelaunchIfNeeded

# If still not PS7 for some reason, just continue but warn
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Warn "Still running under PowerShell $($PSVersionTable.PSVersion). Some features may not work as intended."
}

# endregion ensure PowerShell 7 -------------------------------------------------

# region ensure Git -------------------------------------------------------------

function Ensure-Git {
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if ($gitCmd) {
        Write-Ok "Git is already installed: $($gitCmd.Source)"
        return
    }

    Write-Info "Git is not installed. Attempting to download and install latest Git for Windows..."

    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/git-for-windows/git/releases/latest" -UseBasicParsing
        $asset   = $release.assets | Where-Object { $_.name -like "*64-bit.exe" } | Select-Object -First 1

        if (-not $asset) {
            Write-Err "Could not find a suitable Git for Windows installer."
            return
        }

        $gitPath = Join-Path $env:TEMP "git-latest-64bit.exe"
        Write-Info "Downloading Git from $($asset.browser_download_url)"
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $gitPath -UseBasicParsing

        Write-Info "Installing Git for Windows silently..."
        $args = "/VERYSILENT /NORESTART"
        Start-Process $gitPath -ArgumentList $args -Wait

        Write-Ok "Git installation completed."
    } catch {
        Write-Err "Failed to download or install Git for Windows. $_"
    }
}

Ensure-Git

# endregion ensure Git ----------------------------------------------------------

# region clone / update profile repo -------------------------------------------

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
    Write-Info "Profile repository already exists. Checking for updates..."
    try {
        Push-Location $profileRepoPath
        # Only fast-forward, do not merge
        git pull --ff-only
        Write-Ok "Repository updated."
    } catch {
        Write-Warn "Could not update repository (may be offline or have local changes)."
    } finally {
        Pop-Location
    }
}

# endregion clone / update profile repo ----------------------------------------

# region install core modules ---------------------------------------------------

$modulesToEnsure = @(
    'PSReadLine',
    'Microsoft.PowerShell.SecretManagement',
    'Microsoft.PowerShell.SecretStore',
    'Terminal-Icons'
)

foreach ($module in $modulesToEnsure) {
    try {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            Write-Info "Installing module: $module"
            Install-Module -Name $module -Scope CurrentUser -Force -ErrorAction Stop
            Write-Ok "Installed module: $module"
        } else {
            Write-Ok "Module already available: $module"
        }
    } catch {
        Write-Warn "Failed to install module $module (may be offline or repository blocked). $_"
    }
}

# endregion install core modules -----------------------------------------------

# region write loader profile ---------------------------------------------------

$loaderPath = $PROFILE.CurrentUserAllHosts
$loaderDir  = Split-Path $loaderPath -Parent

if (-not (Test-Path $loaderDir)) {
    Write-Info "Creating profile directory at $loaderDir"
    New-Item -ItemType Directory -Path $loaderDir -Force | Out-Null
}

$loaderContent = @"
# Synced PowerShell profile loader (managed by bootstrap.ps1)
# Do not edit this file directly; edit the Git-based Profile.ps1 instead.

\$profileRepo   = "$profileRepoPath"
\$profileFile   = Join-Path \$profileRepo "Profile.ps1"

if (\$PROFILE -ne \$profileFile) {
    Write-Host "⚠ Profile loader active — edit the Git-based Profile.ps1 instead." -ForegroundColor Yellow
}

if (Test-Path \$profileFile) {
    . \$profileFile
} else {
    Write-Host "⚠ Git-based profile not found at \$profileFile" -ForegroundColor Yellow
}
"@

Write-Info "Writing loader profile to $loaderPath (replacing existing content)."
$loaderContent | Set-Content -Path $loaderPath -Encoding UTF8

# endregion write loader profile ----------------------------------------------

# region final message ---------------------------------------------------------

Write-Host ""
Write-Ok "Synced PowerShell environment is ready."
Write-Ok "Repo: $profileRepoPath"
Write-Ok "Loader: $loaderPath"
Write-Host ""
Write-Info "Close this window and open a new PowerShell 7 session to start using your roaming profile."
Write-Host ""

# endregion final message ------------------------------------------------------
