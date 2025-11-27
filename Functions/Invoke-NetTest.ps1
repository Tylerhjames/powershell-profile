function Invoke-NetTest {
    Write-Host "=== CBIT Net-Test ===" -ForegroundColor Cyan
    Write-Host "`nSelect test mode:" -ForegroundColor Yellow
    Write-Host " 1) LAN throughput test (requires local iperf server)"
    Write-Host " 2) WAN throughput test (public iperf servers)"
    Write-Host " 3) Internet speed test (Speedtest.net CLI)"
    Write-Host " Q) Quit`n"

    $mode = Read-Host "Choose an option (1-3, Q to cancel)"
    if ($mode -match "^[Qq]$") { return }

    # -------------------------
    # Option 3 - Speedtest CLI
    # -------------------------
    if ($mode -eq "3") {
        if (Get-Command Invoke-InternetSpeedTest -ErrorAction SilentlyContinue) {
            Invoke-InternetSpeedTest
            return
        } else {
            Write-Host "Invoke-InternetSpeedTest function not found." -ForegroundColor Red
            Write-Host "Ensure /Functions/Invoke-InternetSpeedTest.ps1 exists and is loaded." -ForegroundColor Yellow
            return
        }
    }

    # -------------------------
    # Target selection
    # -------------------------
    $target = Read-Host "Enter target IP or hostname (press Enter for public list, Q to cancel)"
    if ($target -match "^[Qq]$") { return }

    if ([string]::IsNullOrWhiteSpace($target)) {
        $servers = @(
            @{ Host = "la.speedtest.clouvider.net";  Recommended = $true  }
            @{ Host = "dal.speedtest.clouvider.net"; Recommended = $false }
            @{ Host = "chi.speedtest.clouvider.net"; Recommended = $false }
            @{ Host = "nyc.speedtest.clouvider.net"; Recommended = $false }
        )

        Write-Host "`nAvailable public test servers:" -ForegroundColor Yellow
        for ($i = 0; $i -lt $servers.Count; $i++) {
            $marker = if ($servers[$i].Recommended) { "Recommended" } else { "          " }
            Write-Host "$($i+1). $($servers[$i].Host) $marker"
        }

        do {
            $choice = Read-Host "`nSelect server (1-4, Q to cancel)"
            if ($choice -match "^[Qq]$") { return }
            if ($choice -match "^[1-4]$") { break }
            Write-Host "Please enter a number between 1 and 4." -ForegroundColor Red
        } while ($true)

        $target = $servers[[int]$choice - 1].Host
    }

    Write-Host "`nTesting against: $target" -ForegroundColor Cyan

    # -------------------------
    # Latency (Ping)
    # -------------------------
    try {
        $ping = Test-Connection -ComputerName $target -Count 2 -ErrorAction Stop
        $latency = [math]::Round(($ping | Measure-Object -Property ResponseTime -Average).Average, 1)
        Write-Host "Latency: $latency ms`n" -ForegroundColor Green
    }
    catch {
        $latency = "N/A"
        Write-Host "Latency: N/A (ICMP blocked or host unreachable)" -ForegroundColor Yellow
    }

    # -------------------------
    # Rough TCP Throughput Test (3-second blast on port 5201)
    # -------------------------
    $port = 5201
    $client = New-Object System.Net.Sockets.TcpClient

    try {
        $client.Connect($target, $port)
        Write-Host "Connected to iperf3 server on port $port" -ForegroundColor Green
    }
    catch {
        Write-Host "Unable to connect to iperf3 server on $target`:$port" -ForegroundColor Red
        Write-Host "   Make sure an iperf3 server is running in normal (not reverse) mode." -ForegroundColor Gray
        $client.Dispose()
        return
    }

    $stream = $client.GetStream()
    $buffer = New-Object byte[] (64KB)
    (New-Object System.Random).NextBytes($buffer)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $totalBytes = 0

    try {
        while ($sw.Elapsed.TotalSeconds -lt 3) {
            $stream.Write($buffer, 0, $buffer.Length)
            $totalBytes += $buffer.Length
        }
    }
    catch {
        Write-Host "Stream interrupted early." -ForegroundColor Yellow
    }

    $sw.Stop()
    $stream.Close()
    $client.Close()

    $seconds = $sw.Elapsed.TotalSeconds
    $mbps = [math]::Round((($totalBytes * 8) / 1MB) / $seconds, 1)

    # -------------------------
    # Results & Rating
    # -------------------------
    Write-Host "`n=== Results ===" -ForegroundColor Cyan
    Write-Host "Target       : $target"
    Write-Host "Latency      : $latency"
    Write-Host "Throughput   : $mbps Mbps (3-second TCP blast)`n"

    # Determine if target is likely private/LAN
    try {
        $ip = ([System.Net.Dns]::GetHostAddresses($target))[0].IPAddressToString
        $private = $ip -match "^(10\.|172\.(1[6-9]|2[0-9]|3[1-2])\.|192\.168\.|169\.254\.|fd)"
    }
    catch { $private = $false }

    if ($private) {
        if ($mbps -ge 700) { $rating = "Excellent LAN performance" }
        elseif ($mbps -ge 300) { $rating = "Good LAN performance" }
        else { $rating = "Possible LAN bottleneck" }
    }
    else {
        if ($mbps -ge 400) { $rating = "Excellent WAN performance" }
        elseif ($mbps -ge 100) { $rating = "Typical/good ISP speeds" }
        else { $rating = "Possible throttling or congestion" }
    }

    Write-Host "$rating`n" -ForegroundColor Magenta
}

# Create alias so you can just type 'net-test'
Set-Alias -Name net-test -Value Invoke-NetTest -Scope Global

Write-Host "net-test function loaded! Type 'net-test' to run." -ForegroundColor Green