# --- Safe auto-pull if repo is clean and remote reachable ---
$repoPath = "$HOME\Documents\Git\powershell-profile"

if (Test-Path $repoPath) {
    try {
        Set-Location $repoPath

        # Check for uncommitted changes
        $status = git status --porcelain
        $hasLocalChanges = -not [string]::IsNullOrWhiteSpace($status)

        # Test remote availability (fast & reliable)
        $remoteReachable = $false
        try {
            $result = git ls-remote origin 2>$null
            if ($result) { $remoteReachable = $true }
        } catch {}

        if (-not $hasLocalChanges -and $remoteReachable) {
            git pull --ff-only | Out-Null
            Write-Host "⬇ Profile updated from GitHub" -ForegroundColor DarkCyan
        }
        elseif ($hasLocalChanges) {
            Write-Host "⚠ Local changes detected — skipping auto-update to prevent overwrite" -ForegroundColor Yellow
        }
        else {
            Write-Host "ℹ GitHub not reachable — skipping update" -ForegroundColor DarkGray
        }
    }
    finally {
        Set-Location $HOME
    }
}


# --- Auto-load functions from the Functions folder ---
$functionsPath = "$HOME\Documents\Git\powershell-profile\Functions"
if (Test-Path $functionsPath) {
    Get-ChildItem $functionsPath -Filter *.ps1 | ForEach-Object {
        . $_.FullName
    }
}

# --- Ensure newest PSReadLine loads instead of bundled version ---
$latest = Get-Module PSReadLine -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
if ($latest) {
    Remove-Module PSReadLine -ErrorAction SilentlyContinue
    Import-Module $latest.Path -Force
}


# --- PSReadLine Experience Customization ---
# Set editing style (Emacs = powerful shortcuts, non-modal)
Set-PSReadLineOption -EditMode Emacs

# Enable predictions and list-style suggestions
Set-PSReadLineOption -PredictionSource HistoryAndPlugin
Set-PSReadLineOption -PredictionViewStyle InlineView

# Smarter history filtering (UpArrow only cycles matching entries)
Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward

# TAB cycles completion results (Cisco-style)
Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete

# Ctrl+R fuzzy reverse-search through history
Set-PSReadLineKeyHandler -Chord "Ctrl+r" -Function ReverseSearchHistory

# ── Matte pastel syntax colors – final version ──
Set-PSReadLineOption -Colors @{
    Command           = '#A7C7E7'   # soft sky blue
    Parameter         = '#D8BFD8'   # barely-there lavender
    Operator          = '#B0C4DE'   # light steel blue
    Variable          = '#98C1D9'   # calm aqua-teal
    String            = '#B5EAD7'   # soft mint
    Number            = '#E0BFB8'   # warm sand
    InlinePrediction  = '#B9ADA2'   # your warm beige-gray
    Selection         = '#5C6B7A'   # slate selection highlight
}

# --- Silent module install + load (only warn on failures) ---
$modulesToEnsure = @(
    'PSReadLine',
    'Microsoft.PowerShell.SecretManagement',
    'Microsoft.PowerShell.SecretStore',
    'Terminal-Icons'
)

foreach ($module in $modulesToEnsure) {

    # Install if missing (quiet unless failure)
    if (-not (Get-Module -ListAvailable -Name $module)) {
        try {
            Install-Module $module -Scope CurrentUser -Force -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Host "⚠ Failed to install module: $module" -ForegroundColor Yellow
            continue
        }
    }

    # Load silently unless failure
    try {
        Import-Module $module -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Host "⚠ Failed to load module: $module" -ForegroundColor Yellow
    }
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
Write-Host "✅ Roaming PowerShell profile loaded from Git" -ForegroundColor Green
