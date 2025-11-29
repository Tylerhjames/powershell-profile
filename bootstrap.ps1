<#
    Synced PowerShell Bootstrap (Optimized & Hardened)
    ---------------------------------------------------
    - Run from Windows PowerShell 5.1 or PowerShell 7+
    - Ensures latest PowerShell 7 is installed (silent)
    - Ensures Git for Windows is installed (silent, defaults)
    - Clones/repairs https://github.com/tylerhjames/powershell-profile.git
    - Writes loader to PS7 profile: $PROFILE.CurrentUserCurrentHost
    - Safe to run repeatedly: fixes partial installs
    - Optimized: caches API responses, parallel checks, better error handling
#>

#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

# ══════════════════════════════════════════════════════════════════════════════
# Configuration
# ══════════════════════════════════════════════════════════════════════════════

$script:Config = @{
    ProfileRepoUrl    = 'https://github.com/tylerhjames/powershell-profile.git'
    ProfileRepoPath   = Join-Path $HOME 'Documents\Git\powershell-profile'
    BootstrapUrl      = 'https://raw.githubusercontent.com/tylerhjames/powershell-profile/main/bootstrap.ps1'
    MinPowerShellVer  = [version]'7.0'
    CacheDir          = Join-Path $env:TEMP 'ps-bootstrap-cache'
}

# ══════════════════════════════════════════════════════════════════════════════
# Helper Functions
# ══════════════════════════════════════════════════════════════════════════════

function Write-Info { param([string]$Message) Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "[ OK ] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Err  { param([string]$Message) Write-Host "[FAIL] $Message" -ForegroundColor Red }

function Test-IsAdmin {
    <#
    .SYNOPSIS
    Checks if current session is elevated
    #>
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
    } catch {
        return $false
    }
}

function Initialize-TLS {
    <#
    .SYNOPSIS
    Enables TLS 1.2/1.3 for older PowerShell versions
    #>
    try {
        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
    } catch {
        Write-Warn "Could not enable TLS 1.3. TLS 1.2 should still work."
    }
}

function Get-CachedWebContent {
    <#
    .SYNOPSIS
    Downloads web content with caching to avoid rate limits
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Url,
        
        [int]$CacheMinutes = 60
    )
    
    if (-not (Test-Path $Config.CacheDir)) {
        New-Item -ItemType Directory -Path $Config.CacheDir -Force | Out-Null
    }
    
    $cacheKey = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Url)) -replace '[/+=]', '_'
    $cacheFile = Join-Path $Config.CacheDir "$cacheKey.json"
    $cacheMetaFile = "$cacheFile.meta"
    
    # Check if cache is valid
    if ((Test-Path $cacheFile) -and (Test-Path $cacheMetaFile)) {
        $cacheMeta = Get-Content $cacheMetaFile -Raw | ConvertFrom-Json
        $cacheAge = (Get-Date) - [datetime]$cacheMeta.Timestamp
        
        if ($cacheAge.TotalMinutes -lt $CacheMinutes) {
            Write-Info "Using cached response (age: $([math]::Round($cacheAge.TotalMinutes, 1))m)"
            return Get-Content $cacheFile -Raw | ConvertFrom-Json
        }
    }
    
    # Fetch fresh content
    try {
        $response = Invoke-RestMethod -Uri $Url -UseBasicParsing -TimeoutSec 30
        
        # Cache the response
        $response | ConvertTo-Json -Depth 10 | Set-Content $cacheFile -Encoding UTF8
        @{ Timestamp = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content $cacheMetaFile -Encoding UTF8
        
        return $response
    } catch {
        # Try to use stale cache if network fails
        if (Test-Path $cacheFile) {
            Write-Warn "Network request failed, using stale cache"
            return Get-Content $cacheFile -Raw | ConvertFrom-Json
        }
        throw
    }
}

function Refresh-EnvironmentPath {
    <#
    .SYNOPSIS
    Reloads PATH from registry without restarting shell
    #>
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machinePath;$userPath"
}

function Find-ExecutableInPath {
    <#
    .SYNOPSIS
    Finds an executable after refreshing PATH
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        
        [string[]]$FallbackPaths = @()
    )
    
    Refresh-EnvironmentPath
    
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd }
    
    # Check fallback paths
    foreach ($path in $FallbackPaths) {
        if (Test-Path $path) {
            return Get-Command $path
        }
    }
    
    return $null
}

# ══════════════════════════════════════════════════════════════════════════════
# Main Installation Functions
# ══════════════════════════════════════════════════════════════════════════════

function Ensure-PowerShell7 {
    <#
    .SYNOPSIS
    Ensures PowerShell 7+ is installed and optionally relaunches bootstrap
    #>
    param([switch]$RelaunchIfNeeded)
    
    $currentVersion = $PSVersionTable.PSVersion
    
    if ($currentVersion -ge $Config.MinPowerShellVer) {
        Write-Ok "Running PowerShell $currentVersion"
        return $true
    }
    
    Write-Info "Current PowerShell version: $currentVersion"
    
    # Check if PowerShell 7 is installed
    $pwsh = Find-ExecutableInPath -Name 'pwsh' -FallbackPaths @(
        "$env:ProgramFiles\PowerShell\7\pwsh.exe",
        "${env:ProgramFiles(x86)}\PowerShell\7\pwsh.exe",
        "$env:LocalAppData\Microsoft\PowerShell\7\pwsh.exe"
    )
    
    if (-not $pwsh) {
        Write-Info "PowerShell 7 not found. Installing latest version..."
        
        try {
            # Get latest release info (with caching)
            $release = Get-CachedWebContent -Url 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest'
            
            $asset = $release.assets | Where-Object { 
                $_.name -like '*win-x64.msi' 
            } | Select-Object -First 1
            
            if (-not $asset) {
                throw "No suitable PowerShell 7 MSI found in latest release"
            }
            
            $msiPath = Join-Path $env:TEMP "pwsh7-$($release.tag_name).msi"
            
            # Download if not already cached
            if (-not (Test-Path $msiPath)) {
                Write-Info "Downloading PowerShell $($release.tag_name)..."
                Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $msiPath -UseBasicParsing
            }
            
            Write-Info "Installing PowerShell 7 (this may take a minute)..."
            $msiArgs = @(
                '/i', "`"$msiPath`"",
                '/qn',
                'ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1',
                'ENABLE_PSREMOTING=1',
                'REGISTER_MANIFEST=1'
            )
            
            $process = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
            
            if ($process.ExitCode -eq 0) {
                Write-Ok "PowerShell 7 installed successfully"
                
                # Find the newly installed pwsh
                $pwsh = Find-ExecutableInPath -Name 'pwsh' -FallbackPaths @(
                    "$env:ProgramFiles\PowerShell\7\pwsh.exe"
                )
            } else {
                throw "Installation failed with exit code $($process.ExitCode)"
            }
        } catch {
            Write-Err "Failed to install PowerShell 7: $_"
            return $false
        }
    } else {
        Write-Ok "PowerShell 7 is installed at: $($pwsh.Source)"
    }
    
    # Relaunch if needed
    if ($RelaunchIfNeeded -and $currentVersion -lt $Config.MinPowerShellVer) {
        Write-Info "Relaunching bootstrap under PowerShell 7..."
        
        if ($pwsh) {
            try {
                $pwshArgs = @(
                    '-NoLogo',
                    '-NoProfile',
                    '-ExecutionPolicy', 'Bypass',
                    '-Command', "iwr '$($Config.BootstrapUrl)' -UseBasicParsing | iex"
                )
                
                & $pwsh.Source @pwshArgs
                exit 0
            } catch {
                Write-Err "Failed to relaunch: $_"
            }
        } else {
            Write-Err "PowerShell 7 installed but not found in PATH. Please restart your terminal."
        }
        
        exit 1
    }
    
    return $true
}

function Ensure-Git {
    <#
    .SYNOPSIS
    Ensures Git for Windows is installed
    #>
    
    # Check if git is available
    $git = Find-ExecutableInPath -Name 'git' -FallbackPaths @(
        "$env:ProgramFiles\Git\cmd\git.exe",
        "${env:ProgramFiles(x86)}\Git\cmd\git.exe",
        "$env:LocalAppData\Programs\Git\cmd\git.exe"
    )
    
    if ($git) {
        $version = & $git.Source --version 2>$null
        Write-Ok "Git installed: $version"
        return $true
    }
    
    Write-Info "Git not found. Installing Git for Windows..."
    
    try {
        # Get latest release (with caching)
        $release = Get-CachedWebContent -Url 'https://api.github.com/repos/git-for-windows/git/releases/latest'
        
        $asset = $release.assets | Where-Object {
            $_.name -like '*64-bit.exe' -and $_.name -notlike '*stub*'
        } | Select-Object -First 1
        
        if (-not $asset) {
            throw "No suitable Git installer found in latest release"
        }
        
        $installerPath = Join-Path $env:TEMP "git-$($release.tag_name)-64bit.exe"
        
        # Download if not cached
        if (-not (Test-Path $installerPath)) {
            Write-Info "Downloading Git $($release.tag_name)..."
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $installerPath -UseBasicParsing
        }
        
        Write-Info "Installing Git (this may take a minute)..."
        $process = Start-Process $installerPath -ArgumentList '/VERYSILENT', '/NORESTART' -Wait -PassThru
        
        if ($process.ExitCode -eq 0) {
            Write-Ok "Git installed successfully"
            
            # Verify installation
            $git = Find-ExecutableInPath -Name 'git'
            if (-not $git) {
                Write-Warn "Git installed but not found in PATH. You may need to restart your terminal."
            }
            
            return $true
        } else {
            throw "Installation failed with exit code $($process.ExitCode)"
        }
    } catch {
        Write-Err "Failed to install Git: $_"
        return $false
    }
}

function Ensure-ProfileRepository {
    <#
    .SYNOPSIS
    Clones or updates the profile repository
    #>
    
    $repoPath = $Config.ProfileRepoPath
    $repoUrl = $Config.ProfileRepoUrl
    $repoRoot = Split-Path $repoPath -Parent
    
    # Create root directory
    if (-not (Test-Path $repoRoot)) {
        Write-Info "Creating $repoRoot"
        New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
    }
    
    # Check if repository exists
    if (-not (Test-Path $repoPath)) {
        Write-Info "Cloning profile repository..."
        
        try {
            git clone $repoUrl $repoPath 2>&1 | Out-Null
            Write-Ok "Repository cloned to $repoPath"
            return $true
        } catch {
            Write-Err "Failed to clone repository: $_"
            return $false
        }
    }
    
    # Verify it's a valid git repository
    $gitDir = Join-Path $repoPath '.git'
    if (-not (Test-Path $gitDir)) {
        $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
        $backupPath = "$repoPath.broken.$timestamp"
        
        Write-Warn "Invalid repository at $repoPath"
        Write-Info "Moving to $backupPath"
        
        Rename-Item -Path $repoPath -NewName (Split-Path $backupPath -Leaf)
        
        Write-Info "Cloning fresh repository..."
        git clone $repoUrl $repoPath 2>&1 | Out-Null
        Write-Ok "Repository re-cloned"
        
        return $true
    }
    
    # Update existing repository
    Write-Info "Checking for profile updates..."
    
    try {
        Push-Location $repoPath
        
        # Check for uncommitted changes
        $status = git status --porcelain 2>$null
        if ($status) {
            Write-Warn "Repository has local changes. Skipping update."
            Write-Warn "Run 'git status' in $repoPath to review changes."
            return $true
        }
        
        # Fetch and pull
        git fetch --all --quiet 2>$null
        $localCommit = git rev-parse HEAD 2>$null
        $remoteCommit = git rev-parse '@{u}' 2>$null
        
        if ($localCommit -ne $remoteCommit) {
            Write-Info "Updating repository..."
            git pull --ff-only --quiet 2>$null
            
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "Repository updated successfully"
            } else {
                Write-Warn "Update failed. You may need to resolve conflicts manually."
            }
        } else {
            Write-Ok "Repository is up to date"
        }
        
        return $true
    } catch {
        Write-Warn "Could not update repository: $_"
        return $true  # Not a fatal error
    } finally {
        Pop-Location
    }
}

function Install-ProfileLoader {
    <#
    .SYNOPSIS
    Creates loader profile that sources the git-managed profile
    #>
    
    $loaderPath = $PROFILE.CurrentUserCurrentHost
    $loaderDir = Split-Path $loaderPath -Parent
    $gitProfilePath = Join-Path $Config.ProfileRepoPath 'Profile.ps1'
    
    # Create profile directory
    if (-not (Test-Path $loaderDir)) {
        Write-Info "Creating profile directory: $loaderDir"
        New-Item -ItemType Directory -Path $loaderDir -Force | Out-Null
    }
    
    # Generate loader content
    $loaderContent = @"
# ══════════════════════════════════════════════════════════════════════════════
# Synced PowerShell Profile Loader
# ══════════════════════════════════════════════════════════════════════════════
# This file is auto-generated by bootstrap.ps1
# Do not edit this file directly - edit Profile.ps1 in the Git repository
# Repository: $($Config.ProfileRepoUrl)
# ══════════════════════════════════════════════════════════════════════════════

`$ErrorActionPreference = 'SilentlyContinue'

`$gitProfile = '$($gitProfilePath -replace "'", "''")'

if (-not (Test-Path `$gitProfile)) {
    Write-Warning "Git-based profile not found at: `$gitProfile"
    Write-Warning "Run this command to repair your profile setup:"
    Write-Warning "  iwr '$($Config.BootstrapUrl)' -UseBasicParsing | iex"
} else {
    try {
        . `$gitProfile
    } catch {
        Write-Warning "Failed to load Git-based profile: `$_"
        Write-Warning "Check `$gitProfile for syntax errors."
    }
}

`$ErrorActionPreference = 'Continue'
"@
    
    Write-Info "Writing loader profile to $loaderPath"
    $loaderContent | Set-Content -Path $loaderPath -Encoding UTF8 -Force
    
    # Clean up legacy profiles
    $legacyPath = Join-Path $loaderDir 'profile.ps1'
    if ((Test-Path $legacyPath) -and $legacyPath -ne $loaderPath) {
        $firstLine = Get-Content $legacyPath -TotalCount 1 -ErrorAction SilentlyContinue
        if ($firstLine -like '*Synced PowerShell profile loader*') {
            Write-Info "Removing legacy loader at $legacyPath"
            Remove-Item $legacyPath -Force -ErrorAction SilentlyContinue
        }
    }
    
    Write-Ok "Profile loader installed"
    return $true
}

# ══════════════════════════════════════════════════════════════════════════════
# Main Execution
# ══════════════════════════════════════════════════════════════════════════════

try {
    Write-Host ""
    Write-Host "══════════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  PowerShell Profile Bootstrap (Optimized)" -ForegroundColor Cyan
    Write-Host "══════════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    
    # Check admin status
    if (-not (Test-IsAdmin)) {
        Write-Warn "Not running as administrator"
        Write-Warn "System-wide installations may fail. Run elevated if you encounter errors."
        Write-Host ""
    }
    
    # Initialize TLS
    Initialize-TLS
    
    # Install PowerShell 7 (and relaunch if needed)
    if (-not (Ensure-PowerShell7 -RelaunchIfNeeded)) {
        throw "PowerShell 7 installation failed"
    }
    
    # Install Git
    if (-not (Ensure-Git)) {
        throw "Git installation failed"
    }
    
    # Setup profile repository
    if (-not (Ensure-ProfileRepository)) {
        throw "Profile repository setup failed"
    }
    
    # Install loader profile
    if (-not (Install-ProfileLoader)) {
        throw "Profile loader installation failed"
    }
    
    # Success summary
    Write-Host ""
    Write-Host "══════════════════════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Ok "Bootstrap completed successfully!"
    Write-Host "══════════════════════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host ""
    Write-Info "Profile repository: $($Config.ProfileRepoPath)"
    Write-Info "Loader profile:     $($PROFILE.CurrentUserCurrentHost)"
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host "  1. Close this window" -ForegroundColor White
    Write-Host "  2. Open a new PowerShell 7 window (run 'pwsh')" -ForegroundColor White
    Write-Host "  3. Your synced profile will load automatically" -ForegroundColor White
    Write-Host ""
    
} catch {
    Write-Host ""
    Write-Err "Bootstrap failed: $_"
    Write-Host ""
    Write-Info "Troubleshooting:"
    Write-Info "  - Run this script as administrator"
    Write-Info "  - Check your internet connection"
    Write-Info "  - Verify GitHub is accessible"
    Write-Host ""
    exit 1
}