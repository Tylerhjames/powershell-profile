function Scan-Network {
    [CmdletBinding()]
    param()

    Write-Host "Advanced PowerShell Network Scanner" -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan

    do {
        $network = Read-Host "Enter network (e.g. 192.168.1.0/24 or 192.168.1.1-192.168.1.254)"
    } while (-not $network)

    $fast = (Read-Host "Fast scan? (skip port scanning) [Y/n]").Trim() -notin "n","N"
    
    if (-not $fast) {
        $portInput = Read-Host "Ports to scan (comma-separated, e.g. 22,80,443,3389,445 or press Enter for defaults)"
        $ports = if ($portInput.Trim()) {
            ($portInput -split ',' | ForEach-Object { $_.Trim() -as [int] }) -ne $null
        } else {
            @(21,22,23,80,135,139,443,445,3389,5040,8080,8443)
        }
    } else {
        $ports = @()
    }

    $threads = Read-Host "Max threads (default 256, up to 1024 recommended)" 
    $threads = if ($threads -match '^\d+$') { [int]$threads } else { 256 }
    $threads = [Math]::Clamp($threads, 32, 1024)

    # -----------------------------
    # Auto-download OUI database
    # -----------------------------
    $OUIFile = "$env:LOCALAPPDATA\PowerShell-OUI\oui.txt"
    $OUIUrl  = "https://standards-oui.ieee.org/oui/oui.txt"

    if (-not (Test-Path $OUIFile) -or ((Get-Item $OUIFile).LastWriteTime -lt (Get-Date).AddDays(-7))) {
        Write-Host "Downloading latest OUI database from IEEE..." -ForegroundColor Yellow
        $dir = Split-Path $OUIFile -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        try {
            Invoke-WebRequest -Uri $OUIUrl -OutFile $OUIFile -UseBasicParsing
            Write-Host "OUI database updated!" -ForegroundColor Green
        } catch {
            Write-Warning "Could not update OUI. Will use built-in fallback or previous cache."
        }
    }

    # Load OUI dictionary
    $OUILookup = @{}
    if (Test-Path $OUIFile) {
        Get-Content $OUIFile | ForEach-Object {
            if ($_ -match '^([0-9A-F]{6})\s+\(hex\)\s+(.+)$') {
                $oui = ($matches[1] -replace '..', '$&:').Substring(0,8).ToUpper()
                $OUILookup[$oui] = $matches[2].Trim()
            }
        }
    }

    # -----------------------------
    # IP Range Parser
    # -----------------------------
    function Get-IPRange {
        param([string]$InputString)
        if ($InputString -match '^\d+\.\d+\.\d+\.\d+/\d+$') {
            $ip, $cidr = $InputString -split '/'
            $cidr = [int]$cidr
            $ipAddr = [Net.IPAddress]$ip
            $mask = [uint32]([math]::Pow(2,32) - [math]::Pow(2,32-$cidr))
            $network = $ipAddr.Address -band $mask
            $start = $network + 1
            $broadcast = $network -bor (-bnot $mask)
            $end = $broadcast - 1
            for ($i = $start; $i -le $end; $i++) { [Net.IPAddress]$i }
        }
        elseif ($InputString -match '^\d+\.\d+\.\d+\.\d+-\d+$') {
            $parts = $InputString -split '\.'
            $prefix = "$($parts[0]).$($parts[1]).$($parts[2])."
            $startOctet = [int]($parts[3] -split '-')[0]
            $endOctet   = [int]($parts[3] -split '-')[1]
            for ($i = $startOctet; $i -le $endOctet; $i++) {
                [Net.IPAddress]("$prefix$i")
            }
        }
        else { throw "Invalid format. Use CIDR (192.168.1.0/24) or range (192.168.1.1-192.168.1.254)" }
    }

    $ips = Get-IPRange $network
    Write-Host "Scanning $($ips.Count) IPs on $network with $threads threads..." -ForegroundColor Cyan

    # -----------------------------
    # Parallel scanning
    # -----------------------------
    $RunspacePool = [RunspaceFactory]::CreateRunspacePool(1, $threads)
    $RunspacePool.Open()
    $Jobs = @()
    $Results = [System.Collections.Concurrent.ConcurrentBag[psobject]]::new()

    # Pass the whole lookup table with $using (simple variable = allowed)
    foreach ($ipObj in $ips) {
        $ip = $ipObj.IPAddressToString

        $ps = [PowerShell]::Create().AddScript({
            param($IP, $Timeout, $Ports, $FastScan, $LookupTable)

            $result = [pscustomobject]@{
                IP           = $IP
                Status       = "Down"
                ResponseTime = ""
                Hostname     = ""
                MAC          = ""
                Vendor       = ""
                ComputerName = ""
                OpenPorts    = ""
                LastSeen     = Get-Date
            }

            # Ping
            $ping = New-Object System.Net.NetworkInformation.Ping
            $reply = $ping.Send($IP, $Timeout)
            if ($reply.Status -eq "Success") {
                $result.Status = "Up"
                $result.ResponseTime = "$($reply.RoundtripTime)ms"

                # Reverse DNS
                try { $result.Hostname = [Net.Dns]::GetHostEntry($IP).HostName } catch { }

                # ARP → MAC
                try {
                    $arpResult = arp -a | Where-Object { $_ -match [regex]::Escape($IP) }
                    if ($arpResult) {
                        $mac = ($arpResult -split '\s+')[2] -replace '-', ':'
                        if ($mac -and $mac -notmatch 'ff:ff:ff:ff:ff:ff') {
                            $result.MAC = $mac.ToUpper()
                            $ouiKey = $mac.Substring(0,8).ToUpper()
                            $result.Vendor = $LookupTable[$ouiKey] ?? "Unknown"
                        }
                    }
                } catch { }

                # NetBIOS name
                try {
                    $nbt = nbtstat -A $IP 2>$null | Select-String "<00>"
                    if ($nbt) {
                        $line = $nbt.Line -split '\s+'
                        $result.ComputerName = $line[$line.Count-2]
                    }
                } catch { }

                # Port scan
                if (-not $FastScan) {
                    $open = foreach ($port in $Ports) {
                        $tcp = New-Object Net.Sockets.TcpClient
                        $connect = $tcp.BeginConnect($IP, $port, $null, $null)
                        if ($connect.AsyncWaitHandle.WaitOne(150)) {
                            try { $null = $tcp.EndConnect($connect); $port } catch { }
                        }
                        $tcp.Close()
                    }
                    if ($open) { $result.OpenPorts = ($open -join ", ") }
                }
            }
            return $result
        }).AddParameters(@{
            IP          = $ip
            Timeout     = 1000
            Ports       = $ports
            FastScan    = $fast
            LookupTable = $OUILookup   # This is now allowed — simple variable!
        })

        $ps.RunspacePool = $RunspacePool
        $Jobs += [pscustomobject]@{ Instance = $ps; AsyncResult = $ps.BeginInvoke() }
    }

    # Progress bar
    while ($Jobs.AsyncResult.IsCompleted -contains $false) {
        $done = ($Jobs | Where-Object { $_.AsyncResult.IsCompleted }).Count
        Write-Progress -Activity "Scanning $network" -Status "$done / $($ips.Count)" -PercentComplete ($done/$ips.Count*100)
        Start-Sleep -Milliseconds 200
    }

    foreach ($job in $Jobs) {
        $Results.Add($job.Instance.EndInvoke($job.AsyncResult))
        $job.Instance.Dispose()
    }

    $RunspacePool.Close(); $RunspacePool.Dispose()
    Write-Progress -Activity "Complete" -Completed

    # Beautiful GUI
    $Results |
        Sort-Object IP |
        Select-Object IP,
                      Status,
                      ResponseTime,
                      Hostname,
                      ComputerName,
                      MAC,
                      Vendor,
                      OpenPorts,
                      @{N="Last Seen"; E={$_.LastSeen.ToString("HH:mm:ss")}} |
        Out-GridView -Title "Network Scan Complete — $network — $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -PassThru
}

# Handy alias
Set-Alias -Name scan -Value Scan-Network