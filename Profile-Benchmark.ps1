<#
    Profile Startup Benchmark
    -------------------------
    Run this from a FRESH PowerShell 7 window (not one that already loaded your profile):

        pwsh -NoProfile -NoLogo -File "C:\Git\powershell-profile\Profile-Benchmark.ps1"

    It measures each section of your Profile.ps1 independently so we can see
    exactly where the time goes. Results are saved to Profile-Benchmark-Results.txt
    in the same folder.
#>

$ErrorActionPreference = 'SilentlyContinue'
# Self-locating: the repo is wherever this script lives
$repo = $PSScriptRoot
$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Measure-Section {
    param(
        [string]$Name,
        [scriptblock]$Code,
        [int]$Iterations = 3
    )

    $timings = @()
    for ($i = 0; $i -lt $Iterations; $i++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try { & $Code } catch { }
        $sw.Stop()
        $timings += $sw.ElapsedMilliseconds
    }

    $avg = ($timings | Measure-Object -Average).Average
    $min = ($timings | Measure-Object -Minimum).Minimum
    $max = ($timings | Measure-Object -Maximum).Maximum

    $results.Add([PSCustomObject]@{
        Section    = $Name
        AvgMs      = [math]::Round($avg, 1)
        MinMs      = $min
        MaxMs      = $max
        Iterations = $Iterations
    })

    Write-Host ("{0,-45} {1,8:N1} ms  (min: {2}, max: {3})" -f $Name, $avg, $min, $max)
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  PowerShell Profile Startup Benchmark" -ForegroundColor Cyan
Write-Host "  PowerShell Version: $($PSVersionTable.PSVersion)" -ForegroundColor Cyan
Write-Host "  Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "  Host: $($env:COMPUTERNAME)" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host ("{0,-45} {1,8}     {2}" -f "SECTION", "AVG", "(min / max)")
Write-Host ("{0,-45} {1,8}     {2}" -f "-------", "---", "-----------")

# ── 1. Full profile load (the number we want to shrink) ──
Measure-Section "TOTAL: Full Profile.ps1 load" {
    . "$repo\Profile.ps1"
} -Iterations 3

Write-Host ""
Write-Host "--- Individual Section Breakdown ---" -ForegroundColor Yellow
Write-Host ""

# ── 2. Git operations (fetch + compare + pull) ──
Measure-Section "Git: upstream check" {
    Push-Location $repo
    $upstream = git rev-parse --abbrev-ref '@{u}' 2>$null
    Pop-Location
}

Measure-Section "Git: fetch --quiet" {
    Push-Location $repo
    git fetch --quiet 2>&1 | Out-Null
    Pop-Location
}

Measure-Section "Git: rev-parse HEAD vs @{u}" {
    Push-Location $repo
    $localCommit = git rev-parse HEAD 2>$null
    $remoteCommit = git rev-parse '@{u}' 2>$null
    Pop-Location
}

Measure-Section "Git: diff --quiet HEAD" {
    Push-Location $repo
    git diff --quiet HEAD 2>$null
    Pop-Location
}

# ── 3. Dot-sourcing function files ──
$funcPath = "$repo\Functions"
$funcFiles = Get-ChildItem $funcPath -Filter *.ps1 -ErrorAction SilentlyContinue

Measure-Section "Functions: ALL files dot-sourced" {
    foreach ($f in $funcFiles) { . $f.FullName }
}

# Measure each function file individually
foreach ($f in ($funcFiles | Sort-Object Length -Descending)) {
    Measure-Section "  Function: $($f.Name)" {
        . $f.FullName
    } -Iterations 2
}

# ── 4. PSReadLine version check ──
Measure-Section "PSReadLine: Get-Module -ListAvailable" {
    $latestPSRL = Get-Module PSReadLine -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
}

Measure-Section "PSReadLine: configuration (Set-PSReadLineOption)" {
    Set-PSReadLineOption -EditMode Emacs
    Set-PSReadLineOption -PredictionSource HistoryAndPlugin
    Set-PSReadLineOption -PredictionViewStyle InlineView
    Set-PSReadLineOption -BellStyle None
}

# ── 5. Module management ──
Measure-Section "Module: Get-Module -ListAvailable 'Terminal-Icons'" {
    Get-Module -ListAvailable 'Terminal-Icons' | Out-Null
}

Measure-Section "Module: Import-Module Terminal-Icons" {
    Import-Module Terminal-Icons -ErrorAction SilentlyContinue *>$null
}

Measure-Section "Module: Get-Module -ListAvailable 'Pester'" {
    Get-Module -ListAvailable 'Pester' | Out-Null
}

Measure-Section "Module: Get-Module -ListAvailable 'SecretManagement'" {
    Get-Module -ListAvailable 'Microsoft.PowerShell.SecretManagement' | Out-Null
}

Measure-Section "Module: Get-Module -ListAvailable 'SecretStore'" {
    Get-Module -ListAvailable 'Microsoft.PowerShell.SecretStore' | Out-Null
}

# ── 6. Miscellaneous ──
Measure-Section "Test-Path checks (repo + functions dir)" {
    Test-Path "$repo\.git" | Out-Null
    Test-Path "$repo\Functions" | Out-Null
}

# ── Summary ──
Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  Benchmark Complete" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""

# Save results
$outFile = Join-Path $repo "Profile-Benchmark-Results.txt"
$header = @"
PowerShell Profile Benchmark Results
=====================================
Date:       $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Host:       $($env:COMPUTERNAME)
PS Version: $($PSVersionTable.PSVersion)
OS:         $([System.Environment]::OSVersion.VersionString)

"@

$tableOutput = $results | Format-Table -AutoSize | Out-String
$header + $tableOutput | Set-Content $outFile -Encoding UTF8

Write-Host "Results saved to: $outFile" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next step: Share the results file or paste the output above." -ForegroundColor Yellow
Write-Host ""
