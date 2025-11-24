function Net-Test {
    <#
    .SYNOPSIS
        CBIT Network Performance Test with auto-diagnostics
    .EXAMPLE
        ntest                   # Quick 10-second test to default target
        ntest -Launcher         # Interactive menu
        ntest -Duration 30 -Streams 4
    #>

    [CmdletBinding()]
    param(
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete)
            $common = "192.168.0.1","192.168.1.1","10.0.0.1","8.8.8.8","1.1.1.1"
            $common | Where-Object { $_ -like "$wordToComplete*" }
        })]
        [string]$TargetIP = "192.168.1.100",

        [int]$Duration = 10,
        [int]$Port = 5201,
        [int]$Streams = 1,

        [switch]$VerboseOutput,
        [switch]$ForceDownload,  # Also enables internet test
        [switch]$Launcher,
        [switch]$InternetTest    # Explicitly enable internet test
    )

    # ── Interactive Launcher Menu ─────────────────────────────────────
    if ($Launcher) {
        Clear-Host
        Write-Host "================= CBIT Net-Test Launcher =================`n" -ForegroundColor Cyan
        Write-Host "1) Quick Test        (10s, 1 stream)"
        Write-Host "2) Deep Test         (60s, 4 streams)"
        Write-Host "3) Wi-Fi Diagnostics (15s, verbose)"
        Write-Host "4) Bottleneck Hunt   (20s, 4 streams, incl. internet)"
        Write-Host "`nQ) Quit`n"
        $choice = (Read-Host "Select").ToUpper()
        if ($choice -eq "Q") { return }
        if ($choice -notin "1","2","3","4") { Write-Host "Invalid choice" -ForegroundColor Red; return }

        $target = Read-Host "Enter Target IP (press Enter for default: 192.168.1.100)"
        if ([string]::IsNullOrEmpty($target)) { $target = "192.168.1.100" }

        switch ($choice) {
            "1" { Net-Test -TargetIP $target -Duration 10 -Streams 1; return }
            "2" { Net-Test -TargetIP $target -Duration 60 -Streams 4; return }
            "3" { Net-Test -TargetIP $target -Duration 15 -Streams 2 -VerboseOutput; return }
            "4" { Net-Test -TargetIP $target -Duration 20 -Streams 4 -InternetTest; return }
        }
    }

    # Prompt for TargetIP if not explicitly provided (non-launcher mode)
    if (-not $PSBoundParameters.ContainsKey('TargetIP')) {
        $TargetIP = Read-Host "Enter Target IP (press Enter for default: 192.168.1.100)"
        if ([string]::IsNullOrEmpty($TargetIP)) { $TargetIP = "192.168.1.100" }
    }

    # ── Auto-Install iperf3 if Missing ────────────────────────────────
    $iperfDir = "$env:LOCALAPPDATA\iperf3"
    $iperfPath = "$iperfDir\iperf3.exe"
    if (-not (Test-Path $iperfPath)) {
        $downloadUrl = "https://github.com/ar51an/iperf3-win-builds/releases/download/3.20/iperf3_3.20_win64.zip"
        $tempZip = "$env:TEMP\iperf.zip"
        $tempExtract = "$env:TEMP\iperf_extract"
        try {
            Invoke-WebRequest -Uri $downloadUrl -OutFile $tempZip -UseBasicParsing -ErrorAction Stop
            if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue }
            Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force -ErrorAction Stop
            $extractedFolder = Get-ChildItem $tempExtract | Select-Object -First 1 -ExpandProperty Name
            if (-not (Test-Path $iperfDir)) { New-Item -ItemType Directory -Path $iperfDir -Force | Out-Null }
            Move-Item -Path "$tempExtract\$extractedFolder\*" -Destination $iperfDir -Force -ErrorAction Stop
            Remove-Item $tempZip, $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Warning "Failed to auto-install iperf3: $_. Falling back to latency test."
            $iperfPath = $null
        }
    }
    $hasIperf = (Test-Path $iperfPath)

    # ── Adapter & Wi-Fi Detection ─────────────────────────────────────
    $Adapter = Get-NetAdapter | Where-Object Status -eq "Up" | Sort-Object LinkSpeed -Descending | Select-Object -First 1
    $WiFiInfo = $null; $Signal = $null; $SSID = $null

    if ($Adapter.InterfaceDescription -match "Wireless|Wi.?Fi|802\.11") {
        $wlan = netsh wlan show interfaces
        $WiFiInfo = $wlan
        $SSID     = ($wlan | Select-String "SSID"     | Where-Object { $_ -notmatch "BSSID" } | ForEach-Object ToString).Split(":",2)[-1].Trim()
        $Signal   = ($wlan | Select-String "Signal"  ).ToString().Split(":",2)[-1].Trim()
        if ($VerboseOutput) {
            Write-Host "`n=== Wi-Fi Details ===" -ForegroundColor Cyan
            $WiFiInfo | Write-Host
        }
    }

    # ── Get Default Gateway ───────────────────────────────────────────
    $gateway = (Get-NetRoute | Where-Object DestinationPrefix -eq '0.0.0.0/0' | Select-Object -ExpandProperty NextHop -First 1)

    # ── Define Tests ──────────────────────────────────────────────────
    $tests = @(
        [pscustomobject]@{IP=$gateway; Port=$Port; Desc="Gateway (Local LAN)"}
        [pscustomobject]@{IP=$TargetIP; Port=$Port; Desc="Target Path"}
    )
    if ($InternetTest -or $ForceDownload) {
        $tests += [pscustomobject]@{IP="la.speedtest.clouvider.net"; Port=5201; Desc="Internet (Public US Server)"}  # Reliable 10G public server
    }

    # ── Run Bandwidth Tests ───────────────────────────────────────────
    $Results = @()
    foreach ($test in $tests) {
        $ip = $test.IP
        $port = $test.Port
        $desc = $test.Desc
        if (-not $ip) { continue }

        Write-Host "`nRunning test to $desc ($($ip):$($port))..." -ForegroundColor Cyan
        try {
            if ($hasIperf) {
                # iperf3 for bandwidth
                $iperfArgs = @("-c", $ip, "-p", $port, "-t", $Duration, "-P", $Streams, "-R", "-f", "m", "--get-server-output")
                $output = & $iperfPath $iperfArgs 2>&1
                if ($VerboseOutput) { $output | Write-Host -ForegroundColor Gray }

                # Parse download speed from [SUM] receiver line
                $sumLine = $output | Select-String "\[SUM\].*receiver" | Select-Object -Last 1
                $bw = if ($sumLine) { [double]($sumLine.Line -split '\s+')[6] } else { 0 }

                $grade = if ($bw -gt 500) { "GREEN ✅" } elseif ($bw -gt 100) { "YELLOW ⚠️" } else { "RED ❌" }
                $Results += [pscustomobject]@{ Target = $desc; Metric = "$([math]::Round($bw, 2)) Mbps"; Grade = $grade }
            } else {
                # Fallback to Test-NetConnection for latency (ICMP ping)
                $tnc = Test-NetConnection $ip -InformationLevel Detailed -WarningAction SilentlyContinue
                $latency = if ($tnc.PingSucceeded) { $tnc.PingReplyDetails.RoundtripTime } else { 9999 }

                $grade = if ($latency -lt 20) { "GREEN ✅" } elseif ($latency -lt 100) { "YELLOW ⚠️" } else { "RED ❌" }
                $Results += [pscustomobject]@{ Target = $desc; Metric = "$latency ms latency"; Grade = $grade }
            }
        } catch {
            Write-Error "Test to $desc failed: $_"
            $Results += [pscustomobject]@{ Target = $desc; Metric = "Failed"; Grade = "RED ❌" }
        }
    }

    # ── Output Test Results ───────────────────────────────────────────
    if ($Results.Count -gt 0) {
        Write-Host "`n=== Test Results ===" -ForegroundColor Cyan
        $Results | Format-Table Target, Metric, Grade -AutoSize
    }

    # ── Performance Badges ────────────────────────────────────────────
    $Badges = @()

    # Client NIC speed check
    $speedNum = 0
    if ($Adapter.LinkSpeed -match '(\d+(\.\d+)?)\s*([GM])bps') {
        $val = [double]$matches[1]
        $speedNum = if ($matches[3] -eq 'G') { $val * 1000 } else { $val }
    }
    if ($speedNum -lt 1000 -and $speedNum -gt 0) {
        $Badges += "Client NIC Limiting Speed (Only $($Adapter.LinkSpeed)) 🐢"
    }

    # Weak Wi-Fi signal
    if ($Signal) {
        $pct = [int]($Signal -replace '\D')
        if ($pct -lt 65) { $Badges += "Weak Wi-Fi Signal ($Signal) 📶" }
    }

    # Switch / path bottleneck detection (only if we actually have results)
    if ($Results.Count -ge 2 -and $Results[0].Grade -eq "GREEN ✅" -and $Results[1].Grade -ne "GREEN ✅") {
        $Badges += "Possible Switch/Intermediate Bottleneck 🔀"
    }
    if ($Results.Count -ge 3 -and $Results[1].Grade -eq "GREEN ✅" -and $Results[2].Grade -ne "GREEN ✅") {
        $Badges += "Target Path Limitation 🎯"
    }

    # ── Final Output ──────────────────────────────────────────────────
    Write-Host "`n=== Performance Indicators ===" -ForegroundColor Magenta
    if ($Badges.Count -eq 0) {
        Write-Host "No bottlenecks detected ✅" -ForegroundColor Green
    } else {
        $Badges | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
    }
    Write-Host ""   # blank line for readability
}

# Safe alias (only this runs when the file is dot-sourced)
Set-Alias -Name ntest -Value Net-Test -Scope Global