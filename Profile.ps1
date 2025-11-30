# ══════════════════════════════════════════════════════════════════════════════
# Optimized Roaming PowerShell Profile with Auto-Sync
# ══════════════════════════════════════════════════════════════════════════════

$ErrorActionPreference = 'SilentlyContinue'  # Reduce noise from git operations

# ── Configuration ──
$script:ProfileRepo = "$HOME\Documents\Git\powershell-profile"
$script:RequiredModules = @('Terminal-Icons')  # Only load essentials at startup
$script:LazyModules = @('Pester', 'Microsoft.PowerShell.SecretManagement', 'Microsoft.PowerShell.SecretStore')

# ══════════════════════════════════════════════════════════════════════════════
# Auto-Pull from Git (Silent)
# ══════════════════════════════════════════════════════════════════════════════

$repo = "$HOME\Documents\Git\powershell-profile"
if (Test-Path "$repo\.git") {
    Push-Location $repo
    
    # Set upstream if not configured
    $upstream = git rev-parse --abbrev-ref '@{u}' 2>$null
    if (-not $upstream) {
        git branch --set-upstream-to=origin/main main 2>&1 | Out-Null
    }
    
    # Fetch updates
    git fetch --quiet 2>&1 | Out-Null
    
    # Check for local changes
    $hasChanges = git diff --quiet HEAD 2>$null
    $exitCode = $LASTEXITCODE
    
    if ($exitCode -ne 0) {
        Write-Host "⚠ Local changes detected — skipping auto-update" -ForegroundColor Yellow
    }
    else {
        # Check if behind remote
        $localCommit = git rev-parse HEAD 2>$null
        $remoteCommit = git rev-parse '@{u}' 2>$null
        
        if ($localCommit -ne $remoteCommit) {
            git pull --ff-only --quiet 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "✓ Profile updated from GitHub" -ForegroundColor DarkGreen
            }
        }
    }
    
    Pop-Location
}

# ══════════════════════════════════════════════════════════════════════════════
# Auto-Load Functions
# ══════════════════════════════════════════════════════════════════════════════

$functionsPath = "$ProfileRepo\Functions"
if (Test-Path $functionsPath) {
    Get-ChildItem $functionsPath -Filter *.ps1 -ErrorAction SilentlyContinue | 
        ForEach-Object { . $_.FullName }
}

# ══════════════════════════════════════════════════════════════════════════════
# PSReadLine Configuration (Lazy Load Latest Version)
# ══════════════════════════════════════════════════════════════════════════════

# Import latest PSReadLine if newer version is available
$currentPSRL = Get-Module PSReadLine
$latestPSRL = Get-Module PSReadLine -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1

if ($latestPSRL -and ($currentPSRL.Version -lt $latestPSRL.Version)) {
    Remove-Module PSReadLine -ErrorAction SilentlyContinue
    Import-Module $latestPSRL.Path -Force -ErrorAction SilentlyContinue
}

# ── PSReadLine Settings ──
Set-PSReadLineOption -EditMode Emacs
Set-PSReadLineOption -PredictionSource HistoryAndPlugin
Set-PSReadLineOption -PredictionViewStyle InlineView
Set-PSReadLineOption -BellStyle None  # Disable annoying beeps

# Key bindings
Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
Set-PSReadLineKeyHandler -Chord 'Ctrl+r' -Function ReverseSearchHistory

# ── Matte Pastel Theme ──
Set-PSReadLineOption -Colors @{
    Command          = '#D4B847'
    Parameter        = '#C7A8C7'
    Operator         = '#B0C4DE'
    Variable         = '#98C1D9'
    String           = '#B5EAD7'
    Number           = '#E0BFB8'
    InlinePrediction = '#B9ADA2'
    Selection        = '#5C6B7A'
}

# ── Muted Sage Green Formatting ──
$PSStyle.Formatting.FormatAccent = "`e[38;2;134;166;137m"
$PSStyle.Formatting.TableHeader = "`e[38;2;134;166;137m"

# ══════════════════════════════════════════════════════════════════════════════
# Module Management (Optimized)
# ══════════════════════════════════════════════════════════════════════════════

function Install-ProfileModule {
    param([string]$ModuleName)
    
    if (-not (Get-Module -ListAvailable $ModuleName)) {
        Write-Host "Installing $ModuleName..." -ForegroundColor Cyan
        Install-Module $ModuleName -Scope CurrentUser -Force -AllowClobber *>$null
    }
}

function Import-ProfileModule {
    param([string]$ModuleName, [switch]$Lazy)
    
    if (-not (Get-Module $ModuleName)) {
        if ($Lazy) {
            # Create stub function that loads module on first use
            return
        }
        Import-Module $ModuleName -ErrorAction SilentlyContinue *>$null
    }
}

# Load essential modules immediately
foreach ($module in $RequiredModules) {
    Install-ProfileModule $module
    Import-ProfileModule $module
}

# Lazy-load heavy modules (only when needed)
foreach ($module in $LazyModules) {
    Install-ProfileModule $module
    # Don't import yet - load on demand
}

# ══════════════════════════════════════════════════════════════════════════════
# Profile Management Functions
# ══════════════════════════════════════════════════════════════════════════════

function Reload-Profile {
    <#
    .SYNOPSIS
    Reloads the PowerShell profile
    #>
    . $PROFILE
    Write-Host "✓ Profile reloaded" -ForegroundColor Green
}
Set-Alias rpl Reload-Profile

function Update-Profile {
    <#
    .SYNOPSIS
    Force-pulls latest profile from Git
    #>
    Push-Location $ProfileRepo
    
    $status = git status --porcelain 2>$null
    if ([string]::IsNullOrEmpty($status)) {
        git pull --ff-only --quiet *>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ Profile force-updated" -ForegroundColor DarkGreen
            . $PROFILE
        } else {
            Write-Host "✗ Update failed" -ForegroundColor Red
        }
    } else {
        Write-Host "⚠ Local changes present — commit or stash first" -ForegroundColor Yellow
        git status --short
    }
    
    Pop-Location
}

function Sync-Profile {
    <#
    .SYNOPSIS
    Commits and pushes profile changes to Git
    .PARAMETER Message
    Commit message (defaults to auto-generated message)
    #>
    param(
        [string]$Message = "Auto-sync: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    )
    
    Push-Location $ProfileRepo
    
    try {
        $status = git status --porcelain 2>$null
        
        if ([string]::IsNullOrEmpty($status)) {
            Write-Host "✓ No changes to sync" -ForegroundColor Gray
            return
        }
        
        # Show what's being synced
        Write-Host "Changes to sync:" -ForegroundColor Cyan
        git status --short
        
        # Commit and push
        git add -A
        git commit -m $Message *>$null
        
        if ($LASTEXITCODE -eq 0) {
            git push *>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "✓ Profile synced to GitHub" -ForegroundColor DarkGreen
            } else {
                Write-Host "✗ Push failed - check network connection" -ForegroundColor Red
            }
        } else {
            Write-Host "✗ Commit failed" -ForegroundColor Red
        }
    }
    catch {
        Write-Host "✗ Sync failed: $_" -ForegroundColor Red
    }
    finally {
        Pop-Location
    }
}
Set-Alias sync Sync-Profile

function Save-Profile {
    <#
    .SYNOPSIS
    Quick save with custom commit message
    .PARAMETER Message
    Commit message (prompts if not provided)
    #>
    param([string]$Message)
    
    if (-not $Message) {
        $Message = Read-Host "Commit message"
        if ([string]::IsNullOrWhiteSpace($Message)) {
            $Message = "Profile update: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        }
    }
    
    Sync-Profile -Message $Message
}
Set-Alias sp Save-Profile

function Edit-Profile {
    <#
    .SYNOPSIS
    Opens profile in default editor
    #>
    code "$ProfileRepo\Profile.ps1"
}
Set-Alias ep Edit-Profile

function Show-ProfileStatus {
    <#
    .SYNOPSIS
    Shows Git status of profile repository
    #>
    Push-Location $ProfileRepo
    Write-Host "`nProfile Repository Status:" -ForegroundColor Cyan
    git status
    Pop-Location
}
Set-Alias ps Show-ProfileStatus

# ══════════════════════════════════════════════════════════════════════════════
# Startup Message
# ══════════════════════════════════════════════════════════════════════════════

Write-Host "✓ Roaming PowerShell profile loaded" -ForegroundColor DarkGreen

# Reset error preference
$ErrorActionPreference = 'Continue'