function Get-SystemDetails {
    <#
    .SYNOPSIS
        Comprehensive system information for MSP technicians

    .DESCRIPTION
        Displays detailed hardware and performance information including:
        - CPU details and current load
        - RAM specifications, usage, and upgrade recommendations
        - Storage devices with capacity, type, and health status
        - System performance summary

    .EXAMPLE
        Get-SystemDetails
        Display full system report

    .EXAMPLE
        sysinfo
        Using alias
    #>

    [CmdletBinding()]
    param()

    Write-Color "`n╔═══════════════════════════════════════════════════════════════╗" 'Header'
    Write-Color "║                    💻 SYSTEM DETAILS                         ║" 'Header'
    Write-Color "╚═══════════════════════════════════════════════════════════════╝`n" 'Header'

    # ══════════════════════════════════════════════════════════════════════════
    # Computer Information
    # ══════════════════════════════════════════════════════════════════════════

    $computerInfo = Get-CimInstance Win32_ComputerSystem
    $osInfo = Get-CimInstance Win32_OperatingSystem
    $biosInfo = Get-CimInstance Win32_BIOS

    Write-Color "┌─ Computer Information" 'Header'
    Write-Color "│  Computer Name    : " 'Detail' -NoNewline
    Write-Color $computerInfo.Name
    Write-Color "│  Manufacturer     : " 'Detail' -NoNewline
    Write-Color "$($computerInfo.Manufacturer) $($computerInfo.Model)"
    Write-Color "│  Serial Number    : " 'Detail' -NoNewline
    Write-Color $biosInfo.SerialNumber
    Write-Color "│  OS               : " 'Detail' -NoNewline
    Write-Color "$($osInfo.Caption) ($($osInfo.OSArchitecture))"
    Write-Color "│  OS Build         : " 'Detail' -NoNewline
    Write-Color $osInfo.Version

    $uptime = (Get-Date) - $osInfo.LastBootUpTime
    Write-Color "│  Uptime           : " 'Detail' -NoNewline
    Write-Color "$($uptime.Days)d $($uptime.Hours)h $($uptime.Minutes)m"
    Write-Color "└─" 'Detail'

    # ══════════════════════════════════════════════════════════════════════════
    # CPU Information
    # ══════════════════════════════════════════════════════════════════════════

    Write-Color "`n┌─ CPU Information" 'Header'
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1

    Write-Color "│  Processor        : " 'Detail' -NoNewline
    Write-Color $cpu.Name.Trim()
    Write-Color "│  Cores / Threads  : " 'Detail' -NoNewline
    Write-Color "$($cpu.NumberOfCores) cores / $($cpu.NumberOfLogicalProcessors) threads"
    Write-Color "│  Base Speed       : " 'Detail' -NoNewline
    Write-Color "$([math]::Round($cpu.MaxClockSpeed / 1000, 2)) GHz"

    # Current CPU load
    $cpuLoad = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    Write-Color "│  Current Load     : " 'Detail' -NoNewline

    if ($cpuLoad -lt 50) {
        Write-Color "$cpuLoad% " 'Good' -NoNewline
        Write-Color "$global:CbitCheck Normal" 'Detail'
    } elseif ($cpuLoad -lt 80) {
        Write-Color "$cpuLoad% " 'Warn' -NoNewline
        Write-Color "$global:CbitWarnGlyph Moderate" 'Detail'
    } else {
        Write-Color "$cpuLoad% " 'Bad' -NoNewline
        Write-Color "$global:CbitWarnGlyph High" 'Detail'
    }
    Write-Color "└─" 'Detail'

    # ══════════════════════════════════════════════════════════════════════════
    # RAM Information
    # ══════════════════════════════════════════════════════════════════════════

    Write-Color "`n┌─ Memory (RAM)" 'Header'

    # FreePhysicalMemory is in KB, so divide by 1024 twice: KB -> MB -> GB
    $totalRAM = [math]::Round($computerInfo.TotalPhysicalMemory / 1GB, 2)
    $availableRAM = [math]::Round($osInfo.FreePhysicalMemory / 1024 / 1024, 2)
    $usedRAM = $totalRAM - $availableRAM
    $ramUsagePercent = [math]::Round(($usedRAM / $totalRAM) * 100, 1)

    Write-Color "│  Total Installed  : " 'Detail' -NoNewline
    Write-Color "$totalRAM GB"
    Write-Color "│  Used             : " 'Detail' -NoNewline
    Write-Color "$usedRAM GB " -NoNewline
    Write-Color "($ramUsagePercent%)" 'Detail'
    Write-Color "│  Available        : " 'Detail' -NoNewline
    Write-Color "$availableRAM GB " -NoNewline
    Write-Color "($([math]::Round(100 - $ramUsagePercent, 1))%)" 'Detail'

    # RAM module details
    $ramModules = Get-CimInstance Win32_PhysicalMemory | Sort-Object DeviceLocator

    if ($ramModules) {
        Write-Color "│" 'Detail'
        Write-Color "│  Installed Modules:" 'Detail'

        foreach ($module in $ramModules) {
            $size = [math]::Round($module.Capacity / 1GB, 0)
            $speed = $module.Speed
            $slot = $module.DeviceLocator
            $manufacturer = if ($module.Manufacturer) { $module.Manufacturer.Trim() } else { "Unknown" }
            $partNumber = if ($module.PartNumber) { $module.PartNumber.Trim() } else { "N/A" }

            Write-Color "│    ├─ $slot" 'Detail'
            Write-Color "│    │  Capacity   : " 'Detail' -NoNewline
            Write-Color "$size GB"
            Write-Color "│    │  Speed      : " 'Detail' -NoNewline
            Write-Color "$speed MHz"
            Write-Color "│    │  Type       : " 'Detail' -NoNewline

            $memType = switch ($module.SMBIOSMemoryType) {
                20 { "DDR" }
                21 { "DDR2" }
                24 { "DDR3" }
                26 { "DDR4" }
                34 { "DDR5" }
                default { "Unknown ($($module.SMBIOSMemoryType))" }
            }
            Write-Color $memType

            Write-Color "│    │  Manufacturer: " 'Detail' -NoNewline
            Write-Color $manufacturer
            Write-Color "│    │  Part Number: " 'Detail' -NoNewline
            Write-Color $partNumber
        }

        # RAM upgrade recommendation
        $totalSlots = (Get-CimInstance Win32_PhysicalMemoryArray | Measure-Object -Property MemoryDevices -Sum).Sum
        $usedSlots = $ramModules.Count
        $emptySlots = $totalSlots - $usedSlots

        Write-Color "│" 'Detail'
        Write-Color "│  Slot Usage       : " 'Detail' -NoNewline
        Write-Color "$usedSlots of $totalSlots slots used " -NoNewline

        if ($emptySlots -gt 0) {
            Write-Color "($emptySlots empty)" 'Good'
        } else {
            Write-Color "(All slots full)" 'Warn'
        }

        if ($ramUsagePercent -gt 80) {
            Write-Color "│" 'Detail'
            Write-Color "│  $global:CbitWarnGlyph RECOMMENDATION : " 'Warn' -NoNewline

            if ($emptySlots -gt 0) {
                $firstModule = $ramModules[0]
                $recommendSize = [math]::Round($firstModule.Capacity / 1GB, 0)
                $recommendSpeed = $firstModule.Speed
                Write-Color "RAM usage high! Add " 'Warn' -NoNewline
                Write-Color "$recommendSize GB ${recommendSpeed}MHz $memType" -NoNewline
                Write-Color " module" 'Warn'
            } else {
                Write-Color "RAM usage high! All slots full - consider replacing with higher capacity modules" 'Warn'
            }
        } elseif ($emptySlots -gt 0 -and $totalRAM -lt 16) {
            Write-Color "│" 'Detail'
            Write-Color "│  💡 TIP           : " 'Detail' -NoNewline
            $firstModule = $ramModules[0]
            $recommendSize = [math]::Round($firstModule.Capacity / 1GB, 0)
            Write-Color "Consider adding $recommendSize GB modules to empty slots for better performance" 'Detail'
        }
    }
    Write-Color "└─" 'Detail'

    # ══════════════════════════════════════════════════════════════════════════
    # Storage Information
    # ══════════════════════════════════════════════════════════════════════════

    Write-Color "`n┌─ Storage Devices" 'Header'

    $physicalDisks = Get-PhysicalDisk | Sort-Object DeviceId

    foreach ($disk in $physicalDisks) {
        $diskNumber = $disk.DeviceId
        $model = $disk.FriendlyName
        $mediaType = $disk.MediaType
        $size = [math]::Round($disk.Size / 1GB, 2)
        $health = $disk.HealthStatus
        $busType = $disk.BusType

        # Get serial number
        $serialNumber = $disk.SerialNumber
        if ([string]::IsNullOrWhiteSpace($serialNumber)) {
            $serialNumber = "N/A"
        }

        Write-Color "│" 'Detail'
        Write-Color "│  ═══ Disk $diskNumber ═══" 'Header'
        Write-Color "│  Model         : " 'Detail' -NoNewline
        Write-Color $model
        Write-Color "│  Capacity      : " 'Detail' -NoNewline
        Write-Color "$size GB"
        Write-Color "│  Type          : " 'Detail' -NoNewline

        $typeDisplay = switch ($mediaType) {
            "HDD" { "HDD (Hard Disk Drive)" }
            "SSD" { "SSD (Solid State Drive)" }
            "SCM" { "Storage Class Memory" }
            default { $mediaType }
        }
        Write-Color $typeDisplay

        Write-Color "│  Interface     : " 'Detail' -NoNewline
        Write-Color $busType
        Write-Color "│  Serial Number : " 'Detail' -NoNewline
        Write-Color $serialNumber
        Write-Color "│  Health Status : " 'Detail' -NoNewline

        switch ($health) {
            "Healthy" { Write-Color "$global:CbitCheck $health" 'Good' }
            "Warning" { Write-Color "$global:CbitWarnGlyph $health" 'Warn' }
            "Unhealthy" { Write-Color "$global:CbitCross $health" 'Bad' }
            default { Write-Color $health }
        }

        # Get partitions and volumes for this disk
        $volumes = Get-Partition | Where-Object { $_.DiskNumber -eq $diskNumber } |
                   Get-Volume | Where-Object { $_.DriveLetter }

        if ($volumes) {
            Write-Color "│" 'Detail'
            Write-Color "│  Volumes:" 'Detail'

            foreach ($volume in $volumes) {
                $driveLetter = $volume.DriveLetter
                $volumeSize = [math]::Round($volume.Size / 1GB, 2)
                $volumeFree = [math]::Round($volume.SizeRemaining / 1GB, 2)
                $volumeUsed = $volumeSize - $volumeFree
                $volumeUsedPercent = [math]::Round(($volumeUsed / $volumeSize) * 100, 1)

                Write-Color "│    ├─ Drive $driveLetter`:" 'Detail'
                Write-Color "│    │  Total  : " 'Detail' -NoNewline
                Write-Color "$volumeSize GB"
                Write-Color "│    │  Used   : " 'Detail' -NoNewline
                Write-Color "$volumeUsed GB " -NoNewline

                if ($volumeUsedPercent -lt 70) {
                    Write-Color "($volumeUsedPercent%)" 'Good'
                } elseif ($volumeUsedPercent -lt 85) {
                    Write-Color "($volumeUsedPercent%)" 'Warn'
                } else {
                    Write-Color "($volumeUsedPercent%)" 'Bad'
                }

                Write-Color "│    │  Free   : " 'Detail' -NoNewline
                Write-Color "$volumeFree GB " -NoNewline
                Write-Color "($([math]::Round(100 - $volumeUsedPercent, 1))%)" 'Detail'

                if ($volumeUsedPercent -ge 85) {
                    Write-Color "│    │  $global:CbitWarnGlyph Warning: Low disk space!" 'Bad'
                }
            }
        }
    }
    Write-Color "└─" 'Detail'

    # ══════════════════════════════════════════════════════════════════════════
    # Performance Summary
    # ══════════════════════════════════════════════════════════════════════════

    Write-Color "`n┌─ Performance Summary" 'Header'

    # Overall system health
    $issues = @()

    if ($cpuLoad -gt 80) { $issues += "High CPU usage" }
    if ($ramUsagePercent -gt 85) { $issues += "High RAM usage" }

    $volumeIssues = Get-Volume | Where-Object {
        $_.DriveLetter -and
        (($_.SizeRemaining / $_.Size) * 100) -lt 15
    }
    if ($volumeIssues) { $issues += "Low disk space on $($volumeIssues.Count) volume(s)" }

    $unhealthyDisks = $physicalDisks | Where-Object { $_.HealthStatus -ne "Healthy" }
    if ($unhealthyDisks) { $issues += "Disk health warning" }

    Write-Color "│  Status           : " 'Detail' -NoNewline

    if ($issues.Count -eq 0) {
        Write-Color "$global:CbitCheck All systems nominal" 'Good'
    } else {
        Write-Color "$global:CbitWarnGlyph $($issues.Count) issue(s) detected" 'Warn'
        foreach ($issue in $issues) {
            Write-Color "│    • $issue" 'Warn'
        }
    }

    Write-Color "└─" 'Detail'

    Write-Host ""
}

# Aliases
Set-Alias -Name sysinfo -Value Get-SystemDetails -Scope Global
Set-Alias -Name sys -Value Get-SystemDetails -Scope Global