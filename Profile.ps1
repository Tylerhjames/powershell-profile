# ══════════════════════════════════════════════════════════════════════════════
# Optimized Roaming PowerShell Profile with Auto-Sync
# ══════════════════════════════════════════════════════════════════════════════
# Optimization pass: 2026-04-10
# Target: <300ms to interactive prompt (git sync moved to background runspace)
# ══════════════════════════════════════════════════════════════════════════════

$ErrorActionPreference = 'SilentlyContinue'

# ── Configuration ──
$script:ProfileRepo = "$HOME\Documents\Git\powershell-profile"

# ══════════════════════════════════════════════════════════════════════════════
# Phase 1: Background Git Sync (non-blocking)
# ══════════════════════════════════════════════════════════════════════════════
# Rationale: git fetch was 454ms avg and blocked the prompt. This fires the
# entire fetch/compare/pull sequence in a background runspace. If an update
# is pulled, a flag file is written and the next prompt displays a notice.

$script:GitSyncFlag = Join-Path $env:TEMP 'ps-profile-git-sync-result.txt'

if (Test-Path "$script:ProfileRepo\.git") {
    $syncRunspace = [runspacefactory]::CreateRunspace()
    $syncRunspace.Open()

    $syncPS = [powershell]::Create().AddScript({
        param($RepoPath, $FlagFile)

        try {
            Set-Location $RepoPath

            # Ensure upstream is configured
            $upstream = & git rev-parse --abbrev-ref '@{u}' 2>$null
            if (-not $upstream) {
                & git branch --set-upstream-to=origin/main main 2>&1 | Out-Null
            }

            # Fetch (this is the expensive network call)
            & git fetch --quiet 2>&1 | Out-Null

            # Check for local changes — skip pull if dirty
            & git diff --quiet HEAD 2>$null
            if ($LASTEXITCODE -ne 0) {
                'local-changes' | Set-Content $FlagFile -Force
                return
            }

            # Compare local vs remote
            $local  = & git rev-parse HEAD 2>$null
            $remote = & git rev-parse '@{u}' 2>$null

            if ($local -ne $remote) {
                & git pull --ff-only --quiet 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    'updated' | Set-Content $FlagFile -Force
                } else {
                    'pull-failed' | Set-Content $FlagFile -Force
                }
            } else {
                # Up to date — no flag needed
                if (Test-Path $FlagFile) { Remove-Item $FlagFile -Force }
            }
        }
        catch {
            # Swallow — offline/timeout is not an error worth surfacing
            if (Test-Path $FlagFile) { Remove-Item $FlagFile -Force }
        }
    }).AddArgument($script:ProfileRepo).AddArgument($script:GitSyncFlag)

    $syncPS.Runspace = $syncRunspace
    $global:_bgSyncHandle = $syncPS.BeginInvoke()

    # Store references for OnIdle cleanup (global because event actions
    # run in their own session state and cannot see $script: vars)
    $global:_bgSyncPS = $syncPS
    $global:_bgSyncRS = $syncRunspace
}

# ── Next-prompt notification via PSReadLine AddToHistoryHandler ──
# Checks the flag file each time a command completes. Lightweight: just a
# Test-Path + one-line read, no git calls on the hot path.

$script:_gitSyncNotified = $false

# ══════════════════════════════════════════════════════════════════════════════
# Auto-Load Functions (eager + lazy)
# ══════════════════════════════════════════════════════════════════════════════
# Small utilities are dot-sourced immediately. Large functions (~3,800 lines
# total) use lightweight stubs that dot-source on first invocation, avoiding
# the parse cost on every shell open.

$functionsPath = "$script:ProfileRepo\Functions"
if (Test-Path $functionsPath) {
    # ── Eager: small utilities needed immediately (<40 lines each) ──
    foreach ($f in @(
        'Get-ClipLength.ps1', 'npp.ps1',
        'renew-safe.ps1', 'test-site.ps1',
        'Repair-Winget.ps1'
    )) {
        $fp = Join-Path $functionsPath $f
        if (Test-Path $fp) { . $fp }
    }

    # ── Lazy: heavy functions loaded on first call ──
    foreach ($def in @(
        @{ Name = 'Get-BitLockerInformation'; File = 'Get-BitLockerInformation.ps1' }
        @{ Name = 'Get-SystemDetails';        File = 'Get-SystemDetails.ps1';        Aliases = 'sysinfo','sys' }
        @{ Name = 'Invoke-InternetSpeedTest'; File = 'Invoke-InternetSpeedTest.ps1'; Aliases = 'speedtest' }
        @{ Name = 'Invoke-ServerInventory';   File = 'Invoke-ServerInventory.ps1';   Aliases = 'inventory','serverinv' }
        @{ Name = 'Scan-Network';             File = 'Scan-Network.ps1' }
        @{ Name = 'Show-TechMenu';            File = 'Show-TechMenu.ps1';           Aliases = 'tech','techmenu' }
        @{ Name = 'Start-Pulse';              File = 'Start-Pulse.ps1';             Aliases = 'pulse' }
        @{ Name = 'Test-EmailAuthentication'; File = 'Test-EmailAuthentication.ps1'; Aliases = 'Test-EmailDNS','Check-EmailDNS','Test-DMARC' }
        @{ Name = 'Test-Internet';            File = 'Test-Internet.ps1' }
        @{ Name = 'Test-Network';             File = 'Test-Network.ps1';            Aliases = 'net-test','Invoke-NetTest' }
    )) {
        $filePath = Join-Path $functionsPath $def.File
        $funcName = $def.Name
        Set-Item "Function:\global:$funcName" -Value ([scriptblock]::Create(@"
            Remove-Item Function:\$funcName -Force
            . '$filePath'
            `$_fn = Get-Item Function:\$funcName -ErrorAction SilentlyContinue
            if (`$_fn) { Set-Item Function:\global:$funcName -Value `$_fn.ScriptBlock }
            & $funcName @args
"@))
        if ($def.Aliases) {
            foreach ($a in $def.Aliases) {
                Set-Alias -Name $a -Value $funcName -Scope Global
            }
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# Lazy winget self-heal shim
# ══════════════════════════════════════════════════════════════════════════════
# Why: roaming between machines, winget intermittently disappears (PATH loss or
# per-user package deregistration). Rather than paying a repair cost at every
# startup, this defines a 'winget' function ONLY when winget.exe doesn't
# resolve. First winget invocation triggers Repair-Winget (PATH fix →
# re-register → Repair-WinGetPackageManager), then replays the original
# command. Startup cost when winget is healthy: one Get-Command (~1ms).
# Repair-Winget itself lives in Functions\Repair-Winget.ps1.

if (-not (Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue)) {
    function global:winget {
        Write-Host 'winget not found — attempting self-repair...' -ForegroundColor Yellow
        if (Repair-Winget) {
            # Remove the shim so winget.exe resolves normally from here on
            Remove-Item Function:\global:winget -Force -ErrorAction SilentlyContinue
            if ($args.Count -gt 0) { & winget.exe @args }
        } else {
            Write-Host 'Self-repair failed. Run ' -ForegroundColor Red -NoNewline
            Write-Host 'Repair-Winget -Verbose' -ForegroundColor Cyan -NoNewline
            Write-Host ' for details.' -ForegroundColor Red
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# PSReadLine Configuration
# ══════════════════════════════════════════════════════════════════════════════
# Phase 3: Removed the Get-Module -ListAvailable scan (~16ms). On PS 7.4+
# the bundled PSReadLine is current. If you install a newer version manually,
# PS loads it automatically from the module path.

Set-PSReadLineOption -EditMode Emacs -BellStyle None -Colors @{
    Command          = '#D4B847'
    Parameter        = '#C7A8C7'
    Operator         = '#B0C4DE'
    Variable         = '#98C1D9'
    String           = '#B5EAD7'
    Number           = '#E0BFB8'
    InlinePrediction = '#B9ADA2'
    Selection        = '#5C6B7A'
}

# Prediction throws a terminating error on non-VT hosts (legacy conhost,
# piped output). Isolate so those hosts run without inline prediction.
try {
    Set-PSReadLineOption -PredictionSource HistoryAndPlugin -PredictionViewStyle InlineView
}
catch {}

Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
Set-PSReadLineKeyHandler -Chord 'Ctrl+r' -Function ReverseSearchHistory

# ── Muted Sage Green Formatting ──
$PSStyle.Formatting.FormatAccent = "`e[38;2;134;166;137m"
$PSStyle.Formatting.TableHeader = "`e[38;2;134;166;137m"

# ══════════════════════════════════════════════════════════════════════════════
# Module Management
# ══════════════════════════════════════════════════════════════════════════════
# Terminal-Icons import is deferred to the OnIdle handler (~30-50ms saved).
# OnIdle fires before the user's first keystroke, so icons are available for
# the first 'ls'. Lazy modules (Pester, SecretManagement, SecretStore) are
# installed once via bootstrap — no need to verify every shell open.

# ── Install-ProfileModule: kept for manual use, not called at startup ──
function Install-ProfileModule {
    param([string]$ModuleName)
    if (-not (Get-Module -ListAvailable $ModuleName)) {
        Write-Host "Installing $ModuleName..." -ForegroundColor Cyan
        Install-Module $ModuleName -Scope CurrentUser -Force -AllowClobber *>$null
    }
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
Set-Alias -Name rpl -Value Reload-Profile -Scope Global

function Update-Profile {
    <#
    .SYNOPSIS
    Force-pulls latest profile from Git
    #>
    Push-Location $script:ProfileRepo

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

    Push-Location $script:ProfileRepo

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
Set-Alias -Name sync -Value Sync-Profile -Scope Global

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
# 'sp' is a built-in alias for Set-ItemProperty — use 'save' instead
Set-Alias -Name save -Value Save-Profile -Scope Global

function Edit-Profile {
    <#
    .SYNOPSIS
    Opens profile in default editor (VS Code → Notepad++ → notepad)
    #>
    $target = "$script:ProfileRepo\Profile.ps1"

    if (Get-Command code -ErrorAction SilentlyContinue) {
        code $target
    } elseif (Get-Command npp -ErrorAction SilentlyContinue) {
        npp $target
    } else {
        notepad $target
    }
}
Set-Alias -Name ep -Value Edit-Profile -Scope Global

function Show-ProfileStatus {
    <#
    .SYNOPSIS
    Shows Git status of profile repository
    #>
    Push-Location $script:ProfileRepo
    Write-Host "`nProfile Repository Status:" -ForegroundColor Cyan
    git status
    Pop-Location
}
# Phase 4: Renamed from 'ps' which shadows the built-in Get-Process alias
Set-Alias -Name pstat -Value Show-ProfileStatus -Scope Global

# ══════════════════════════════════════════════════════════════════════════════
# Phase 5: Background PS Version Check (daily, non-blocking)
# ══════════════════════════════════════════════════════════════════════════════
# Rationale: winget show can take 1-2s. Same pattern as git sync — fire in a
# background runspace, write result to a flag file, notify via OnIdle event.
# The daily throttle is in the flag file itself (date stamp), so the runspace
# only launches once per day.

$script:PSVersionFlag = Join-Path $env:TEMP 'ps-version-update-available.txt'
$today = (Get-Date).ToString('yyyy-MM-dd')
$script:_psVersionCheckDone = $false

# Only launch the runspace if we haven't checked today
$psVerThrottle = Join-Path $env:TEMP 'ps-version-check.txt'
$shouldCheck = $true
if (Test-Path $psVerThrottle) {
    $lastCheck = (Get-Content $psVerThrottle -Raw -ErrorAction SilentlyContinue).Trim()
    if ($lastCheck -eq $today) { $shouldCheck = $false }
}

if ($shouldCheck) {
    $today | Set-Content $psVerThrottle -Force -ErrorAction SilentlyContinue

    $verRunspace = [runspacefactory]::CreateRunspace()
    $verRunspace.Open()

    $verPS = [powershell]::Create().AddScript({
        param($CurrentMajor, $CurrentMinor, $CurrentPatch, $FlagFile)

        try {
            $output = & winget show Microsoft.PowerShell --accept-source-agreements 2>$null
            if (-not $output) { return }

            $vLine = $output | Where-Object { $_ -match '^\s*Version:\s+(.+)' }
            if (-not $vLine) { return }

            $null = $vLine -match '^\s*Version:\s+(.+)'
            $rawVer = [version]($Matches[1].Trim())
            # Normalize both to 3-part (Major.Minor.Build) to avoid
            # .NET Revision=-1 vs 0 false positive (7.6.0 vs 7.6.0.0)
            $latest  = [version]"$($rawVer.Major).$($rawVer.Minor).$($rawVer.Build)"
            $current = [version]"$CurrentMajor.$CurrentMinor.$CurrentPatch"

            if ($latest -gt $current) {
                "$latest|$current" | Set-Content $FlagFile -Force
            } else {
                if (Test-Path $FlagFile) { Remove-Item $FlagFile -Force }
            }
        }
        catch {
            if (Test-Path $FlagFile) { Remove-Item $FlagFile -Force }
        }
    }).AddArgument($PSVersionTable.PSVersion.Major).AddArgument($PSVersionTable.PSVersion.Minor).AddArgument($PSVersionTable.PSVersion.Patch).AddArgument($script:PSVersionFlag)

    $verPS.Runspace = $verRunspace
    $global:_bgVerHandle = $verPS.BeginInvoke()

    $global:_bgVerPS = $verPS
    $global:_bgVerRS = $verRunspace
}

# ══════════════════════════════════════════════════════════════════════════════
# Consolidated OnIdle Notification (git sync + version check)
# ══════════════════════════════════════════════════════════════════════════════
# Single handler for all background task results. Fires once after the first
# idle tick, checks both flag files, and displays any relevant notifications.

if (Get-Module PSReadLine) {
    $null = Register-EngineEvent -SourceIdentifier PowerShell.OnIdle -MaxTriggerCount 1 -Action {
        # ── Deferred Terminal-Icons import (saves ~30-50ms at startup) ──
        if (-not (Get-Module Terminal-Icons)) {
            Import-Module Terminal-Icons -Global -ErrorAction SilentlyContinue *>$null
        }

        # ── Git sync result ──
        $gitFlag = Join-Path $env:TEMP 'ps-profile-git-sync-result.txt'
        if (Test-Path $gitFlag) {
            $result = (Get-Content $gitFlag -Raw).Trim()
            Remove-Item $gitFlag -Force -ErrorAction SilentlyContinue

            switch ($result) {
                'updated'       { Write-Host "`n✓ Profile updated from GitHub — run " -ForegroundColor DarkGreen -NoNewline
                                  Write-Host "Reload-Profile" -ForegroundColor Cyan -NoNewline
                                  Write-Host " to apply" -ForegroundColor DarkGreen }
                'local-changes' { Write-Host "`n⚠ Profile sync skipped — local changes detected" -ForegroundColor Yellow }
                'pull-failed'   { Write-Host "`n✗ Profile auto-pull failed — check manually" -ForegroundColor Red }
            }
        }

        # ── PS version check result ──
        $verFlag = Join-Path $env:TEMP 'ps-version-update-available.txt'
        if (Test-Path $verFlag) {
            $parts = ((Get-Content $verFlag -Raw).Trim()) -split '\|'
            if ($parts.Count -eq 2) {
                Write-Host "⬆ PowerShell $($parts[0]) available " -ForegroundColor DarkYellow -NoNewline
                Write-Host "(current: $($parts[1]))" -ForegroundColor Gray -NoNewline
                Write-Host " — run: " -ForegroundColor DarkYellow -NoNewline
                Write-Host "winget upgrade Microsoft.PowerShell" -ForegroundColor Cyan
            }
            Remove-Item $verFlag -Force -ErrorAction SilentlyContinue
        }

        # ── Dispose background runspaces to prevent memory leaks ──
        foreach ($prefix in @('_bgSync', '_bgVer')) {
            $ps     = (Get-Variable "${prefix}PS"     -Scope Global -ErrorAction SilentlyContinue).Value
            $handle = (Get-Variable "${prefix}Handle" -Scope Global -ErrorAction SilentlyContinue).Value
            $rs     = (Get-Variable "${prefix}RS"     -Scope Global -ErrorAction SilentlyContinue).Value
            if ($ps -and (-not $handle -or $handle.IsCompleted)) {
                try { if ($handle) { $ps.EndInvoke($handle) } } catch {}
                try { $ps.Dispose() } catch {}
                if ($rs) { try { $rs.Dispose() } catch {} }
            }
            # Clear global refs regardless — this is the only OnIdle tick
            # (MaxTriggerCount 1). Any still-running tasks become eligible
            # for GC finalizer cleanup, same as prior behavior.
            Remove-Variable "${prefix}PS","${prefix}Handle","${prefix}RS" -Scope Global -ErrorAction SilentlyContinue
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# Startup Message
# ══════════════════════════════════════════════════════════════════════════════

Write-Host "✓ Roaming PowerShell profile loaded" -ForegroundColor DarkGreen

# Reset error preference
$ErrorActionPreference = 'Continue'
