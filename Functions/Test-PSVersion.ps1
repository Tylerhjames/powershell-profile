function Test-PSVersion {
    <#
    .SYNOPSIS
    Checks if a newer stable PowerShell version is available via winget.
    .DESCRIPTION
    Compares $PSVersionTable.PSVersion against the latest stable version
    reported by winget. Displays a one-line notification if an update is
    available, otherwise stays silent. Uses a daily flag file to avoid
    repeated checks within the same day.
    .PARAMETER Force
    Bypass the daily check throttle and query winget regardless.
    .EXAMPLE
    Test-PSVersion
    .EXAMPLE
    Test-PSVersion -Force
    #>
    [CmdletBinding()]
    param(
        [switch]$Force
    )

    $flagFile = Join-Path $env:TEMP 'ps-version-check.txt'
    $today = (Get-Date).ToString('yyyy-MM-dd')

    # ── Daily throttle: skip if already checked today ──
    if (-not $Force -and (Test-Path $flagFile)) {
        $lastCheck = (Get-Content $flagFile -Raw -ErrorAction SilentlyContinue).Trim()
        if ($lastCheck -eq $today) { return }
    }

    # ── Stamp the flag file immediately to prevent repeat checks ──
    $today | Set-Content $flagFile -Force -ErrorAction SilentlyContinue

    # ── Query winget for latest available version ──
    try {
        $wingetOutput = & winget show Microsoft.PowerShell --accept-source-agreements 2>$null
        if (-not $wingetOutput) { return }

        # Parse the "Version:" line from winget output
        $versionLine = $wingetOutput | Where-Object { $_ -match '^\s*Version:\s+(.+)' }
        if (-not $versionLine) { return }

        $null = $versionLine -match '^\s*Version:\s+(.+)'
        $latestStr = $Matches[1].Trim()

        # Parse into System.Version for reliable comparison
        $latestVersion  = [version]$latestStr
        $currentVersion = [version]"$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor).$($PSVersionTable.PSVersion.Patch)"

        if ($latestVersion -gt $currentVersion) {
            Write-Host "⬆ PowerShell $latestStr available " -ForegroundColor DarkYellow -NoNewline
            Write-Host "(current: $currentVersion)" -ForegroundColor Gray -NoNewline
            Write-Host " — run: " -ForegroundColor DarkYellow -NoNewline
            Write-Host "winget upgrade Microsoft.PowerShell" -ForegroundColor Cyan
        }
    }
    catch {
        # Silently fail — offline, winget missing, parse error, etc.
    }
}
Set-Alias -Name psver -Value Test-PSVersion -Scope Global
