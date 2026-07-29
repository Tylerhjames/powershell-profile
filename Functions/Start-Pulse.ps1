function Start-Pulse {
    <#
    .SYNOPSIS
    CBIT PULSE — Interactive connectivity and latency monitor.

    .DESCRIPTION
    Tracks TCP port or ICMP ping connectivity to a target over time.
    Logs results to CSV and/or TXT with per-check latency tracking,
    uptime percentages, and automatic public IP refresh on state changes.

    Runs an interactive 6-step setup wizard, then monitors until the
    duration expires or Ctrl+C is pressed.

    .EXAMPLE
    Start-Pulse
    Launches the interactive configuration wizard.
    #>
    [CmdletBinding()]
    param()

    # ── Internal helpers (scoped to this function) ──

    function _Pulse_GetPublicIP {
        try { (Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 2).Trim() }
        catch { return "Unknown (Offline?)" }
    }

    function _Pulse_TestPort {
        param([string]$Computer, [int]$Port, [int]$TimeoutMs = 2000)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            $conn = $tcp.BeginConnect($Computer, $Port, $null, $null)
            $wait = $conn.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
            if ($wait -and $tcp.Connected) {
                $tcp.EndConnect($conn)
                $sw.Stop()
                return @{ Success = $true; LatencyMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) }
            }
            $sw.Stop()
            return @{ Success = $false; LatencyMs = 0 }
        }
        catch {
            $sw.Stop()
            return @{ Success = $false; LatencyMs = 0 }
        }
        finally { $tcp.Close() }
    }

    # ── Themed output (Write-Color handles ANSI detection itself) ──
    function _Pulse_WriteSage {
        param([string]$Text)
        Write-Color $Text 'Header'
    }
    function _Pulse_WriteMeta {
        param([string]$Text)
        Write-Color $Text 'Detail'
    }

    # ── Configuration defaults ──
    $Config = @{
        Target      = ""
        Ports       = @()
        DurationHrs = 4
        Interval    = 30
        LogType     = 3
        OutFolder   = [Environment]::GetFolderPath("Desktop")
    }

    # ════════════════════════════════════════════════════════════════════════
    # Interactive Configuration Wizard
    # ════════════════════════════════════════════════════════════════════════

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Stop"

    Clear-Host
    _Pulse_WriteSage "============================================================"
    _Pulse_WriteSage "  CBIT PULSE - Connectivity Tester"
    _Pulse_WriteMeta "  Professional grade connection stability and latency tracking."
    _Pulse_WriteMeta "  Tracks TCP/ICMP uptime with automated CSV & Text reporting."
    _Pulse_WriteSage "============================================================"
    _Pulse_WriteMeta "  (Type 'b' or 'back' to return | 'exit' to cancel | Empty Port for Ping)"

    $CurrentStep = 1
    while ($CurrentStep -le 6) {
        try {
            switch ($CurrentStep) {
                1 {
                    _Pulse_WriteSage "`n[STEP 1] Target Host"
                    _Pulse_WriteMeta "  Example: 8.8.8.8 | gateway.client.com"
                    $UserInput = Read-Host "  >> Target"
                    if ($UserInput -eq "exit") { Write-Color "Cancelled." 'Detail'; $ErrorActionPreference = $prevEAP; return }
                    if ($UserInput -eq "b" -or $UserInput -eq "back") { continue }
                    if ($UserInput -match "^[a-zA-Z0-9._:\-]+$") { $Config.Target = $UserInput; $CurrentStep++ }
                    else { throw "Invalid Hostname/IP format." }
                }
                2 {
                    _Pulse_WriteSage "`n[STEP 2] Port Selection"
                    _Pulse_WriteMeta "  Example: 80,443 | 3389 | <Enter> for Ping (ICMP)"
                    $UserInput = Read-Host "  >> Port(s)"
                    if ($UserInput -eq "exit") { Write-Color "Cancelled." 'Detail'; $ErrorActionPreference = $prevEAP; return }
                    if ($UserInput -eq "b" -or $UserInput -eq "back") { $CurrentStep--; continue }
                    if ($UserInput -eq "") { $Config.Ports = @(); $CurrentStep++ }
                    elseif ($UserInput -match "^[\d,\s]+$") {
                        $Parsed = $UserInput -split "," | ForEach-Object { [int]$_.Trim() }
                        $Invalid = $Parsed | Where-Object { $_ -lt 1 -or $_ -gt 65535 }
                        if ($Invalid) { throw "Port(s) out of range (1-65535): $($Invalid -join ', ')" }
                        $Config.Ports = $Parsed
                        $CurrentStep++
                    } else { throw "Enter numeric ports or leave blank for Ping." }
                }
                3 {
                    _Pulse_WriteSage "`n[STEP 3] Duration"
                    _Pulse_WriteMeta "  Example: 0.5 (30m) | 2 (2h) | 45m (Minutes)"
                    $UserInput = Read-Host "  >> Duration [Default: $($Config.DurationHrs)h]"
                    if ($UserInput -eq "exit") { Write-Color "Cancelled." 'Detail'; $ErrorActionPreference = $prevEAP; return }
                    if ($UserInput -eq "b" -or $UserInput -eq "back") { $CurrentStep--; continue }
                    if ($UserInput -eq "") { $CurrentStep++ }
                    elseif ($UserInput -match "^(\d*\.?\d+)m$") { $Config.DurationHrs = [double]$Matches[1] / 60; $CurrentStep++ }
                    elseif ($UserInput -match "^\d*\.?\d+$") { $Config.DurationHrs = [double]$UserInput; $CurrentStep++ }
                    else { throw "Enter a number or 'm' for minutes." }
                }
                4 {
                    _Pulse_WriteSage "`n[STEP 4] Check Interval"
                    _Pulse_WriteMeta "  Example: 5 (Fast) | 30 (Standard)"
                    $UserInput = Read-Host "  >> Seconds [Default: $($Config.Interval)]"
                    if ($UserInput -eq "exit") { Write-Color "Cancelled." 'Detail'; $ErrorActionPreference = $prevEAP; return }
                    if ($UserInput -eq "b" -or $UserInput -eq "back") { $CurrentStep--; continue }
                    if ($UserInput -eq "") { $CurrentStep++ }
                    elseif ($UserInput -match "^\d+$" -and [int]$UserInput -ge 1) { $Config.Interval = [int]$UserInput; $CurrentStep++ }
                    else { throw "Enter a whole number of seconds." }
                }
                5 {
                    _Pulse_WriteSage "`n[STEP 5] Log Location"
                    _Pulse_WriteMeta "  Leave blank for Desktop"
                    $UserInput = Read-Host "  >> Path"
                    if ($UserInput -eq "exit") { Write-Color "Cancelled." 'Detail'; $ErrorActionPreference = $prevEAP; return }
                    if ($UserInput -eq "b" -or $UserInput -eq "back") { $CurrentStep--; continue }
                    if ($UserInput -ne "") { $Config.OutFolder = $UserInput.TrimEnd("\") }
                    if (-not (Test-Path $Config.OutFolder)) { New-Item -ItemType Directory -Path $Config.OutFolder -Force | Out-Null }
                    $CurrentStep++
                }
                6 {
                    _Pulse_WriteSage "`n[STEP 6] Report Format"
                    _Pulse_WriteMeta "  1: .txt | 2: .csv | 3: Both"
                    $UserInput = Read-Host "  >> Choice (1-3) [Default: 3]"
                    if ($UserInput -eq "exit") { Write-Color "Cancelled." 'Detail'; $ErrorActionPreference = $prevEAP; return }
                    if ($UserInput -eq "b" -or $UserInput -eq "back") { $CurrentStep--; continue }
                    if ($UserInput -eq "") { $CurrentStep++ }
                    elseif ($UserInput -match "^[1-3]$") { $Config.LogType = [int]$UserInput; $CurrentStep++ }
                    else { throw "Choose 1, 2, or 3." }
                }
            }
        } catch {
            Write-Color "  ERROR: $_" 'Bad'
        }
    }

    # ════════════════════════════════════════════════════════════════════════
    # Test Execution
    # ════════════════════════════════════════════════════════════════════════

    $ErrorActionPreference = "Continue"

    $Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $ModeLabel = if ($Config.Ports.Count -eq 0) { "ICMP" } else { "TCP" }
    $BaseName  = "$($Config.OutFolder)\Pulse_$($Config.Target)_${ModeLabel}_${Timestamp}"
    $TxtFile   = "$BaseName.txt"
    $CsvFile   = "$BaseName.csv"
    $PubIP     = _Pulse_GetPublicIP
    $EndTime   = (Get-Date).AddHours($Config.DurationHrs)

    # Per-check stats
    $Stats = @{}
    if ($Config.Ports.Count -eq 0) {
        $Stats["ICMP"] = @{ Pass = 0; Fail = 0; LatencySum = 0; LatencyCount = 0 }
    } else {
        foreach ($P in $Config.Ports) {
            $Stats["Port_$P"] = @{ Pass = 0; Fail = 0; LatencySum = 0; LatencyCount = 0 }
        }
    }
    $LastState = $null

    # Header logging
    $LogStart = "CBIT PULSE LOG`n" + ("-"*30) + "`nTarget: $($Config.Target)`nMode: $ModeLabel`nStarted: $(Get-Date)`nPublic IP: $PubIP`n" + ("-"*30)
    if ($Config.LogType -in 1,3) { $LogStart | Out-File $TxtFile -Encoding UTF8 }
    if ($Config.LogType -in 2,3) { "Timestamp,Target,CheckType,Status,LatencyMS,PublicIP" | Out-File $CsvFile -Encoding UTF8 }

    _Pulse_WriteSage "`n$("="*60)"
    _Pulse_WriteSage "  TEST ACTIVE | Mode: $ModeLabel | Target: $($Config.Target)"
    _Pulse_WriteMeta "  Ends: $($EndTime.ToString('HH:mm:ss')) | Ctrl+C to stop"
    _Pulse_WriteSage "$("="*60)`n"

    # ── Main test loop ──
    try {
        while ((Get-Date) -lt $EndTime) {
            $CheckTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

            if ($Config.Ports.Count -eq 0) {
                $Ping = Test-Connection -ComputerName $Config.Target -Count 1 -ErrorAction SilentlyContinue
                $Success = [bool]$Ping
                $Latency = 0
                if ($Success) {
                    if     ($Ping.PSObject.Properties['ResponseTime']) { $Latency = $Ping.ResponseTime }
                    elseif ($Ping.PSObject.Properties['Latency'])      { $Latency = $Ping.Latency }
                }
                $S = $Stats["ICMP"]
                if ($Success) { $S.Pass++; $S.LatencySum += $Latency; $S.LatencyCount++ } else { $S.Fail++ }

                $Color = if ($Success) { 'Good' } else { 'Bad' }
                Write-Color "[$CheckTime] PING : $(if($Success){'SUCCESS'}else{'FAIL'}) ($($Latency)ms)" $Color

                try {
                    if ($Config.LogType -in 1,3) { "[$CheckTime] ICMP | $(if($Success){'SUCCESS'}else{'FAIL'}) | $($Latency)ms" | Out-File $TxtFile -Append -Encoding UTF8 }
                    if ($Config.LogType -in 2,3) { "$CheckTime,$($Config.Target),ICMP,$(if($Success){'SUCCESS'}else{'FAIL'}),$Latency,$PubIP" | Out-File $CsvFile -Append -Encoding UTF8 }
                } catch { Write-Color "  [LOG WRITE ERROR] $_" 'Warn' }

                $CurrentState = $Success
                if ($null -ne $LastState -and $CurrentState -ne $LastState) {
                    $PubIP = _Pulse_GetPublicIP
                }
                $LastState = $CurrentState

            } else {
                foreach ($P in $Config.Ports) {
                    $Result  = _Pulse_TestPort -Computer $Config.Target -Port $P
                    $Success = $Result.Success
                    $Latency = $Result.LatencyMs
                    $Key     = "Port_$P"
                    $S       = $Stats[$Key]
                    if ($Success) { $S.Pass++; $S.LatencySum += $Latency; $S.LatencyCount++ } else { $S.Fail++ }

                    $Color = if ($Success) { 'Good' } else { 'Bad' }
                    Write-Color "[$CheckTime] Port $P : $(if($Success){'SUCCESS'}else{'FAIL'}) ($($Latency)ms)" $Color

                    try {
                        if ($Config.LogType -in 1,3) { "[$CheckTime] Port $P | $(if($Success){'SUCCESS'}else{'FAIL'}) | $($Latency)ms" | Out-File $TxtFile -Append -Encoding UTF8 }
                        if ($Config.LogType -in 2,3) { "$CheckTime,$($Config.Target),Port_$P,$(if($Success){'SUCCESS'}else{'FAIL'}),$Latency,$PubIP" | Out-File $CsvFile -Append -Encoding UTF8 }
                    } catch { Write-Color "  [LOG WRITE ERROR] $_" 'Warn' }
                }

                $CurrentState = (_Pulse_TestPort -Computer $Config.Target -Port $Config.Ports[0]).Success
                if ($null -ne $LastState -and $CurrentState -ne $LastState) {
                    $PubIP = _Pulse_GetPublicIP
                }
                $LastState = $CurrentState
            }
            Start-Sleep -Seconds $Config.Interval
        }
    }
    finally {
        $Summary = "`n$("="*60)`nCBIT PULSE SUMMARY`nCompleted: $(Get-Date)`n$("-"*30)"

        foreach ($Key in $Stats.Keys | Sort-Object) {
            $S     = $Stats[$Key]
            $Total = $S.Pass + $S.Fail
            $Pct   = if ($Total -gt 0) { [math]::Round(($S.Pass / $Total) * 100, 1) } else { 0 }
            $AvgL  = if ($S.LatencyCount -gt 0 -and $S.LatencySum -gt 0) { [math]::Round($S.LatencySum / $S.LatencyCount, 1) } else { 0 }
            $Summary += "`n  $Key | Pass: $($S.Pass) | Fail: $($S.Fail) | Uptime: $Pct% | Avg Latency: $($AvgL)ms"
        }

        $Summary += "`n$("-"*30)"
        $GrandPass  = ($Stats.Values | ForEach-Object { $_.Pass } | Measure-Object -Sum).Sum
        $GrandFail  = ($Stats.Values | ForEach-Object { $_.Fail } | Measure-Object -Sum).Sum
        $GrandTotal = $GrandPass + $GrandFail
        $GrandPct   = if ($GrandTotal -gt 0) { [math]::Round(($GrandPass / $GrandTotal) * 100, 1) } else { 0 }
        $Summary += "`n  TOTAL | Pass: $GrandPass | Fail: $GrandFail | Uptime: $GrandPct%"
        $Summary += "`n$("="*60)"

        _Pulse_WriteSage $Summary
        try {
            if ($Config.LogType -in 1,3) { $Summary | Out-File $TxtFile -Append -Encoding UTF8 }
        } catch { Write-Color "  [LOG WRITE ERROR] $_" 'Warn' }

        # Restore error preference
        $ErrorActionPreference = $prevEAP
    }
}
Set-Alias -Name pulse -Value Start-Pulse -Scope Global
