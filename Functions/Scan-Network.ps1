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
        - IEEE OUI database for vendor lookup (no API calls needed)
        - Quick scan mode (skip port scanning)
        - Handles VPN point-to-point connections (/32 subnets)
    
    .PARAMETER Ports
        Array of ports to scan. Default: 22,80,443,3389,445,139
        Note: Ignored if -Preset is specified
    
    .PARAMETER Preset
        Use a predefined port list optimized for specific scenarios:
        - Quick: Fast scan of common services (10 ports)
        - Standard: Typical MSP scan including SQL (15 ports)
        - Dental: Dental practice focused with practice management software (20 ports)
        - Deep: Comprehensive scan including imaging and specialty services (25+ ports)
        - Web: Web services and APIs only
        - Database: All common database ports
    
    .PARAMETER ThrottleLimit
        Number of concurrent threads. Default: 30 (increased from 20)
    
    .PARAMETER QuickScan
        Skip port scanning for faster results (ping + MAC only)
    
    .PARAMETER NoCacheClear
        Skip ARP cache clearing (faster but may have stale data)
    
    .PARAMETER OUIFilePath
        Path to IEEE OUI database file. Default: oui.txt in script directory
    
    .EXAMPLE
        Scan-Network
        Scans the network with default settings
    
    .EXAMPLE
        Scan-Network -QuickScan
        Fast scan without port checking
    
    .EXAMPLE
        Scan-Network -Preset Dental
        Uses dental practice optimized port list
    
    .EXAMPLE
        Scan-Network -Preset Deep -ThrottleLimit 100
        Comprehensive scan with 100 concurrent threads
    
    .EXAMPLE
        Scan-Network -Ports @(80,443,8080) -ThrottleLimit 50
        Scans specific ports with 50 concurrent threads
    
    .EXAMPLE
        Scan-Network -OUIFilePath "C:\path\to\oui.txt"
        Uses a custom OUI database file
    #>
    
    [CmdletBinding()]
    param(
        [int[]]$Ports,
        
        [ValidateSet('Quick', 'Standard', 'Dental', 'Deep', 'Web', 'Database')]
        [string]$Preset,
        
        [int]$ThrottleLimit = 30,
        [switch]$QuickScan,
        [switch]$NoCacheClear,
        [string]$OUIFilePath = ""
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
            Write-Host "    🗑️  Clearing ARP cache..." -ForegroundColor DarkGray
            
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
    
    function Load-OUIDatabase {
        <#
        .SYNOPSIS
        Loads IEEE OUI database from file into memory
        #>
        param(
            [Parameter(Mandatory)]
            [string]$FilePath
        )
        
        $ouiHash = @{}
        $loadStart = Get-Date
        
        try {
            Write-Host "    📖 Loading OUI database from: $FilePath" -ForegroundColor DarkGray
            
            if (-not (Test-Path $FilePath)) {
                throw "OUI file not found: $FilePath"
            }
            
            $content = Get-Content $FilePath -ErrorAction Stop
            
            foreach ($line in $content) {
                # Look for lines with "(base 16)" which contain the vendor info
                if ($line -match '^([0-9A-F]{6})\s+\(base 16\)\s+(.+)$') {
                    $prefix = $matches[1]
                    $vendor = $matches[2].Trim()
                    $ouiHash[$prefix] = $vendor
                }
            }
            
            $loadTime = ((Get-Date) - $loadStart).TotalSeconds
            Write-Host "    ✓ Loaded $($ouiHash.Count) OUI entries in $([math]::Round($loadTime, 2))s" -ForegroundColor DarkGreen
            
            return $ouiHash
        } catch {
            Write-Warning "Failed to load OUI database: $_"
            return @{}
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
        Optimized IP range calculator using bitwise operations with better error handling
        #>
        param(
            [Parameter(Mandatory)]
            [string]$IP,
            
            [Parameter(Mandatory)]
            [int]$PrefixLength
        )
        
        # Check for /32 (VPN point-to-point connection)
        if ($PrefixLength -eq 32) {
            Write-Host "`n⚠️  VPN Point-to-Point Connection Detected" -ForegroundColor Yellow
            Write-Host ("═" * 70) -ForegroundColor Yellow
            Write-Host "`nThis interface has a /32 subnet mask, which means:" -ForegroundColor White
            Write-Host "  • It's a single host address (no network range)" -ForegroundColor DarkGray
            Write-Host "  • Typically used for VPN client endpoints" -ForegroundColor DarkGray
            Write-Host "  • There are no other local hosts to scan" -ForegroundColor DarkGray
            
            Write-Host "`n💡 Options:" -ForegroundColor Cyan
            Write-Host "  1. Scan a different network interface (if available)" -ForegroundColor White
            Write-Host "  2. If you want to scan the remote VPN network:" -ForegroundColor White
            Write-Host "     • You'll need the actual remote subnet (e.g., 10.0.0.0/24)" -ForegroundColor DarkGray
            Write-Host "     • Contact your network admin for the remote network range" -ForegroundColor DarkGray
            Write-Host "  3. Single host scan:" -ForegroundColor White
            Write-Host "     • Press 'S' to scan just this host ($IP)" -ForegroundColor DarkGray
            
            Write-Host "`nPress Enter to return to interface selection..." -ForegroundColor Gray
            $choice = Read-Host
            
            if ($choice -eq 'S' -or $choice -eq 's') {
                # Return single IP for scanning
                return @($IP)
            } else {
                throw "VPN_INTERFACE_SKIP"
            }
        }
        
        # Validate prefix length for network scanning
        if ($PrefixLength -lt 1 -or $PrefixLength -gt 30) {
            throw "Invalid prefix length: $PrefixLength (must be 1-30 for network scanning)"
        }
        
        # Parse IP to bytes
        try {
            $ipBytes = [System.Net.IPAddress]::Parse($IP).GetAddressBytes()
            [Array]::Reverse($ipBytes)
            $ipInt = [System.BitConverter]::ToUInt32($ipBytes, 0)
        } catch {
            throw "Invalid IP address: $IP"
        }
        
        # Calculate network range
        $hostBits = 32 - $PrefixLength
        $hostCount = [Math]::Pow(2, $hostBits) - 2
        
        # Warn for large ranges
        if ($hostCount -gt 1024) {
            Write-Warning "Large network detected ($hostCount hosts). This may take several minutes."
            $continue = Read-Host "Continue? (Y/N)"
            if ($continue -notmatch '^y(es)?$') {
                throw "Scan cancelled by user"
            }
        }
        
        # Calculate subnet mask - PowerShell 7.5.4 workaround for bit-shift casting issues
        # Convert to hex string first, then cast to uint32 (only method that works reliably)
        $hexMask = "0x{0:X8}" -f ((0xFFFFFFFF -shl $hostBits) -band 0xFFFFFFFF)
        $mask = [uint32]$hexMask
        
        # Calculate network address
        $hexNetwork = "0x{0:X8}" -f ($ipInt -band $mask)
        $networkInt = [uint32]$hexNetwork
        
        # Generate IP list efficiently
        $ips = [System.Collections.Generic.List[string]]::new([int]$hostCount)
        
        for ($i = 1; $i -le $hostCount; $i++) {
            try {
                # Use hex conversion to avoid uint32 overflow issues in PowerShell 7.5.4
                $hexHost = "0x{0:X8}" -f ($networkInt + $i)
                $hostInt = [uint32]$hexHost
                # Convert back to IP address
                $bytes = [System.BitConverter]::GetBytes($hostInt)
                [Array]::Reverse($bytes)
                
                # Create IP address string
                $ipAddr = [System.Net.IPAddress]::new($bytes)
                $ips.Add($ipAddr.ToString())
            } catch {
                Write-Warning "Skipped invalid IP at offset ${i}: $_"
                continue
            }
        }
        
        if ($ips.Count -eq 0) {
            throw "Failed to generate any valid IPs in range"
        }
        
        return $ips.ToArray()
    }
    
    function Get-MACVendor {
        <#
        .SYNOPSIS
        Looks up MAC address vendor from OUI database
        #>
        param(
            [string]$MAC,
            [hashtable]$OUIDatabase
        )
        
        if (-not $MAC -or $MAC.Length -lt 8) { return "" }
        if (-not $OUIDatabase -or $OUIDatabase.Count -eq 0) { return "" }
        
        # Normalize MAC address and get first 6 hex digits (OUI prefix)
        $cleanMAC = ($MAC -replace '[:-]', '').ToUpper()
        if ($cleanMAC.Length -lt 6) { return "" }
        
        $prefix = $cleanMAC.Substring(0, 6)
        
        # Look up in OUI database
        if ($OUIDatabase.ContainsKey($prefix)) {
            return $OUIDatabase[$prefix]
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
            [hashtable]$OUIDatabase
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
            $vendor = Get-MACVendor -MAC $mac -OUIDatabase $OUIDatabase
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
    
    Write-Host "`n🔍 Network Scanner" -ForegroundColor DarkCyan
    Write-Host ("═" * 70) -ForegroundColor DarkCyan
    
    # Apply port presets if specified (overrides -Ports parameter)
    if ($Preset) {
        switch ($Preset) {
            'Quick' {
                $Ports = @(22, 80, 443, 445, 1433, 3306, 3389, 8080)
                Write-Host "`n📋 Using 'Quick' preset (8 ports)" -ForegroundColor Cyan
            }
            'Standard' {
                $Ports = @(22, 80, 443, 445, 139, 1433, 1434, 3306, 3389, 5900, 8080, 9100, 50000)
                Write-Host "`n📋 Using 'Standard' preset (13 ports)" -ForegroundColor Cyan
            }
            'Dental' {
                $Ports = @(
                    # Remote Access & Management
                    22, 3389, 5900,
                    # Web Services
                    80, 443, 8080, 8443,
                    # File Sharing
                    445, 139,
                    # SQL Databases (Critical for dental software)
                    1433, 1434, 3306, 5432,
                    # Dental Practice Management Software
                    50000, 50001, 32767, 4000, 52734,
                    # Imaging/X-Ray Systems
                    104, 11112,
                    # Print Services
                    9100, 631
                )
                Write-Host "`n📋 Using 'Dental' preset (22 ports - optimized for dental practices)" -ForegroundColor Cyan
            }
            'Deep' {
                $Ports = @(
                    # Remote Access
                    22, 23, 3389, 5900, 5901,
                    # Web Services
                    80, 443, 8080, 8443, 8000, 8888,
                    # File Sharing
                    445, 139, 2049, 21, 20,
                    # Databases
                    1433, 1434, 3306, 5432, 27017, 6379, 1521,
                    # Dental Software
                    50000, 50001, 32767, 4000, 52734,
                    # Email
                    25, 587, 465, 110, 995, 143, 993,
                    # Imaging
                    104, 11112,
                    # Storage
                    3260, 2049,
                    # Print
                    9100, 631,
                    # Other
                    53, 88, 389, 636, 3128
                )
                Write-Host "`n📋 Using 'Deep' preset (45 ports - comprehensive scan)" -ForegroundColor Cyan
            }
            'Web' {
                $Ports = @(80, 443, 8080, 8443, 8000, 8888, 3000, 5000, 9000)
                Write-Host "`n📋 Using 'Web' preset (9 ports)" -ForegroundColor Cyan
            }
            'Database' {
                $Ports = @(1433, 1434, 3306, 5432, 27017, 6379, 1521, 5984, 9042, 7000, 7001)
                Write-Host "`n📋 Using 'Database' preset (11 ports)" -ForegroundColor Cyan
            }
        }
    } elseif (-not $Ports) {
        # Use default ports if none specified
        $Ports = @(22, 80, 443, 3389, 445, 139)
    }
    
    Write-Host "    Ports: $($Ports -join ', ')" -ForegroundColor DarkGray
    
    # Determine OUI file path
    if (-not $OUIFilePath) {
        # Try script directory first
        $scriptDir = Split-Path -Parent $PSCommandPath
        $defaultPaths = @(
            (Join-Path $scriptDir "oui.txt"),
            ".\oui.txt",
            (Join-Path $env:USERPROFILE "oui.txt")
        )
        
        foreach ($path in $defaultPaths) {
            if (Test-Path $path) {
                $OUIFilePath = $path
                break
            }
        }
        
        if (-not $OUIFilePath) {
            Write-Warning "OUI database file (oui.txt) not found. Vendor lookup will be disabled."
            Write-Host "    Download from: https://standards-oui.ieee.org/oui/oui.txt" -ForegroundColor DarkGray
        }
    }
    
    # Load OUI database
    $ouiDatabase = @{}
    if ($OUIFilePath -and (Test-Path $OUIFilePath)) {
        $ouiDatabase = Load-OUIDatabase -FilePath $OUIFilePath
    }
    
    # Step 1: Detect interfaces (with retry loop for VPN handling)
    :InterfaceSelection while ($true) {
        Write-Host "`n[1/4] Detecting active network interfaces..." -ForegroundColor Yellow
        
        try {
            $interfaces = Get-ActiveInterfaces
        } catch {
            Write-Host "❌ Error detecting interfaces: $_" -ForegroundColor Red
            return
        }
        
        if ($interfaces.Count -eq 0) {
            Write-Host "❌ No active interfaces found!" -ForegroundColor Red
            Write-Host "    Ensure you have an active network connection." -ForegroundColor DarkGray
            return
        }
        
        Write-Host "`nActive Interfaces:" -ForegroundColor Green
        $interfaces | ForEach-Object { 
            $vpnIndicator = if ($_.PrefixLength -eq 32) { " [VPN Point-to-Point]" } else { "" }
            Write-Host "  ✓ $($_.Name) - $($_.CIDR)$vpnIndicator ($($_.Description))" -ForegroundColor White
        }
        
        # Interface selection
        $selectedInterface = $interfaces[0]
        if ($interfaces.Count -gt 1) {
            Write-Host "`n⚠️  Multiple interfaces detected. Select one to scan:" -ForegroundColor Yellow
            
            for ($i = 0; $i -lt $interfaces.Count; $i++) {
                $vpnNote = if ($interfaces[$i].PrefixLength -eq 32) { " (VPN - /32)" } else { "" }
                Write-Host "  [$($i+1)] $($interfaces[$i].Name) - $($interfaces[$i].CIDR)$vpnNote"
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
            Write-Host "    ⏭️  Skipping ARP cache clear (using -NoCacheClear)" -ForegroundColor DarkGray
        }
        
        # Step 3: Calculate IP range (this will handle /32 detection)
        Write-Host "`n[3/4] Calculating host range..." -ForegroundColor Yellow
        
        try {
            $ips = Get-NetworkRange -IP $selectedInterface.IPAddress -PrefixLength $selectedInterface.PrefixLength
            
            # If we get here successfully, break out of the interface selection loop
            break InterfaceSelection
            
        } catch {
            if ($_.Exception.Message -eq "VPN_INTERFACE_SKIP") {
                # User chose to return to interface selection
                continue InterfaceSelection
            } else {
                Write-Host "❌ Error calculating range: $_" -ForegroundColor Red
                return
            }
        }
    }
    
    # Continue with scan...
    Write-Host "    Total hosts to scan: $($ips.Count)" -ForegroundColor DarkGray
    
    if ($QuickScan) {
        Write-Host "    ⚡ Quick scan mode (no port scanning)" -ForegroundColor DarkCyan
    } else {
        Write-Host "    Port scan: $($Ports -join ', ')" -ForegroundColor DarkGray
    }
    
    if ($ouiDatabase.Count -gt 0) {
        Write-Host "    📦 Vendor lookup: IEEE OUI database ($($ouiDatabase.Count) entries)" -ForegroundColor DarkGray
    } else {
        Write-Host "    📦 Vendor lookup: Disabled (no OUI database)" -ForegroundColor DarkGray
    }
    
    Write-Host "    🧵 Threads: $ThrottleLimit" -ForegroundColor DarkGray
    
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
        Get-HostInfo -IP $_ -PortList $using:Ports -SkipPorts:$using:QuickScan -OUIDatabase $using:ouiDatabase
        
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
    
    # ══════════════════════════════════════════════════════════════════════════
    # Display Results
    # ══════════════════════════════════════════════════════════════════════════
    
    Write-Host "`n" -NoNewline
    Write-Host ("═" * 70) -ForegroundColor Green
    Write-Host "✅ Scan complete!" -ForegroundColor Green
    Write-Host ("═" * 70) -ForegroundColor Green
    
    Write-Host "`n📊 Summary:" -ForegroundColor DarkCyan
    Write-Host "    • Network:       $($selectedInterface.CIDR)" -ForegroundColor White
    Write-Host "    • Hosts scanned: $($ips.Count)" -ForegroundColor White
    Write-Host "    • Hosts found:   $($results.Count)" -ForegroundColor Green
    Write-Host "    • Scan time:     $([math]::Round($scanDuration, 2))s" -ForegroundColor White
    Write-Host "    • Speed:         $([math]::Round($ips.Count / $scanDuration, 1)) hosts/sec" -ForegroundColor White
    
    if ($ouiDatabase.Count -gt 0) {
        Write-Host "    • OUI database:  $($ouiDatabase.Count) entries`n" -ForegroundColor White
    } else {
        Write-Host "    • OUI database:  Not loaded`n" -ForegroundColor White
    }
    
    if ($results.Count -eq 0) {
        Write-Host "❌ No active hosts found on this network" -ForegroundColor Red
        Write-Host "    Try:" -ForegroundColor DarkGray
        Write-Host "    • Check if you're connected to the right network" -ForegroundColor DarkGray
        Write-Host "    • Verify firewall settings" -ForegroundColor DarkGray
        Write-Host "    • Try a different interface`n" -ForegroundColor DarkGray
        return
    }
    
    # Display results table
    Write-Host "📋 Discovered Hosts:" -ForegroundColor DarkCyan
    $results | Format-Table -AutoSize
    
    # Save results globally
    $Global:LastScanResults = $results
    
    # Export helpers
    Write-Host "💾 Results saved to: `$Global:LastScanResults`n" -ForegroundColor DarkCyan
    
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
    Write-Host "🔎 Opening results in GridView (use Ctrl+C to copy selected rows)..." -ForegroundColor DarkCyan
    
    $results | Out-GridView -Title "Network Scan Results - $($selectedInterface.CIDR) | Found: $($results.Count) hosts | Scan time: $([math]::Round($scanDuration, 1))s"
}