function Test-Network {
    <#
    .SYNOPSIS
        Comprehensive network testing tool with LAN/WAN/Internet speed tests
    
    .DESCRIPTION
        Multi-mode network tester supporting:
        - LAN throughput (iperf3 to local server)
        - WAN throughput (iperf3 to public servers)
        - Internet speed (Speedtest.net CLI)
    
    .PARAMETER Mode
        Test mode: LAN, WAN, Internet, or Interactive (default)
    
    .PARAMETER Target
        Target hostname or IP (for LAN/WAN modes)
    
    .EXAMPLE
        Test-Network
        Interactive mode with menu selection
    
    .EXAMPLE
        Test-Network -Mode Internet
        Direct internet speed test
    
    .EXAMPLE
        Test-Network -Mode LAN -Target 192.168.1.100
        LAN throughput test to specific host
    #>
    
    [CmdletBinding()]
    param(
        [ValidateSet('Interactive', 'LAN', 'WAN', 'Internet')]
        [string]$Mode = 'Interactive',
        
        [string]$Target
    )
    
    # ══════════════════════════════════════════════════════════════════════════
    # Helper Functions
    # ══════════════════════════════════════════════════════════════════════════
    
    function Show-TestMenu {
        Write-Color "`n═══════════════════════════════════════" 'Header'
        Write-Color "    Network Testing Suite" 'Header'
        Write-Color "═══════════════════════════════════════`n" 'Header'

        Write-Color "Select test mode:`n" 'Header'
        Write-Color "  [1] LAN Throughput Test"
        Write-Color "      └─ Requires local iperf3 server" 'Detail'
        Write-Host ""
        Write-Color "  [2] WAN Throughput Test"
        Write-Color "      └─ Tests against public iperf servers" 'Detail'
        Write-Host ""
        Write-Color "  [3] Internet Speed Test"
        Write-Color "      └─ Uses Speedtest.net CLI (Ookla)" 'Detail'
        Write-Host ""
        Write-Color "  [Q] Quit`n" 'Detail'
        
        do {
            $choice = Read-Host "Choose an option"
            
            $result = switch ($choice) {
                '1' { 'LAN'; break }
                '2' { 'WAN'; break }
                '3' { 'Internet'; break }
                { $_ -match '^[Qq]$' } { $null; break }
                default { 
                    Write-Color "Invalid choice. Please try again." 'Bad'
                    'retry'
                }
            }
            
            if ($result -ne 'retry') {
                return $result
            }
        } while ($true)
    }
    
    function Get-PublicServers {
        return @(
            @{ Host = "la.speedtest.clouvider.net";  Port = 5201; Location = "Los Angeles, CA"; Recommended = $true }
            @{ Host = "dal.speedtest.clouvider.net"; Port = 5201; Location = "Dallas, TX"; Recommended = $false }
            @{ Host = "chi.speedtest.clouvider.net"; Port = 5201; Location = "Chicago, IL"; Recommended = $false }
            @{ Host = "nyc.speedtest.clouvider.net"; Port = 5201; Location = "New York, NY"; Recommended = $false }
        )
    }
    
    function Select-TargetServer {
        param([string]$TestMode)
        
        if ($Target) {
            Write-Color "`n$($global:CbitCheck) Using target: $Target" 'Good'
            return $Target
        }
        
        if ($TestMode -eq 'LAN') {
            $input = Read-Host "`nEnter target IP or hostname (Q to cancel)"
            if ($input -match '^[Qq]$') { return $null }
            return $input
        }
        
        # WAN mode - show public servers
        $servers = Get-PublicServers
        
        Write-Color "`n═══════════════════════════════════════" 'Header'
        Write-Color "  Public iperf3 Test Servers" 'Header'
        Write-Color "═══════════════════════════════════════`n" 'Header'

        for ($i = 0; $i -lt $servers.Count; $i++) {
            $marker = if ($servers[$i].Recommended) { "⭐ Recommended" } else { "" }
            Write-Color "  [$($i+1)] $($servers[$i].Host)"
            Write-Color "      └─ $($servers[$i].Location) $marker" 'Detail'
        }
        
        do {
            $choice = Read-Host "`nSelect server (1-$($servers.Count), Q to cancel)"
            if ($choice -match '^[Qq]$') { return $null }
            if ($choice -match "^\d+$" -and [int]$choice -ge 1 -and [int]$choice -le $servers.Count) {
                return $servers[[int]$choice - 1].Host
            }
            Write-Color "Invalid choice. Please try again." 'Bad'
        } while ($true)
    }
    
    function Test-Latency {
        param([string]$Target)
        
        Write-Color "`n[1/2] Testing latency..." 'Header'
        
        try {
            $pingResults = Test-Connection -ComputerName $Target -Count 4 -ErrorAction Stop
            $stats = $pingResults | Measure-Object -Property ResponseTime -Average -Minimum -Maximum
            
            $result = @{
                Average = [math]::Round($stats.Average, 1)
                Min     = $stats.Minimum
                Max     = $stats.Maximum
                Success = $true
            }
            
            Write-Color "  $($global:CbitCheck) Latency: $($result.Average)ms (min: $($result.Min)ms, max: $($result.Max)ms)" 'Good'
            return $result
        }
        catch {
            Write-Color "  $($global:CbitWarnGlyph) Latency test failed (ICMP may be blocked)" 'Warn'
            return @{ Average = 'N/A'; Success = $false }
        }
    }
    
    function Test-TCPThroughput {
        param(
            [string]$Target,
            [int]$Port = 5201,
            [int]$Duration = 5
        )
        
        Write-Color "`n[2/2] Testing TCP throughput ($Duration seconds)..." 'Header'
        
        $client = New-Object System.Net.Sockets.TcpClient
        
        try {
            # Attempt connection with timeout
            $asyncResult = $client.BeginConnect($Target, $Port, $null, $null)
            $waitHandle = $asyncResult.AsyncWaitHandle
            
            if (-not $waitHandle.WaitOne(5000, $false)) {
                throw "Connection timeout after 5 seconds"
            }
            
            $client.EndConnect($asyncResult)
            Write-Color "  $($global:CbitCheck) Connected to $Target`:$Port" 'Good'
            
        }
        catch {
            Write-Color "  $($global:CbitCross) Failed to connect to $Target`:$Port" 'Bad'
            Write-Color "    Ensure iperf3 server is running:" 'Detail'
            Write-Color "      iperf3 -s" 'Header'
            $client.Dispose()
            return $null
        }
        
        # Configure buffer and stream
        $stream = $client.GetStream()
        $bufferSize = 128KB  # Increased from 64KB
        $buffer = New-Object byte[] $bufferSize
        
        # Fill buffer with random data (more realistic)
        $rng = New-Object System.Random
        $rng.NextBytes($buffer)
        
        # Throughput test
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $totalBytes = 0
        $lastUpdate = 0
        
        Write-Color "  ⏱ Testing..." 'Detail' -NoNewline
        
        try {
            while ($stopwatch.Elapsed.TotalSeconds -lt $Duration) {
                $stream.Write($buffer, 0, $buffer.Length)
                $totalBytes += $buffer.Length
                
                # Progress indicator every 0.5 seconds
                if ($stopwatch.Elapsed.TotalSeconds - $lastUpdate -ge 0.5) {
                    Write-Color "." 'Detail' -NoNewline
                    $lastUpdate = $stopwatch.Elapsed.TotalSeconds
                }
            }
            Write-Color " Done!" 'Good'
        }
        catch {
            Write-Color " Error!" 'Bad'
            Write-Warning "Stream interrupted: $_"
        }
        finally {
            $stopwatch.Stop()
            $stream.Close()
            $client.Close()
            $client.Dispose()
        }
        
        # Calculate results
        $seconds = $stopwatch.Elapsed.TotalSeconds
        $mbps = [math]::Round((($totalBytes * 8) / 1000000) / $seconds, 2)
        $mbytes = [math]::Round($totalBytes / 1MB, 2)
        
        return @{
            Mbps      = $mbps
            MBytes    = $mbytes
            Duration  = [math]::Round($seconds, 2)
            BytesSent = $totalBytes
        }
    }
    
    function Show-Results {
        param(
            [string]$Target,
            [hashtable]$Latency,
            [hashtable]$Throughput,
            [string]$TestType
        )
        
        Write-Color "`n═══════════════════════════════════════" 'Header'
        Write-Color "  Test Results" 'Header'
        Write-Color "═══════════════════════════════════════`n" 'Header'

        Write-Color "Target:      $Target"
        Write-Color "Test Type:   $TestType"

        if ($Latency.Success) {
            Write-Color "Latency:     $($Latency.Average)ms (min: $($Latency.Min)ms, max: $($Latency.Max)ms)"
        } else {
            Write-Color "Latency:     N/A" 'Detail'
        }

        if ($Throughput) {
            Write-Color "Throughput:  $($Throughput.Mbps) Mbps"
            Write-Color "Data Sent:   $($Throughput.MBytes) MB in $($Throughput.Duration)s`n"

            # Performance rating
            $rating = Get-PerformanceRating -Mbps $Throughput.Mbps -Target $Target -TestType $TestType
            Write-Color $rating.Message $rating.Color
            Write-Host ""
        }
    }
    
    function Get-PerformanceRating {
        param(
            [double]$Mbps,
            [string]$Target,
            [string]$TestType
        )
        
        # Determine if target is private/LAN
        $isPrivate = $false
        try {
            $ip = ([System.Net.Dns]::GetHostAddresses($Target))[0].IPAddressToString
            $isPrivate = $ip -match '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.|169\.254\.|fd)'
        } catch {}
        
        if ($TestType -eq 'LAN' -or $isPrivate) {
            # LAN performance ratings
            if ($Mbps -ge 900) {
                return @{ Message = "$($global:CbitCheck) Excellent - Near gigabit speeds!"; Color = 'Good' }
            } elseif ($Mbps -ge 700) {
                return @{ Message = "$($global:CbitCheck) Great - Good LAN performance"; Color = 'Good' }
            } elseif ($Mbps -ge 300) {
                return @{ Message = "$($global:CbitWarnGlyph)  Fair - Possible bottleneck (check NIC/switch/cables)"; Color = 'Warn' }
            } else {
                return @{ Message = "$($global:CbitCross) Poor - Significant LAN bottleneck detected"; Color = 'Bad' }
            }
        } else {
            # WAN performance ratings
            if ($Mbps -ge 500) {
                return @{ Message = "$($global:CbitCheck) Excellent - Premium connection speeds"; Color = 'Good' }
            } elseif ($Mbps -ge 200) {
                return @{ Message = "$($global:CbitCheck) Great - Above-average WAN performance"; Color = 'Good' }
            } elseif ($Mbps -ge 100) {
                return @{ Message = "$($global:CbitCheck)  Good - Typical ISP speeds"; Color = 'Good' }
            } elseif ($Mbps -ge 50) {
                return @{ Message = "$($global:CbitWarnGlyph)  Fair - Below typical broadband speeds"; Color = 'Warn' }
            } else {
                return @{ Message = "$($global:CbitCross) Poor - Possible throttling or congestion"; Color = 'Bad' }
            }
        }
    }
    
    # ══════════════════════════════════════════════════════════════════════════
    # Main Execution
    # ══════════════════════════════════════════════════════════════════════════
    
    # Interactive menu if mode not specified
    if ($Mode -eq 'Interactive') {
        $selectedMode = Show-TestMenu
        if (-not $selectedMode) {
            Write-Color "`nTest cancelled.`n" 'Detail'
            return
        }
        $Mode = $selectedMode
    }
    
    # Internet speed test (separate function)
    if ($Mode -eq 'Internet') {
        if (Get-Command Invoke-InternetSpeedTest -ErrorAction SilentlyContinue) {
            Invoke-InternetSpeedTest
        } else {
            Write-Color "$($global:CbitCross) Invoke-InternetSpeedTest function not found" 'Bad'
            Write-Color "   Ensure Invoke-InternetSpeedTest.ps1 is loaded" 'Warn'
        }
        return
    }
    
    # Get target server
    $targetHost = Select-TargetServer -TestMode $Mode
    if (-not $targetHost) {
        Write-Color "`nTest cancelled.`n" 'Detail'
        return
    }
    
    Write-Color "`n═══════════════════════════════════════" 'Header'
    Write-Color "  Starting $Mode Test" 'Header'
    Write-Color "═══════════════════════════════════════" 'Header'
    
    # Run tests
    $latency = Test-Latency -Target $targetHost
    $throughput = Test-TCPThroughput -Target $targetHost -Port 5201 -Duration 5
    
    # Show results
    if ($throughput) {
        Show-Results -Target $targetHost -Latency $latency -Throughput $throughput -TestType $Mode
    } else {
        Write-Color "`n$($global:CbitCross) Throughput test failed. Check server connectivity.`n" 'Bad'
    }
}

# Aliases - support both old and new names
Set-Alias -Name net-test -Value Test-Network -Scope Global
Set-Alias -Name Invoke-NetTest -Value Test-Network -Scope Global  # Backward compatibility