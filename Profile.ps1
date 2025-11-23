# --- Auto-update with backup, conflict prevention, logging, and update indicator ---

$profileRepo   = "$HOME\Documents\Git\powershell-profile"
$profileFile   = Join-Path $profileRepo "Profile.ps1"
$logFile       = Join-Path $profileRepo "update.log"
$dateStamp     = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

# Prevent editing if this is not the repo copy
if ($PROFILE -ne $profileFile) {
    Write-Host "⚠ Profile loader active — edit the Git-based Profile.ps1 instead." -ForegroundColor Yellow
}

# Backup before updating (one backup per day)
$backupFile = "$profileFile.bak.$(Get-Date -Format yyyy-MM-dd)"
if (-not (Test-Path $backupFile)) {
    Copy-Item $profileFile $backupFile -ErrorAction SilentlyContinue
}

# Pull latest updates quietly
$updateResult = git -C $profileRepo pull 2>&1

# Log update activity
"$dateStamp : $updateResult" | Out-File -FilePath $logFile -Append -Encoding utf8

# Subtle update indicator
if ($updateResult -notmatch "Already up to date") {
    Write-Host "🔄 Profile updated from Git" -ForegroundColor Cyan
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
