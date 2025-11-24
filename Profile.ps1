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

# --- PSReadLine Experience Customization ---

# Ensure PSReadLine is loaded
Import-Module PSReadLine -ErrorAction SilentlyContinue

$psrl = Get-Module PSReadLine
$version = [version]$psrl.Version

# Set editing mode (always supported)
Set-PSReadLineOption -EditMode Emacs

# Prediction source (supported in all recent versions)
Set-PSReadLineOption -PredictionSource HistoryAndPlugin

# View style selection based on version
if ($version.Major -ge 2 -and $version.Minor -ge 2) {
    Set-PSReadLineOption -PredictionViewStyle ListView
}
else {
    Set-PSReadLineOption -PredictionViewStyle InlineView
}

# Key handlers (only apply if supported)
try { Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete } catch {}
try { Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward } catch {}
try { Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward } catch {}
try { Set-PSReadLineKeyHandler -Chord "Ctrl+R" -Function ReverseSearchHistory } catch {}
try { Set-PSReadLineKeyHandler -Chord "Ctrl+Space" -Function AcceptNextSuggestionWord } catch {}

# Color customization (skip unsupported properties)
$colorOptions = @{}
$colorOptions.Command         = '#00E5FF'
$colorOptions.Parameter       = '#FFCB6B'
$colorOptions.Operator        = '#C792EA'
$colorOptions.Variable        = '#F78C6C'
$colorOptions.String          = '#C3E88D'

try { $colorOptions.CommandPrediction = '#5EF1FF' } catch {}

Set-PSReadLineOption -Colors $colorOptions

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
