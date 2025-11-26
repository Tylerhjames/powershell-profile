# --- Safe auto-pull if repo is clean and remote reachable ---
$repoPath = "$HOME\Documents\Git\powershell-profile"

if (Test-Path $repoPath) {
    try {
        Set-Location $repoPath
        $status = git status --porcelain 2>$null
        $hasLocalChanges = -not [string]::IsNullOrWhiteSpace($status)

        # Silent remote check (no PSJob output)
        $remoteReachable = $false
        try {
            git ls-remote origin 2>&1 | Out-Null
            $remoteReachable = $true
        } catch {}

        if (-not $hasLocalChanges -and $remoteReachable) {
            git pull --ff-only 2>&1 | Out-Null
            Write-Host "⬇ Profile updated from GitHub" -ForegroundColor DarkCyan
        }
        elseif ($hasLocalChanges) {
            Write-Host "⚠ Local changes detected — skipping auto-update" -ForegroundColor Yellow
        }
        else {
            Write-Host "ℹ GitHub not reachable — skipping update" -ForegroundColor DarkGray
        }
    }
    finally {
        Set-Location $HOME
    }
}

# --- Auto-load functions ---
$functionsPath = "$HOME\Documents\Git\powershell-profile\Functions"
if (Test-Path $functionsPath) {
    Get-ChildItem $functionsPath -Filter *.ps1 | ForEach-Object { . $_.FullName }
}

# --- Latest PSReadLine ---
$latest = Get-Module PSReadLine -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
if ($latest) {
    Remove-Module PSReadLine -ErrorAction SilentlyContinue
    Import-Module $latest.Path -Force
}

# --- PSReadLine basics ---
Set-PSReadLineOption -EditMode Emacs
Set-PSReadLineOption -PredictionSource HistoryAndPlugin
Set-PSReadLineOption -PredictionViewStyle InlineView
Set-PSReadLineKeyHandler -Key UpArrow   -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
Set-PSReadLineKeyHandler -Key Tab       -Function MenuComplete
Set-PSReadLineKeyHandler -Chord "Ctrl+r" -Function ReverseSearchHistory

# --- Matte pastel theme ---
Set-PSReadLineOption -Colors @{
    Command           = '#D4B847'
    Parameter         = '#C7A8C7'
    Operator          = '#B0C4DE'
    Variable          = '#98C1D9'
    String            = '#B5EAD7'
    Number            = '#E0BFB8'
    InlinePrediction  = '#B9ADA2'
    Selection         = '#5C6B7A'
}

# --- Muted sage green formatting ---
$PSStyle.Formatting.FormatAccent  = "`e[38;2;134;166;137m"
$PSStyle.Formatting.TableHeader   = "`e[38;2;134;166;137m"

# --- Modules ---
$modules = 'PSReadLine','Microsoft.PowerShell.SecretManagement','Microsoft.PowerShell.SecretStore','Terminal-Icons'
foreach ($m in $modules) {
    if (-not (Get-Module -ListAvailable $m)) {
        try { Install-Module $m -Scope CurrentUser -Force -ErrorAction Stop | Out-Null }
        catch { Write-Host "⚠ Failed installing $m" -ForegroundColor Yellow }
    }
    try { Import-Module $m -ErrorAction Stop | Out-Null }
    catch { Write-Host "⚠ Failed loading $m" -ForegroundColor Yellow }
}

Write-Host "✅ Roaming PowerShell profile loaded from Git" -ForegroundColor DarkGreen

function Reload-Profile {
    Write-Host "🔁 Reloading profile..." -ForegroundColor Yellow
    . $PROFILE
}
Set-Alias rp Reload-Profile
