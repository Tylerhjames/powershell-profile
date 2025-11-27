# ── Silent, safe auto-pull — works on fresh clones and existing installs ──
$repo = "$HOME\Documents\Git\powershell-profile"

if (Test-Path "$repo\.git") {
    try {
        Push-Location $repo -ErrorAction Stop

        # Ensure upstream tracking exists (harmless if already set)
        git branch --set-upstream-to=origin/main main 2>$null | Out-Null

        # Fast local-vs-remote check (zero traffic when up-to-date)
        $local  = git rev-parse HEAD 2>$null
        $remote = git rev-parse '@{u}' 2>$null

        if ($local -and $remote -and $local -ne $remote) {
            # Only pull when repo is clean
            $dirty = git status --porcelain
            if ([string]::IsNullOrWhiteSpace($dirty)) {
                git pull --ff-only --quiet
                Write-Host "Profile silently updated from GitHub" -ForegroundColor DarkGreen
            }
            else {
                Write-Host "Local changes in profile repo — update skipped" -ForegroundColor Yellow
            }
        }
    }
    catch {
        # Network offline, no upstream, etc. → completely silent
    }
    finally {
        Pop-Location -ErrorAction SilentlyContinue
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
Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
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
$PSStyle.Formatting.FormatAccent = "`e[38;2;134;166;137m"
$PSStyle.Formatting.TableHeader = "`e[38;2;134;166;137m"

# --- Modules ---
$modules = 'PSReadLine','Microsoft.PowerShell.SecretManagement','Microsoft.PowerShell.SecretStore','Terminal-Icons'
foreach ($m in $modules) {
    if (-not (Get-Module -ListAvailable $m)) {
        try { Install-Module $m -Scope CurrentUser -Force -ErrorAction Stop | Out-Null }
        catch { Write-Host "Failed installing $m" -ForegroundColor Yellow }
    }
    try { Import-Module $m -ErrorAction Stop | Out-Null }
    catch { Write-Host "Failed loading $m" -ForegroundColor Yellow }
}

Write-Host "Roaming PowerShell profile loaded from Git" -ForegroundColor DarkGreen

function Reload-Profile {
    . $PROFILE
    Write-Host "Profile reloaded" -ForegroundColor Green
}
Set-Alias rpl Reload-Profile

# ── Manual update command (optional but handy) ──
function Update-Profile {
    Set-Location "$HOME\Documents\Git\powershell-profile"
    if ((git status --porcelain) -eq '') {
        git pull --ff-only --quiet && Write-Host "Profile force-updated" -ForegroundColor DarkGreen
    } else {
        Write-Host "Local changes present — commit or stash first" -ForegroundColor Yellow
    }
    Set-Location $HOME
}