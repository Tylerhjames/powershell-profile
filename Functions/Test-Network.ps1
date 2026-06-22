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
        Write-Host "`n═══════════════════════════════════════" -ForegroundColor Cyan
        Write-Host "    Network Testing Suite" -ForegroundColor Cyan
        Write-Host "═══════════════════════════════════════`n" -ForegroundColor Cyan
        
        Write-Host "Select test mode:`n" -ForegroundColor Yellow
        Write-Host "  [1] LAN Throughput Test" -ForegroundColor White
        Write-Host "      └─ Requires local iperf3 server" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  [2] WAN Throughput Test" -ForegroundColor White
        Write-Host "      └─ Tests against public iperf servers" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  [3] Internet Speed Test" -ForegroundColor White
        Write-Host "      └─ Uses Speedtest.net CLI (Ookla)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  [Q] Quit`n" -ForegroundColor DarkGray
        
        do {
            $choice = Read-Host "Choose an option"
            
            $result = switch ($choice) {
                '1' { 'LAN'; break }
                '2' { 'WAN'; break }
                '3' { 'Internet'; break }
                { $_ -match '^[Qq]$' } { $null; break }
                default { 
                    Write-Host "Invalid choice. Please try again." -ForegroundColor Red
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
            Write-Host "`n✓ Using target: $Target" -ForegroundColor Green
            return $Target
        }
        
        if ($TestMode -eq 'LAN') {
            $input = Read-Host "`nEnter target IP or hostname (Q to cancel)"
            if ($input -match '^[Qq]$') { return $null }
            return $input
        }
        
        # WAN mode - show public servers
        $servers = Get-PublicServers
        
        Write-Host "`n═══════════════════════════════════════" -ForegroundColor Cyan
        Write-Host "  Public iperf3 Test Servers" -ForegroundColor Cyan
        Write-Host "═══════════════════════════════════════`n" -ForegroundColor Cyan
        
        for ($i = 0; $i -lt $servers.Count; $i++) {
            $marker = if ($servers[$i].Recommended) { "⭐ Recommended" } else { "" }
            Write-Host "  [$($i+1)] $($servers[$i].Host)" -ForegroundColor White
            Write-Host "      └─ $($servers[$i].Location) $marker" -ForegroundColor Gray
        }
        
        do {
            $choice = Read-Host "`nSelect server (1-$($servers.Count), Q to cancel)"
            if ($choice -match '^[Qq]$') { return $null }
            if ($choice -match "^\d+$" -and [int]$choice -ge 1 -and [int]$choice -le $servers.Count) {
                return $servers[[int]$choice - 1].Host
            }
            Write-Host "Invalid choice. Please try again." -ForegroundColor Red
        } while ($true)
    }
    
    function Test-Latency {
        param([string]$Target)
        
        Write-Host "`n[1/2] Testing latency..." -ForegroundColor Yellow
        
        try {
            $pingResults = Test-Connection -ComputerName $Target -Count 4 -ErrorAction Stop
            $stats = $pingResults | Measure-Object -Property ResponseTime -Average -Minimum -Maximum
            
            $result = @{
                Average = [math]::Round($stats.Average, 1)
                Min     = $stats.Minimum
                Max     = $stats.Maximum
                Success = $true
            }
            
            Write-Host "  ✓ Latency: $($result.Average)ms (min: $($result.Min)ms, max: $($result.Max)ms)" -ForegroundColor Green
            return $result
        }
        catch {
            Write-Host "  ⚠ Latency test failed (ICMP may be blocked)" -ForegroundColor Yellow
            return @{ Average = 'N/A'; Success = $false }
        }
    }
    
    function Test-TCPThroughput {
        param(
            [string]$Target,
            [int]$Port = 5201,
            [int]$Duration = 5
        )
        
        Write-Host "`n[2/2] Testing TCP throughput ($Duration seconds)..." -ForegroundColor Yellow
        
        $client = New-Object System.Net.Sockets.TcpClient
        
        try {
            # Attempt connection with timeout
            $asyncResult = $client.BeginConnect($Target, $Port, $null, $null)
            $waitHandle = $asyncResult.AsyncWaitHandle
            
            if (-not $waitHandle.WaitOne(5000, $false)) {
                throw "Connection timeout after 5 seconds"
            }
            
            $client.EndConnect($asyncResult)
            Write-Host "  ✓ Connected to $Target`:$Port" -ForegroundColor Green
            
        }
        catch {
            Write-Host "  ✗ Failed to connect to $Target`:$Port" -ForegroundColor Red
            Write-Host "    Ensure iperf3 server is running:" -ForegroundColor Gray
            Write-Host "      iperf3 -s" -ForegroundColor White
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
        
        Write-Host "  ⏱ Testing..." -ForegroundColor Gray -NoNewline
        
        try {
            while ($stopwatch.Elapsed.TotalSeconds -lt $Duration) {
                $stream.Write($buffer, 0, $buffer.Length)
                $totalBytes += $buffer.Length
                
                # Progress indicator every 0.5 seconds
                if ($stopwatch.Elapsed.TotalSeconds - $lastUpdate -ge 0.5) {
                    Write-Host "." -ForegroundColor Gray -NoNewline
                    $lastUpdate = $stopwatch.Elapsed.TotalSeconds
                }
            }
            Write-Host " Done!" -ForegroundColor Green
        }
        catch {
            Write-Host " Error!" -ForegroundColor Red
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
        
        Write-Host "`n═══════════════════════════════════════" -ForegroundColor Cyan
        Write-Host "  Test Results" -ForegroundColor Cyan
        Write-Host "═══════════════════════════════════════`n" -ForegroundColor Cyan
        
        Write-Host "Target:      $Target" -ForegroundColor White
        Write-Host "Test Type:   $TestType" -ForegroundColor White
        
        if ($Latency.Success) {
            Write-Host "Latency:     $($Latency.Average)ms (min: $($Latency.Min)ms, max: $($Latency.Max)ms)" -ForegroundColor White
        } else {
            Write-Host "Latency:     N/A" -ForegroundColor Gray
        }
        
        if ($Throughput) {
            Write-Host "Throughput:  $($Throughput.Mbps) Mbps" -ForegroundColor White
            Write-Host "Data Sent:   $($Throughput.MBytes) MB in $($Throughput.Duration)s`n" -ForegroundColor White
            
            # Performance rating
            $rating = Get-PerformanceRating -Mbps $Throughput.Mbps -Target $Target -TestType $TestType
            Write-Host $rating.Message -ForegroundColor $rating.Color
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
                return @{ Message = "🚀 Excellent - Near gigabit speeds!"; Color = 'Green' }
            } elseif ($Mbps -ge 700) {
                return @{ Message = "✅ Great - Good LAN performance"; Color = 'Green' }
            } elseif ($Mbps -ge 300) {
                return @{ Message = "⚠️  Fair - Possible bottleneck (check NIC/switch/cables)"; Color = 'Yellow' }
            } else {
                return @{ Message = "❌ Poor - Significant LAN bottleneck detected"; Color = 'Red' }
            }
        } else {
            # WAN performance ratings
            if ($Mbps -ge 500) {
                return @{ Message = "🚀 Excellent - Premium connection speeds"; Color = 'Green' }
            } elseif ($Mbps -ge 200) {
                return @{ Message = "✅ Great - Above-average WAN performance"; Color = 'Green' }
            } elseif ($Mbps -ge 100) {
                return @{ Message = "✔️  Good - Typical ISP speeds"; Color = 'Cyan' }
            } elseif ($Mbps -ge 50) {
                return @{ Message = "⚠️  Fair - Below typical broadband speeds"; Color = 'Yellow' }
            } else {
                return @{ Message = "❌ Poor - Possible throttling or congestion"; Color = 'Red' }
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
            Write-Host "`nTest cancelled.`n" -ForegroundColor Gray
            return
        }
        $Mode = $selectedMode
    }
    
    # Internet speed test (separate function)
    if ($Mode -eq 'Internet') {
        if (Get-Command Invoke-InternetSpeedTest -ErrorAction SilentlyContinue) {
            Invoke-InternetSpeedTest
        } else {
            Write-Host "❌ Invoke-InternetSpeedTest function not found" -ForegroundColor Red
            Write-Host "   Ensure Invoke-InternetSpeedTest.ps1 is loaded" -ForegroundColor Yellow
        }
        return
    }
    
    # Get target server
    $targetHost = Select-TargetServer -TestMode $Mode
    if (-not $targetHost) {
        Write-Host "`nTest cancelled.`n" -ForegroundColor Gray
        return
    }
    
    Write-Host "`n═══════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Starting $Mode Test" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════" -ForegroundColor Cyan
    
    # Run tests
    $latency = Test-Latency -Target $targetHost
    $throughput = Test-TCPThroughput -Target $targetHost -Port 5201 -Duration 5
    
    # Show results
    if ($throughput) {
        Show-Results -Target $targetHost -Latency $latency -Throughput $throughput -TestType $Mode
    } else {
        Write-Host "`n❌ Throughput test failed. Check server connectivity.`n" -ForegroundColor Red
    }
}

# Aliases - support both old and new names
Set-Alias -Name net-test -Value Test-Network -Scope Global
Set-Alias -Name Invoke-NetTest -Value Test-Network -Scope Global  # Backward compatibility