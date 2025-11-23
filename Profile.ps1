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
        }
        catch { }

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

        elseif ($hasLocalChanges) {
            Write-Host "⚠ Local changes detected — skipping auto-update to prevent overwrite" -ForegroundColor Yellow
        }
        else {
            Write-Host "ℹ GitHub not reachable — skipping update" -ForegroundColor DarkGray
        }
    }
    catch {
        Write-Host "ℹ Auto-update skipped due to git error" -ForegroundColor DarkGray
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

# --- Safe automatic module install and load (local use only) ---
$modulesToEnsure = @(
    'PSReadLine',
    'Microsoft.PowerShell.SecretManagement',
    'Microsoft.PowerShell.SecretStore',
    'Terminal-Icons'
)

foreach ($module in $modulesToEnsure) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        try {
            Write-Host "⬇ Installing missing module: $module" -ForegroundColor DarkYellow
            Install-Module $module -Scope CurrentUser -Force -ErrorAction Stop
        }
        catch {
            Write-Host "⚠ Failed to install module: $module (offline or repository unavailable)" -ForegroundColor Yellow
            continue
        }
    }

    try {
        Import-Module $module -ErrorAction Stop
        Write-Host "✅ Loaded module: $module" -ForegroundColor Green
    }
    catch {
        Write-Host "⚠ Failed to import module: $module" -ForegroundColor Yellow
    }
}


# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
Write-Host "✅ Roaming PowerShell profile loaded from Git" -ForegroundColor Green
