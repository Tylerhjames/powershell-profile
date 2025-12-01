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
    
    # Validate prefix length
    if ($PrefixLength -lt 1 -or $PrefixLength -gt 30) {
        throw "Invalid prefix length: $PrefixLength (must be 1-30)"
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
    
    # Calculate subnet mask
    $mask = [uint32]0xFFFFFFFF -shl $hostBits
    $networkInt = $ipInt -band $mask
    
    # Generate IP list efficiently
    $ips = [System.Collections.Generic.List[string]]::new([int]$hostCount)
    
    for ($i = 1; $i -le $hostCount; $i++) {
        try {
            $hostInt = $networkInt + $i
            
            # Ensure we don't overflow - cast to uint32 explicitly
            $hostInt = [uint32]$hostInt
            
            # Convert back to IP address
            $bytes = [System.BitConverter]::GetBytes($hostInt)
            [Array]::Reverse($bytes)
            
            # Create IP address string
            $ipAddr = [System.Net.IPAddress]::new($bytes)
            $ips.Add($ipAddr.ToString())
        } catch {
            Write-Warning "Skipped invalid IP at offset $i: $_"
            continue
        }
    }
    
    if ($ips.Count -eq 0) {
        throw "Failed to generate any valid IPs in range"
    }
    
    return $ips.ToArray()
}