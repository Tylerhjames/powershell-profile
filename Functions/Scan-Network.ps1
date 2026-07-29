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
            Write-Color "    🗑️  Clearing ARP cache..." 'Detail'
            
            # Windows command to clear ARP cache
            $result = netsh interface ip delete arpcache 2>&1
            
            if ($LASTEXITCODE -eq 0) {
                Write-Color "    $global:CbitCheck ARP cache cleared" 'Good'
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
            Write-Color "    📖 Loading OUI database from: $FilePath" 'Detail'
            
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
            Write-Color "    $global:CbitCheck Loaded $($ouiHash.Count) OUI entries in $([math]::Round($loadTime, 2))s" 'Good'
            
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
            Write-Color "`n$global:CbitWarnGlyph  VPN Point-to-Point Connection Detected" 'Warn'
            Write-Color ("═" * 70) 'Detail'
            Write-Color "`nThis interface has a /32 subnet mask, which means:"
            Write-Color "  • It's a single host address (no network range)" 'Detail'
            Write-Color "  • Typically used for VPN client endpoints" 'Detail'
            Write-Color "  • There are no other local hosts to scan" 'Detail'

            Write-Color "`n💡 Options:" 'Header'
            Write-Color "  1. Scan a different network interface (if available)"
            Write-Color "  2. If you want to scan the remote VPN network:"
            Write-Color "     • You'll need the actual remote subnet (e.g., 10.0.0.0/24)" 'Detail'
            Write-Color "     • Contact your network admin for the remote network range" 'Detail'
            Write-Color "  3. Single host scan:"
            Write-Color "     • Press 'S' to scan just this host ($IP)" 'Detail'

            Write-Color "`nPress Enter to return to interface selection..." 'Detail'
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
    
    function Get-HostUrl {
        <#
        .SYNOPSIS
        Builds a web-UI URL for a host, choosing http/https from its open ports.
        .DESCRIPTION
        Reuses the OpenPorts comma-string already collected by Get-HostInfo.
        Prefers https when 443/8443 are open, else http when 80/8080 are open.
        Falls back to http:// when no port data exists (e.g. -QuickScan).
        #>
        param([Parameter(Mandatory)]$HostObj)

        $ports = @()
        if ($HostObj.OpenPorts) { $ports = ($HostObj.OpenPorts -split ',').Trim() }

        if     ($ports -contains '443' -or $ports -contains '8443') { return "https://$($HostObj.IPAddress)" }
        elseif ($ports -contains '80'  -or $ports -contains '8080') { return "http://$($HostObj.IPAddress)" }
        else   { return "http://$($HostObj.IPAddress)" }
    }

    # ══════════════════════════════════════════════════════════════════════════
    # Main Execution
    # ══════════════════════════════════════════════════════════════════════════

    Write-Color "`n🔍 Network Scanner" 'Header'
    Write-Color ("═" * 70) 'Detail'
    
    # Apply port presets if specified (overrides -Ports parameter)
    if ($Preset) {
        switch ($Preset) {
            'Quick' {
                $Ports = @(22, 80, 443, 445, 1433, 3306, 3389, 8080)
                Write-Color "`n📋 Using 'Quick' preset (8 ports)" 'Detail'
            }
            'Standard' {
                $Ports = @(22, 80, 443, 445, 139, 1433, 1434, 3306, 3389, 5900, 8080, 9100, 50000)
                Write-Color "`n📋 Using 'Standard' preset (13 ports)" 'Detail'
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
                Write-Color "`n📋 Using 'Dental' preset (22 ports - optimized for dental practices)" 'Detail'
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
                Write-Color "`n📋 Using 'Deep' preset (45 ports - comprehensive scan)" 'Detail'
            }
            'Web' {
                $Ports = @(80, 443, 8080, 8443, 8000, 8888, 3000, 5000, 9000)
                Write-Color "`n📋 Using 'Web' preset (9 ports)" 'Detail'
            }
            'Database' {
                $Ports = @(1433, 1434, 3306, 5432, 27017, 6379, 1521, 5984, 9042, 7000, 7001)
                Write-Color "`n📋 Using 'Database' preset (11 ports)" 'Detail'
            }
        }
    } elseif (-not $Ports) {
        # Use default ports if none specified
        $Ports = @(22, 80, 443, 3389, 445, 139)
    }
    
    Write-Color "    Ports: $($Ports -join ', ')" 'Detail'
    
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
            Write-Color "    Download from: https://standards-oui.ieee.org/oui/oui.txt" 'Detail'
        }
    }
    
    # Load OUI database
    $ouiDatabase = @{}
    if ($OUIFilePath -and (Test-Path $OUIFilePath)) {
        $ouiDatabase = Load-OUIDatabase -FilePath $OUIFilePath
    }
    
    # Step 1: Detect interfaces (with retry loop for VPN handling)
    :InterfaceSelection while ($true) {
        Write-Color "`n[1/4] Detecting active network interfaces..." 'Header'

        try {
            $interfaces = Get-ActiveInterfaces
        } catch {
            Write-Color "$global:CbitCross Error detecting interfaces: $_" 'Bad'
            return
        }

        if ($interfaces.Count -eq 0) {
            Write-Color "$global:CbitCross No active interfaces found!" 'Bad'
            Write-Color "    Ensure you have an active network connection." 'Detail'
            return
        }

        Write-Color "`nActive Interfaces:" 'Header'
        $interfaces | ForEach-Object {
            $vpnIndicator = if ($_.PrefixLength -eq 32) { " [VPN Point-to-Point]" } else { "" }
            Write-Color "  $global:CbitCheck $($_.Name) - $($_.CIDR)$vpnIndicator ($($_.Description))"
        }

        # Interface selection
        $selectedInterface = $interfaces[0]
        if ($interfaces.Count -gt 1) {
            Write-Color "`n$global:CbitWarnGlyph  Multiple interfaces detected. Select one to scan:" 'Warn'
            
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
        
        Write-Color "`n$global:CbitCheck Selected: $($selectedInterface.Name) - $($selectedInterface.CIDR)" 'Good'

        # Step 2: Clear ARP cache
        Write-Color "`n[2/4] Preparing ARP cache..." 'Header'

        if (-not $NoCacheClear) {
            Clear-ARPCache | Out-Null
        } else {
            Write-Color "    ⏭️  Skipping ARP cache clear (using -NoCacheClear)" 'Detail'
        }

        # Step 3: Calculate IP range (this will handle /32 detection)
        Write-Color "`n[3/4] Calculating host range..." 'Header'
        
        try {
            $ips = Get-NetworkRange -IP $selectedInterface.IPAddress -PrefixLength $selectedInterface.PrefixLength
            
            # If we get here successfully, break out of the interface selection loop
            break InterfaceSelection
            
        } catch {
            if ($_.Exception.Message -eq "VPN_INTERFACE_SKIP") {
                # User chose to return to interface selection
                continue InterfaceSelection
            } else {
                Write-Color "$global:CbitCross Error calculating range: $_" 'Bad'
                return
            }
        }
    }
    
    # Continue with scan...
    Write-Color "    Total hosts to scan: $($ips.Count)" 'Detail'

    if ($QuickScan) {
        Write-Color "    ⚡ Quick scan mode (no port scanning)" 'Detail'
    } else {
        Write-Color "    Port scan: $($Ports -join ', ')" 'Detail'
    }

    if ($ouiDatabase.Count -gt 0) {
        Write-Color "    📦 Vendor lookup: IEEE OUI database ($($ouiDatabase.Count) entries)" 'Detail'
    } else {
        Write-Color "    📦 Vendor lookup: Disabled (no OUI database)" 'Detail'
    }

    Write-Color "    🧵 Threads: $ThrottleLimit" 'Detail'

    # Step 4: Scan network
    Write-Color "`n[4/4] Scanning network..." 'Header'
    
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
    Write-Color ("═" * 70) 'Detail'
    Write-Color "$global:CbitCheck Scan complete!" 'Good'
    Write-Color ("═" * 70) 'Detail'

    Write-Color "`n📊 Summary:" 'Header'
    Write-Color "    • Network:       $($selectedInterface.CIDR)"
    Write-Color "    • Hosts scanned: $($ips.Count)"
    Write-Color "    • Hosts found:   $($results.Count)" 'Good'
    Write-Color "    • Scan time:     $([math]::Round($scanDuration, 2))s"
    Write-Color "    • Speed:         $([math]::Round($ips.Count / $scanDuration, 1)) hosts/sec"

    if ($ouiDatabase.Count -gt 0) {
        Write-Color "    • OUI database:  $($ouiDatabase.Count) entries`n"
    } else {
        Write-Color "    • OUI database:  Not loaded`n"
    }

    if ($results.Count -eq 0) {
        Write-Color "$global:CbitCross No active hosts found on this network" 'Bad'
        Write-Color "    Try:" 'Detail'
        Write-Color "    • Check if you're connected to the right network" 'Detail'
        Write-Color "    • Verify firewall settings" 'Detail'
        Write-Color "    • Try a different interface`n" 'Detail'
        return
    }

    # Display results table
    Write-Color "📋 Discovered Hosts:" 'Header'
    $results | Format-Table -AutoSize
    
    # Save results globally
    $Global:LastScanResults = $results
    
    # Export helpers
    Write-Color "💾 Results saved to: `$Global:LastScanResults`n" 'Detail'

    Write-Color "📤 Quick Export Commands:" 'Header'
    Write-Color "    • CSV:       `$Global:LastScanResults | Export-Csv 'network-scan.csv' -NoTypeInformation" 'Header'
    Write-Color "    • JSON:      `$Global:LastScanResults | ConvertTo-Json | Out-File 'network-scan.json'" 'Header'
    Write-Color "    • IPs only:  `$Global:LastScanResults.IPAddress | Set-Clipboard" 'Header'
    Write-Color "    • MACs only: `$Global:LastScanResults.MAC | Set-Clipboard`n" 'Header'
    
    # Quick copy helpers
    $Global:CopyIPs = { 
        $Global:LastScanResults.IPAddress | Set-Clipboard
        Write-Color "$global:CbitCheck $($Global:LastScanResults.Count) IPs copied to clipboard!" 'Good'
    }
    
    $Global:CopyMACs = { 
        $macs = $Global:LastScanResults.MAC | Where-Object { $_ }
        $macs | Set-Clipboard
        Write-Color "$global:CbitCheck $($macs.Count) MAC addresses copied to clipboard!" 'Good'
    }
    
    Write-Color "⚡ Quick Copy (run these commands):" 'Header'
    Write-Color "    • & `$Global:CopyIPs    - Copy all IPs to clipboard" 'Header'
    Write-Color "    • & `$Global:CopyMACs   - Copy all MAC addresses to clipboard`n" 'Header'
    
    # Open in GridView, then offer copy/open actions on the selected row(s).
    # Out-GridView is read-only (no double-click/per-cell copy), so -PassThru returns
    # the selected rows on OK and we act on them from the console. Closing the window
    # (Cancel/X) returns nothing and exits the loop.
    Write-Color "🔎 Opening results in GridView (filter, select row(s) + OK for copy/open actions; Ctrl+C copies whole rows)..." 'Detail'

    while ($true) {
        $selected = $results | Out-GridView -PassThru -Title "Network Scan Results - $($selectedInterface.CIDR) | Found: $($results.Count) hosts | Select row(s) + OK for actions"
        if (-not $selected) { break }   # window closed / cancelled

        Write-Color "`nSelected $($selected.Count) host(s):" 'Header'
        $selected | ForEach-Object { Write-Color "    • $($_.IPAddress)  $($_.Hostname)  $($_.MAC)" }

        Write-Color "`nActions:" 'Header'
        Write-Color "  [1] Copy MAC(s) to clipboard"
        Write-Color "  [2] Copy IP(s) to clipboard"
        Write-Color "  [3] Open web interface(s) in browser"
        Write-Color "  [B] Back to grid    [Q] Done" 'Detail'
        $action = Read-Host "Choose"

        switch -Regex ($action) {
            '^1$' {
                $macs = $selected.MAC | Where-Object { $_ }
                if ($macs) {
                    $macs | Set-Clipboard
                    Write-Color "$global:CbitCheck Copied $($macs.Count) MAC(s) to clipboard" 'Good'
                } else {
                    Write-Color "$global:CbitWarnGlyph No MAC addresses on the selected host(s)" 'Warn'
                }
            }
            '^2$' {
                $ipList = $selected.IPAddress | Where-Object { $_ }
                $ipList | Set-Clipboard
                Write-Color "$global:CbitCheck Copied $($ipList.Count) IP(s) to clipboard" 'Good'
            }
            '^3$' {
                if ($selected.Count -gt 5) {
                    $ok = Read-Host "This opens $($selected.Count) browser tabs. Continue? (Y/N)"
                    if ($ok -notmatch '^y') { continue }
                }
                foreach ($h in $selected) {
                    $url = Get-HostUrl -HostObj $h
                    Write-Color "🌐 Opening $url"
                    Start-Process $url
                }
            }
            '^[Bb]$' { continue }
            '^[Qq]$' { break }
            default  { Write-Color "Invalid choice." 'Bad' }
        }
    }
}