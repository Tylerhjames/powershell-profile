function Scan-Network {
    <#
    .SYNOPSIS
        Fast network scanner with multi-threading, MAC/vendor/NetBIOS lookup, and port scanning.
    
    .DESCRIPTION
        Scans active network interfaces (skips loopback/Bluetooth/APIPA, keeps VPNs),
        performs multi-threaded ping + port scan, retrieves MAC addresses, vendor info,
        and NetBIOS names. Results open in GridView for easy CSV export.
        
        Features:
        - ARP cache clearing for accurate MAC discovery
        - Persistent vendor cache to avoid repeated API calls
        - Quick scan mode (skip port scanning)
        - Offline mode (local vendor DB only)
    
    .PARAMETER Ports
        Array of ports to scan. Default: 22,80,443,3389,445,139
    
    .PARAMETER ThrottleLimit
        Number of concurrent threads. Default: 30 (increased from 20)
    
    .PARAMETER QuickScan
        Skip port scanning for faster results (ping + MAC only)
    
    .PARAMETER NoVendorLookup
        Skip vendor API lookups (uses local database only)
    
    .PARAMETER NoCacheClear
        Skip ARP cache clearing (faster but may have stale data)
    
    .EXAMPLE
        Scan-Network
        Scans the network with default settings
    
    .EXAMPLE
        Scan-Network -QuickScan
        Fast scan without port checking
    
    .EXAMPLE
        Scan-Network -Ports @(80,443,8080) -ThrottleLimit 50
        Scans specific ports with 50 concurrent threads
    #>
    
    [CmdletBinding()]
    param(
        [int[]]$Ports = @(22, 80, 443, 3389, 445, 139),
        [int]$ThrottleLimit = 30,
        [switch]$QuickScan,
        [switch]$NoVendorLookup,
        [switch]$NoCacheClear
    )
    
    # ══════════════════════════════════════════════════════════════════════════
    # Helper Functions
    # ══════════════════════════════════════════════════════════════════════════
    
    function Clear-ARPCache {
        <#
        .SYNOPSIS
        Clears Windows ARP cache for fresh MAC address discovery
        #>
        
        try {
            Write-Host "    🗑️  Clearing ARP cache..." -ForegroundColor Gray
            
            # Windows command to clear ARP cache
            $result = netsh interface ip delete arpcache 2>&1
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "    ✓ ARP cache cleared" -ForegroundColor DarkGreen
                return $true
            } else {
                Write-Warning "Failed to clear ARP cache (may need admin rights)"
                return $false
            }
        } catch {
            Write-Warning "Error clearing ARP cache: $_"
            return $false
        }
    }
    
    function Get-VendorCache {
        <#
        .SYNOPSIS
        Loads persistent vendor cache from disk
        #>
        
        $cacheFile = Join-Path $env:TEMP "ps-network-scanner-vendor-cache.json"
        
        if (Test-Path $cacheFile) {
            try {
                $cache = Get-Content $cacheFile -Raw | ConvertFrom-Json -AsHashtable
                $cacheAge = (Get-Date) - (Get-Item $cacheFile).LastWriteTime
                
                Write-Host "    📦 Loaded vendor cache ($($cache.Count) entries, age: $([math]::Round($cacheAge.TotalDays, 1))d)" -ForegroundColor Gray
                
                return $cache
            } catch {
                Write-Warning "Failed to load vendor cache: $_"
                return @{}
            }
        }
        
        return @{}
    }
    
    function Save-VendorCache {
        <#
        .SYNOPSIS
        Saves vendor cache to disk
        #>
        param(
            [Parameter(Mandatory)]
            [hashtable]$Cache
        )
        
        $cacheFile = Join-Path $env:TEMP "ps-network-scanner-vendor-cache.json"
        
        try {
            $Cache | ConvertTo-Json | Set-Content $cacheFile -Force
            Write-Host "`n    💾 Vendor cache saved ($($Cache.Count) entries)" -ForegroundColor DarkGreen
        } catch {
            Write-Warning "Failed to save vendor cache: $_"
        }
    }
    
    function Get-ActiveInterfaces {
        <#
        .SYNOPSIS
        Gets active network interfaces, filtering out loopback/Bluetooth/APIPA
        #>
        
        $adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
        $results = @()
        
        foreach ($adapter in $adapters) {
            # Skip virtual/unwanted adapters early
            if ($adapter.InterfaceDescription -match 'Loopback|Bluetooth|Hyper-V|Virtual') {
                continue
            }
            
            $ip = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            
            # Filter APIPA and localhost
            if ($ip -and 
                $ip.IPAddress -notmatch '^169\.254\.' -and 
                $ip.IPAddress -ne '127.0.0.1') {
                
                $results += [PSCustomObject]@{
                    Name         = $adapter.Name
                    Description  = $adapter.InterfaceDescription
                    IPAddress    = $ip.IPAddress
                    PrefixLength = $ip.PrefixLength
                    CIDR         = "$($ip.IPAddress)/$($ip.PrefixLength)"
                }
            }
        }
        
        return $results
    }
    
    function Get-NetworkRange {
        <#
        .SYNOPSIS
        Calculates all host IPs in a CIDR range
        .DESCRIPTION
        Optimized IP range calculator using bitwise operations
        #>
        param(
            [Parameter(Mandatory)]
            [string]$IP,
            
            [Parameter(Mandatory)]
            [int]$PrefixLength
        )
        
        # Parse IP to bytes
        $ipBytes = [System.Net.IPAddress]::Parse($IP).GetAddressBytes()
        [Array]::Reverse($ipBytes)
        $ipInt = [System.BitConverter]::ToUInt32($ipBytes, 0)
        
        # Calculate network range
        $mask = [uint32]([Math]::Pow(2, 32) - [Math]::Pow(2, 32 - $PrefixLength))
        $networkInt = $ipInt -band $mask
        $hostBits = 32 - $PrefixLength
        $hostCount = [Math]::Pow(2, $hostBits) - 2
        
        # Optimize for large ranges (warn if > 1024 hosts)
        if ($hostCount -gt 1024) {
            Write-Warning "Large network detected ($hostCount hosts). This may take several minutes."
            $continue = Read-Host "Continue? (Y/N)"
            if ($continue -notmatch '^y(es)?$') {
                throw "Scan cancelled by user"
            }
        }
        
        # Generate IP list efficiently
        $ips = [System.Collections.Generic.List[string]]::new([int]$hostCount)
        
        for ($i = 1; $i -le $hostCount; $i++) {
            $hostInt = $networkInt + $i
            $bytes = [System.BitConverter]::GetBytes($hostInt)
            [Array]::Reverse($bytes)
            $ips.Add([System.Net.IPAddress]::new($bytes).ToString())
        }
        
        return $ips.ToArray()
    }
    
    function Get-MACVendor {
        <#
        .SYNOPSIS
        Looks up MAC address vendor (cache -> local DB -> API)
        #>
        param(
            [string]$MAC,
            [switch]$LocalOnly,
            [hashtable]$Cache
        )
        
        if (-not $MAC -or $MAC.Length -lt 8) { return "" }
        
        # Normalize MAC address
        $cleanMAC = ($MAC -replace '[:-]', '').ToUpper()
        if ($cleanMAC.Length -lt 6) { return "" }
        
        # Check cache first
        if ($Cache -and $Cache.ContainsKey($cleanMAC)) {
            return $Cache[$cleanMAC]
        }
        
        # Extended local database (faster, no rate limits)
        $prefix = $cleanMAC.Substring(0, 6)
        $vendors = @{
            # Major manufacturers
            '000000' = 'Xerox'
            '00005E' = 'IANA'
            '0050F2' = 'Microsoft'
            '001B63' = 'Apple'
            '7CC3A1' = 'Apple'
            '001CF0' = 'Apple'
            'F01898' = 'Apple'
            'B8F6B1' = 'Apple'
            '3C0754' = 'Apple'
            'A4C361' = 'Apple'
            '00155D' = 'Microsoft'
            '001DD8' = 'Microsoft'
            '000D3A' = 'Microsoft'
            '000C29' = 'VMware'
            '005056' = 'VMware'
            '080027' = 'VirtualBox'
            '0A0027' = 'VirtualBox'
            '001C42' = 'Parallels'
            '00E04C' = 'Realtek'
            '0090FE' = 'Kingston'
            '525400' = 'QEMU/KVM'
            
            # IoT/Embedded
            'A036BC' = 'Espressif (ESP32)'
            '245EBE' = 'Espressif (ESP32)'
            'E09E26' = 'Espressif (ESP8266)'
            'FCEE28' = 'Espressif (ESP8266)'
            '0CEA14' = 'Espressif (ESP8266)'
            'CCEE28' = 'Espressif (ESP32)'
            'B232E8' = 'Espressif (ESP32)'
            'C44F33' = 'Espressif (ESP32)'
            
            # Networking equipment
            '7C1175' = 'D-Link'
            '249E7D' = 'TP-Link'
            '54AF97' = 'TP-Link'
            'C006C3' = 'TP-Link'
            'B0BE76' = 'TP-Link'
            '001E58' = 'Netgear'
            '00146C' = 'Netgear'
            '2C3033' = 'Netgear'
            '44A56E' = 'Netgear'
            'E0469A' = 'Netgear'
            '9CDA3E' = 'Asus'
            '2C56DC' = 'Asus'
            '001EA6' = 'Cisco-Linksys'
            '68EF43' = 'Cisco-Linksys'
            'C0FFD4' = 'Ubiquiti'
            '247F20' = 'Ubiquiti'
            
            # Mobile/Tablets
            '283737' = 'Samsung'
            '3C5A37' = 'Samsung'
            '7C6193' = 'Samsung'
            'E4121D' = 'Samsung'
            '54E43A' = 'Google'
            'DC2C26' = 'Google'
            'F4F5E8' = 'Google'
            'C46516' = 'Amazon'
            'F0D2F1' = 'Amazon'
            '78E103' = 'Amazon'
        }
        
        # Check local database
        if ($vendors.ContainsKey($prefix)) {
            $vendor = $vendors[$prefix]
            # Add to cache
            if ($Cache) {
                $Cache[$cleanMAC] = $vendor
            }
            return $vendor
        }
        
        # Skip API if requested
        if ($LocalOnly) { return "" }
        
        # API lookup with error handling and timeout
        try {
            $apiUrl = "https://api.maclookup.app/v2/macs/$cleanMAC"
            $response = Invoke-RestMethod -Uri $apiUrl -Method Get -TimeoutSec 2 -ErrorAction Stop
            
            if ($response.company) {
                # Add to cache
                if ($Cache) {
                    $Cache[$cleanMAC] = $response.company
                }
                return $response.company
            }
        } catch {
            # Silently fail back to empty string
            # API failures are common (rate limits, network issues)
        }
        
        return ""
    }
    
    function Test-PortScan {
        <#
        .SYNOPSIS
        Fast TCP port scanner using async connections
        #>
        param(
            [Parameter(Mandatory)]
            [string]$IP,
            
            [Parameter(Mandatory)]
            [int[]]$PortList
        )
        
        $openPorts = [System.Collections.Generic.List[int]]::new()
        
        foreach ($port in $PortList) {
            $client = $null
            try {
                $client = New-Object System.Net.Sockets.TcpClient
                $connect = $client.BeginConnect($IP, $port, $null, $null)
                $wait = $connect.AsyncWaitHandle.WaitOne(100, $false)
                
                if ($wait -and $client.Connected) {
                    $openPorts.Add($port)
                }
            } catch {
                # Port closed or filtered
            } finally {
                if ($client) {
                    $client.Close()
                    $client.Dispose()
                }
            }
        }
        
        return ($openPorts.ToArray() -join ',')
    }
    
    function Get-HostInfo {
        <#
        .SYNOPSIS
        Gathers comprehensive host information
        #>
        param(
            [Parameter(Mandatory)]
            [string]$IP,
            
            [int[]]$PortList,
            [switch]$SkipPorts,
            [switch]$NoVendorAPI,
            [hashtable]$VendorCache
        )
        
        # Quick ping test
        $ping = Test-Connection -ComputerName $IP -Count 1 -Quiet -TimeoutSeconds 1
        if (-not $ping) { return $null }
        
        # Get MAC from ARP table (Windows native)
        $mac = ""
        try {
            $arpOutput = arp -a $IP 2>$null
            if ($arpOutput) {
                $macMatch = [regex]::Match($arpOutput, '([0-9a-fA-F]{2}[:-]){5}([0-9a-fA-F]{2})')
                if ($macMatch.Success) {
                    $mac = $macMatch.Value.ToUpper()
                }
            }
        } catch {
            # ARP lookup failed
        }
        
        # Resolve hostname (try DNS first, fallback to NetBIOS)
        $hostname = ""
        try {
            $dnsResult = [System.Net.Dns]::GetHostEntry($IP)
            $hostname = $dnsResult.HostName
        } catch {
            # Fallback to NetBIOS (slower but works for Windows hosts without DNS)
            try {
                $nbt = nbtstat -A $IP 2>$null | Select-String '<00>  UNIQUE'
                if ($nbt -and $nbt.Count -gt 0) {
                    $hostname = ($nbt[0].ToString() -split '\s+')[0].Trim()
                }
            } catch {
                # Both methods failed
            }
        }
        
        # Port scan (optional)
        $portResults = ""
        if (-not $SkipPorts -and $PortList) {
            $portResults = Test-PortScan -IP $IP -PortList $PortList
        }
        
        # Vendor lookup
        $vendor = ""
        if ($mac) {
            $vendor = Get-MACVendor -MAC $mac -LocalOnly:$NoVendorAPI -Cache $VendorCache
        }
        
        return [PSCustomObject]@{
            IPAddress = $IP
            Status    = 'Online'
            Hostname  = $hostname
            MAC       = $mac
            Vendor    = $vendor
            OpenPorts = $portResults
        }
    }
    
    # ══════════════════════════════════════════════════════════════════════════
    # Main Execution
    # ══════════════════════════════════════════════════════════════════════════
    
    Write-Host "`n🔍 Network Scanner" -ForegroundColor Cyan
    Write-Host ("═" * 70) -ForegroundColor Cyan
    
    # Load vendor cache
    $vendorCache = Get-VendorCache
    
    # Step 1: Detect interfaces
    Write-Host "`n[1/4] Detecting active network interfaces..." -ForegroundColor Yellow
    
    try {
        $interfaces = Get-ActiveInterfaces
    } catch {
        Write-Host "❌ Error detecting interfaces: $_" -ForegroundColor Red
        return
    }
    
    if ($interfaces.Count -eq 0) {
        Write-Host "❌ No active interfaces found!" -ForegroundColor Red
        Write-Host "    Ensure you have an active network connection." -ForegroundColor Gray
        return
    }
    
    Write-Host "`nActive Interfaces:" -ForegroundColor Green
    $interfaces | ForEach-Object { 
        Write-Host "  ✓ $($_.Name) - $($_.CIDR) ($($_.Description))" -ForegroundColor White
    }
    
    # Interface selection
    $selectedInterface = $interfaces[0]
    if ($interfaces.Count -gt 1) {
        Write-Host "`n❓ Multiple interfaces detected. Select one to scan:" -ForegroundColor Yellow
        
        for ($i = 0; $i -lt $interfaces.Count; $i++) {
            Write-Host "  [$($i+1)] $($interfaces[$i].Name) - $($interfaces[$i].CIDR)"
        }
        
        $selection = Read-Host "Enter number (default: 1)"
        
        if ($selection -match '^\d+$') {
            $idx = [int]$selection - 1
            if ($idx -ge 0 -and $idx -lt $interfaces.Count) {
                $selectedInterface = $interfaces[$idx]
            }
        }
    }
    
    Write-Host "`n✓ Selected: $($selectedInterface.Name) - $($selectedInterface.CIDR)" -ForegroundColor Green
    
    # Step 2: Clear ARP cache
    Write-Host "`n[2/4] Preparing ARP cache..." -ForegroundColor Yellow
    
    if (-not $NoCacheClear) {
        Clear-ARPCache | Out-Null
    } else {
        Write-Host "    ⏭️  Skipping ARP cache clear (using -NoCacheClear)" -ForegroundColor Gray
    }
    
    # Step 3: Calculate IP range
    Write-Host "`n[3/4] Calculating host range..." -ForegroundColor Yellow
    
    try {
        $ips = Get-NetworkRange -IP $selectedInterface.IPAddress -PrefixLength $selectedInterface.PrefixLength
    } catch {
        Write-Host "❌ Error calculating range: $_" -ForegroundColor Red
        return
    }
    
    Write-Host "    Total hosts to scan: $($ips.Count)" -ForegroundColor Gray
    
    if ($QuickScan) {
        Write-Host "    ⚡ Quick scan mode (no port scanning)" -ForegroundColor Cyan
    } else {
        Write-Host "    Port scan: $($Ports -join ', ')" -ForegroundColor Gray
    }
    
    if ($NoVendorLookup) {
        Write-Host "    📦 Vendor lookup: Local database only" -ForegroundColor Gray
    } else {
        Write-Host "    🌐 Vendor lookup: API + local database + cache" -ForegroundColor Gray
    }
    
    Write-Host "    🧵 Threads: $ThrottleLimit" -ForegroundColor Gray
    
    # Step 4: Scan network
    Write-Host "`n[4/4] Scanning network..." -ForegroundColor Yellow
    
    $scanStart = Get-Date
    
    # Convert functions to script blocks for parallel execution
    $portScanScript = ${function:Test-PortScan}.ToString()
    $macVendorScript = ${function:Get-MACVendor}.ToString()
    $hostInfoScript = ${function:Get-HostInfo}.ToString()
    
    # Progress tracking
    $completed = 0
    $progressParams = @{
        Activity = "Scanning $($selectedInterface.CIDR)"
        Status   = "0 / $($ips.Count) hosts scanned"
    }
    
    Write-Progress @progressParams -PercentComplete 0
    
    # Parallel scan with progress updates
    $results = $ips | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        # Recreate functions in parallel scope
        $portScanDef = $using:portScanScript
        $macVendorDef = $using:macVendorScript
        $hostInfoDef = $using:hostInfoScript
        
        Invoke-Expression "function Test-PortScan { $portScanDef }"
        Invoke-Expression "function Get-MACVendor { $macVendorDef }"
        Invoke-Expression "function Get-HostInfo { $hostInfoDef }"
        
        # Execute scan
        Get-HostInfo -IP $_ -PortList $using:Ports -SkipPorts:$using:QuickScan -NoVendorAPI:$using:NoVendorLookup -VendorCache $using:vendorCache
        
        # Update progress (approximate, not exact due to parallelism)
        $script:completed++
        if ($script:completed % 10 -eq 0) {
            $pct = [math]::Min(100, [int](($script:completed / $using:ips.Count) * 100))
            Write-Progress -Activity "Scanning $($using:selectedInterface.CIDR)" `
                           -Status "$script:completed / $($using:ips.Count) hosts scanned" `
                           -PercentComplete $pct
        }
    } | Where-Object { $_ -ne $null }
    
    Write-Progress -Activity "Scanning" -Completed
    
    $scanDuration = ((Get-Date) - $scanStart).TotalSeconds
    
    # Save vendor cache
    Save-VendorCache -Cache $vendorCache
    
    # ══════════════════════════════════════════════════════════════════════════
    # Display Results
    # ══════════════════════════════════════════════════════════════════════════
    
    Write-Host "`n" + ("═" * 70) -ForegroundColor Green
    Write-Host "✅ Scan complete!" -ForegroundColor Green
    Write-Host ("═" * 70) -ForegroundColor Green
    
    Write-Host "`n📊 Summary:" -ForegroundColor Cyan
    Write-Host "    • Network:       $($selectedInterface.CIDR)" -ForegroundColor White
    Write-Host "    • Hosts scanned: $($ips.Count)" -ForegroundColor White
    Write-Host "    • Hosts found:   $($results.Count)" -ForegroundColor Green
    Write-Host "    • Scan time:     $([math]::Round($scanDuration, 2))s" -ForegroundColor White
    Write-Host "    • Speed:         $([math]::Round($ips.Count / $scanDuration, 1)) hosts/sec" -ForegroundColor White
    Write-Host "    • Vendor cache:  $($vendorCache.Count) entries`n" -ForegroundColor White
    
    if ($results.Count -eq 0) {
        Write-Host "❌ No active hosts found on this network" -ForegroundColor Red
        Write-Host "    Try:" -ForegroundColor Gray
        Write-Host "    • Check if you're connected to the right network" -ForegroundColor Gray
        Write-Host "    • Verify firewall settings" -ForegroundColor Gray
        Write-Host "    • Try a different interface`n" -ForegroundColor Gray
        return
    }
    
    # Display results table
    Write-Host "📋 Discovered Hosts:" -ForegroundColor Cyan
    $results | Format-Table -AutoSize
    
    # Save results globally
    $Global:LastScanResults = $results
    
    # Export helpers
    Write-Host "💾 Results saved to: `$Global:LastScanResults`n" -ForegroundColor Cyan
    
    Write-Host "📤 Quick Export Commands:" -ForegroundColor Yellow
    Write-Host "    • CSV:       `$Global:LastScanResults | Export-Csv 'network-scan.csv' -NoTypeInformation" -ForegroundColor White
    Write-Host "    • JSON:      `$Global:LastScanResults | ConvertTo-Json | Out-File 'network-scan.json'" -ForegroundColor White
    Write-Host "    • IPs only:  `$Global:LastScanResults.IPAddress | Set-Clipboard" -ForegroundColor White
    Write-Host "    • MACs only: `$Global:LastScanResults.MAC | Set-Clipboard`n" -ForegroundColor White
    
    # Quick copy helpers
    $Global:CopyIPs = { 
        $Global:LastScanResults.IPAddress | Set-Clipboard
        Write-Host "✓ $($Global:LastScanResults.Count) IPs copied to clipboard!" -ForegroundColor Green 
    }
    
    $Global:CopyMACs = { 
        $macs = $Global:LastScanResults.MAC | Where-Object { $_ }
        $macs | Set-Clipboard
        Write-Host "✓ $($macs.Count) MAC addresses copied to clipboard!" -ForegroundColor Green 
    }
    
    Write-Host "⚡ Quick Copy (run these commands):" -ForegroundColor Yellow
    Write-Host "    • & `$Global:CopyIPs    - Copy all IPs to clipboard" -ForegroundColor White
    Write-Host "    • & `$Global:CopyMACs   - Copy all MAC addresses to clipboard`n" -ForegroundColor White
    
    # Open in GridView for easy filtering/export
    Write-Host "🔍 Opening results in GridView (use Ctrl+C to copy selected rows)..." -ForegroundColor Cyan
    
    $results | Out-GridView -Title "Network Scan Results - $($selectedInterface.CIDR) | Found: $($results.Count) hosts | Scan time: $([math]::Round($scanDuration, 1))s"
}