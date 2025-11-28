function Scan-Network {
    <#
    .SYNOPSIS
        Fast network scanner with multi-threading, MAC/vendor/NetBIOS lookup, and port scanning.
    
    .DESCRIPTION
        Scans active network interfaces (skips loopback/Bluetooth/APIPA, keeps VPNs),
        performs multi-threaded ping + port scan, retrieves MAC addresses, vendor info,
        and NetBIOS names. Results open in GridView for easy CSV export.
    
    .PARAMETER Ports
        Array of ports to scan. Default: 22,80,443,3389,445,139
    
    .PARAMETER ThrottleLimit
        Number of concurrent threads. Default: 20
    
    .EXAMPLE
        Scan-Network
        Scans the network with default settings
    
    .EXAMPLE
        Scan-Network -Ports @(80,443,8080) -ThrottleLimit 30
        Scans specific ports with 30 concurrent threads
    #>
    
    [CmdletBinding()]
    param(
        [int[]]$Ports = @(22,80,443,3389,445,139),
        [int]$ThrottleLimit = 20
    )
    
    function Get-ActiveInterfaces {
        $adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
        $results = @()
        
        foreach ($adapter in $adapters) {
            $ip = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            
            if ($ip -and $ip.IPAddress -notmatch '^169\.254\.' -and $ip.IPAddress -ne '127.0.0.1') {
                if ($adapter.InterfaceDescription -notmatch 'Loopback|Bluetooth') {
                    $results += [PSCustomObject]@{
                        Name = $adapter.Name
                        Description = $adapter.InterfaceDescription
                        IPAddress = $ip.IPAddress
                        PrefixLength = $ip.PrefixLength
                        CIDR = "$($ip.IPAddress)/$($ip.PrefixLength)"
                    }
                }
            }
        }
        return $results
    }
    
    function Get-NetworkRange {
        param([string]$IP, [int]$PrefixLength)
        
        $ipBytes = [System.Net.IPAddress]::Parse($IP).GetAddressBytes()
        [Array]::Reverse($ipBytes)
        $ipInt = [System.BitConverter]::ToUInt32($ipBytes, 0)
        
        $mask = [uint32]([Math]::Pow(2, 32) - [Math]::Pow(2, 32 - $PrefixLength))
        $networkInt = $ipInt -band $mask
        $hostBits = 32 - $PrefixLength
        $hostCount = [Math]::Pow(2, $hostBits) - 2
        
        $ips = @()
        for ($i = 1; $i -le $hostCount; $i++) {
            $hostInt = $networkInt + $i
            $bytes = [System.BitConverter]::GetBytes($hostInt)
            [Array]::Reverse($bytes)
            $ips += [System.Net.IPAddress]::new($bytes).ToString()
        }
        return $ips
    }
    
    function Get-MACVendor {
        param([string]$MAC)
        
        if (-not $MAC -or $MAC.Length -lt 8) { return "" }
        
        # Normalize MAC address
        $cleanMAC = ($MAC -replace '[:-]', '').ToUpper()
        if ($cleanMAC.Length -lt 6) { return "" }
        
        # Try API lookup first (maclookup.app - free, no key required)
        try {
            $apiUrl = "https://api.maclookup.app/v2/macs/$cleanMAC"
            $response = Invoke-RestMethod -Uri $apiUrl -Method Get -TimeoutSec 2 -ErrorAction Stop
            if ($response.company) {
                return $response.company
            }
        } catch {
            # Fallback to local database if API fails
        }
        
        # Local fallback database (common vendors)
        $prefix = $cleanMAC.Substring(0, 6)
        $vendors = @{
            '000000' = 'Xerox'
            '00005E' = 'IANA'
            '0050F2' = 'Microsoft'
            '001B63' = 'Apple'
            '7CC3A1' = 'Apple'
            '001CF0' = 'Apple'
            'F01898' = 'Apple'
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
            '525400' = 'QEMU'
            'A036BC' = 'Espressif'
            '245EBE' = 'Espressif'
            'E09E26' = 'Espressif'
            'FCEE28' = 'Espressif'
            '0CEA14' = 'Espressif'
            '7C1175' = 'D-Link'
            'CCEE28' = 'Espressif'
            'B232E8' = 'Espressif'
            '249E7D' = 'TP-Link'
            '54AF97' = 'TP-Link'
        }
        
        if ($vendors.ContainsKey($prefix)) {
            return $vendors[$prefix]
        }
        
        return ""
    }
    
    function Test-PortScan {
        param([string]$IP, [int[]]$PortList)
        
        $openPorts = @()
        foreach ($port in $PortList) {
            $client = New-Object System.Net.Sockets.TcpClient
            $connect = $client.BeginConnect($IP, $port, $null, $null)
            $wait = $connect.AsyncWaitHandle.WaitOne(100, $false)
            
            if ($wait -and $client.Connected) {
                $openPorts += $port
            }
            $client.Close()
        }
        return ($openPorts -join ',')
    }
    
    function Get-HostInfo {
        param([string]$IP, [int[]]$PortList)
        
        $ping = Test-Connection -ComputerName $IP -Count 1 -Quiet -TimeoutSeconds 1
        if (-not $ping) { return $null }
        
        # Better MAC extraction from arp
        $arpOutput = arp -a $IP 2>$null
        $mac = ""
        if ($arpOutput) {
            $macMatch = [regex]::Match($arpOutput, '([0-9a-fA-F]{2}[:-]){5}([0-9a-fA-F]{2})')
            if ($macMatch.Success) {
                $mac = $macMatch.Value.ToUpper()
            }
        }
        
        $hostname = ""
        try {
            $hostname = [System.Net.Dns]::GetHostEntry($IP).HostName
        } catch {
            $nbt = nbtstat -A $IP 2>$null | Select-String '<00>  UNIQUE'
            if ($nbt) {
                $hostname = ($nbt[0] -split '\s+')[0].Trim()
            }
        }
        
        $portResults = Test-PortScan -IP $IP -PortList $PortList
        $vendor = Get-MACVendor -MAC $mac
        
        return [PSCustomObject]@{
            IPAddress = $IP
            Status = 'Online'
            Hostname = $hostname
            MAC = $mac
            Vendor = $vendor
            OpenPorts = $portResults
        }
    }
    
    # Main execution
    Write-Host "`n🔍 Fast Network Scanner" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan
    
    Write-Host "`n[1] Detecting active network interfaces..." -ForegroundColor Yellow
    $interfaces = Get-ActiveInterfaces
    
    if ($interfaces.Count -eq 0) {
        Write-Host "❌ No active interfaces found!" -ForegroundColor Red
        return
    }
    
    Write-Host "`nActive Interfaces:" -ForegroundColor Green
    $interfaces | ForEach-Object { 
        Write-Host "  ✓ $($_.Name) - $($_.CIDR) ($($_.Description))" -ForegroundColor White
    }
    
    $selectedInterface = $interfaces[0]
    if ($interfaces.Count -gt 1) {
        Write-Host "`nSelect interface to scan:" -ForegroundColor Yellow
        for ($i = 0; $i -lt $interfaces.Count; $i++) {
            Write-Host "  [$($i+1)] $($interfaces[$i].Name) - $($interfaces[$i].CIDR)"
        }
        $selection = Read-Host "Enter number (default: 1)"
        if ($selection -match '^\d+$' -and [int]$selection -le $interfaces.Count -and [int]$selection -gt 0) {
            $selectedInterface = $interfaces[[int]$selection - 1]
        }
    }
    
    Write-Host "`n[2] Scanning network: $($selectedInterface.CIDR)..." -ForegroundColor Yellow
    $ips = Get-NetworkRange -IP $selectedInterface.IPAddress -PrefixLength $selectedInterface.PrefixLength
    
    Write-Host "    Total hosts to scan: $($ips.Count)" -ForegroundColor Gray
    Write-Host "    Using $ThrottleLimit threads for multi-threaded scanning..." -ForegroundColor Gray
    
    # Convert functions to script blocks for parallel execution
    $portScanScript = ${function:Test-PortScan}.ToString()
    $macVendorScript = ${function:Get-MACVendor}.ToString()
    $hostInfoScript = ${function:Get-HostInfo}.ToString()
    
    $results = $ips | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        # Recreate functions in parallel scope
        $portScanDef = $using:portScanScript
        $macVendorDef = $using:macVendorScript
        $hostInfoDef = $using:hostInfoScript
        
        Invoke-Expression "function Test-PortScan { $portScanDef }"
        Invoke-Expression "function Get-MACVendor { $macVendorDef }"
        Invoke-Expression "function Get-HostInfo { $hostInfoDef }"
        
        Get-HostInfo -IP $_ -PortList $using:Ports
    } | Where-Object { $_ -ne $null }
    
    Write-Host "`n[3] Scan complete! Found $($results.Count) active hosts" -ForegroundColor Green
    
    if ($results.Count -gt 0) {
        Write-Host "`n" + ("=" * 60) -ForegroundColor Cyan
        $results | Format-Table -AutoSize
        
        Write-Host "`n💾 Results saved to `$Global:LastScanResults" -ForegroundColor Cyan
        Write-Host "    📋 Quick exports:" -ForegroundColor Gray
        Write-Host "       • All data:  `$Global:LastScanResults | Export-Csv 'scan.csv' -NoTypeInformation" -ForegroundColor White
        Write-Host "       • IPs only:  `$Global:LastScanResults.IPAddress | Set-Clipboard" -ForegroundColor White
        Write-Host "       • MACs only: `$Global:LastScanResults.MAC | Set-Clipboard" -ForegroundColor White
        Write-Host ""
        
        # Store results in global variable for easy export
        $Global:LastScanResults = $results
        
        # Helper functions for quick clipboard copy
        $Global:CopyIPs = { $Global:LastScanResults.IPAddress | Set-Clipboard; Write-Host "✓ IPs copied to clipboard!" -ForegroundColor Green }
        $Global:CopyMACs = { $Global:LastScanResults.MAC | Where-Object {$_} | Set-Clipboard; Write-Host "✓ MACs copied to clipboard!" -ForegroundColor Green }
        
        Write-Host "    ⚡ Quick copy commands:" -ForegroundColor Gray
        Write-Host "       • & `$Global:CopyIPs   - Copy all IPs" -ForegroundColor White
        Write-Host "       • & `$Global:CopyMACs  - Copy all MACs`n" -ForegroundColor White
        
        $results | Out-GridView -Title "Network Scan Results - $($selectedInterface.CIDR) | Select rows & Ctrl+C to copy"
    } else {
        Write-Host "❌ No hosts found on network" -ForegroundColor Red
    }
    
    Write-Host "`n✅ Scan complete!`n" -ForegroundColor Green
}