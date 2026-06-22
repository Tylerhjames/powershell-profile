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
    
    Write-Host "`n╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor DarkCyan
    Write-Host "║                    💻 SYSTEM DETAILS                         ║" -ForegroundColor DarkCyan
    Write-Host "╚═══════════════════════════════════════════════════════════════╝`n" -ForegroundColor DarkCyan
    
    # ══════════════════════════════════════════════════════════════════════════
    # Computer Information
    # ══════════════════════════════════════════════════════════════════════════
    
    $computerInfo = Get-CimInstance Win32_ComputerSystem
    $osInfo = Get-CimInstance Win32_OperatingSystem
    $biosInfo = Get-CimInstance Win32_BIOS
    
    Write-Host "┌─ Computer Information" -ForegroundColor DarkCyan
    Write-Host "│  Computer Name    : " -NoNewline -ForegroundColor DarkGray
    Write-Host $computerInfo.Name -ForegroundColor White
    Write-Host "│  Manufacturer     : " -NoNewline -ForegroundColor DarkGray
    Write-Host "$($computerInfo.Manufacturer) $($computerInfo.Model)" -ForegroundColor White
    Write-Host "│  Serial Number    : " -NoNewline -ForegroundColor DarkGray
    Write-Host $biosInfo.SerialNumber -ForegroundColor White
    Write-Host "│  OS               : " -NoNewline -ForegroundColor DarkGray
    Write-Host "$($osInfo.Caption) ($($osInfo.OSArchitecture))" -ForegroundColor White
    Write-Host "│  OS Build         : " -NoNewline -ForegroundColor DarkGray
    Write-Host $osInfo.Version -ForegroundColor White
    
    $uptime = (Get-Date) - $osInfo.LastBootUpTime
    Write-Host "│  Uptime           : " -NoNewline -ForegroundColor DarkGray
    Write-Host "$($uptime.Days)d $($uptime.Hours)h $($uptime.Minutes)m" -ForegroundColor White
    Write-Host "└─" -ForegroundColor DarkCyan
    
    # ══════════════════════════════════════════════════════════════════════════
    # CPU Information
    # ══════════════════════════════════════════════════════════════════════════
    
    Write-Host "`n┌─ CPU Information" -ForegroundColor DarkCyan
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    
    Write-Host "│  Processor        : " -NoNewline -ForegroundColor DarkGray
    Write-Host $cpu.Name.Trim() -ForegroundColor White
    Write-Host "│  Cores / Threads  : " -NoNewline -ForegroundColor DarkGray
    Write-Host "$($cpu.NumberOfCores) cores / $($cpu.NumberOfLogicalProcessors) threads" -ForegroundColor White
    Write-Host "│  Base Speed       : " -NoNewline -ForegroundColor DarkGray
    Write-Host "$([math]::Round($cpu.MaxClockSpeed / 1000, 2)) GHz" -ForegroundColor White
    
    # Current CPU load
    $cpuLoad = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    Write-Host "│  Current Load     : " -NoNewline -ForegroundColor DarkGray
    
    if ($cpuLoad -lt 50) {
        Write-Host "$cpuLoad% " -NoNewline -ForegroundColor Green
        Write-Host "✓ Normal" -ForegroundColor DarkGray
    } elseif ($cpuLoad -lt 80) {
        Write-Host "$cpuLoad% " -NoNewline -ForegroundColor DarkYellow
        Write-Host "⚠ Moderate" -ForegroundColor DarkGray
    } else {
        Write-Host "$cpuLoad% " -NoNewline -ForegroundColor Red
        Write-Host "⚠ High" -ForegroundColor DarkGray
    }
    Write-Host "└─" -ForegroundColor DarkCyan
    
    # ══════════════════════════════════════════════════════════════════════════
    # RAM Information
    # ══════════════════════════════════════════════════════════════════════════
    
    Write-Host "`n┌─ Memory (RAM)" -ForegroundColor DarkCyan
    
    # FreePhysicalMemory is in KB, so divide by 1024 twice: KB -> MB -> GB
    $totalRAM = [math]::Round($computerInfo.TotalPhysicalMemory / 1GB, 2)
    $availableRAM = [math]::Round($osInfo.FreePhysicalMemory / 1024 / 1024, 2)
    $usedRAM = $totalRAM - $availableRAM
    $ramUsagePercent = [math]::Round(($usedRAM / $totalRAM) * 100, 1)
    
    Write-Host "│  Total Installed  : " -NoNewline -ForegroundColor DarkGray
    Write-Host "$totalRAM GB" -ForegroundColor White
    Write-Host "│  Used             : " -NoNewline -ForegroundColor DarkGray
    Write-Host "$usedRAM GB " -NoNewline -ForegroundColor White
    Write-Host "($ramUsagePercent%)" -ForegroundColor DarkGray
    Write-Host "│  Available        : " -NoNewline -ForegroundColor DarkGray
    Write-Host "$availableRAM GB " -NoNewline -ForegroundColor White
    Write-Host "($([math]::Round(100 - $ramUsagePercent, 1))%)" -ForegroundColor DarkGray
    
    # RAM module details
    $ramModules = Get-CimInstance Win32_PhysicalMemory | Sort-Object DeviceLocator
    
    if ($ramModules) {
        Write-Host "│" -ForegroundColor DarkCyan
        Write-Host "│  Installed Modules:" -ForegroundColor DarkCyan
        
        foreach ($module in $ramModules) {
            $size = [math]::Round($module.Capacity / 1GB, 0)
            $speed = $module.Speed
            $slot = $module.DeviceLocator
            $manufacturer = if ($module.Manufacturer) { $module.Manufacturer.Trim() } else { "Unknown" }
            $partNumber = if ($module.PartNumber) { $module.PartNumber.Trim() } else { "N/A" }
            
            Write-Host "│    ├─ $slot" -ForegroundColor DarkCyan
            Write-Host "│    │  Capacity   : " -NoNewline -ForegroundColor DarkGray
            Write-Host "$size GB" -ForegroundColor White
            Write-Host "│    │  Speed      : " -NoNewline -ForegroundColor DarkGray
            Write-Host "$speed MHz" -ForegroundColor White
            Write-Host "│    │  Type       : " -NoNewline -ForegroundColor DarkGray
            
            $memType = switch ($module.SMBIOSMemoryType) {
                20 { "DDR" }
                21 { "DDR2" }
                24 { "DDR3" }
                26 { "DDR4" }
                34 { "DDR5" }
                default { "Unknown ($($module.SMBIOSMemoryType))" }
            }
            Write-Host $memType -ForegroundColor White
            
            Write-Host "│    │  Manufacturer: " -NoNewline -ForegroundColor DarkGray
            Write-Host $manufacturer -ForegroundColor White
            Write-Host "│    │  Part Number: " -NoNewline -ForegroundColor DarkGray
            Write-Host $partNumber -ForegroundColor White
        }
        
        # RAM upgrade recommendation
        $totalSlots = (Get-CimInstance Win32_PhysicalMemoryArray | Measure-Object -Property MemoryDevices -Sum).Sum
        $usedSlots = $ramModules.Count
        $emptySlots = $totalSlots - $usedSlots
        
        Write-Host "│" -ForegroundColor DarkCyan
        Write-Host "│  Slot Usage       : " -NoNewline -ForegroundColor DarkGray
        Write-Host "$usedSlots of $totalSlots slots used " -NoNewline -ForegroundColor White
        
        if ($emptySlots -gt 0) {
            Write-Host "($emptySlots empty)" -ForegroundColor DarkGreen
        } else {
            Write-Host "(All slots full)" -ForegroundColor DarkYellow
        }
        
        if ($ramUsagePercent -gt 80) {
            Write-Host "│" -ForegroundColor DarkCyan
            Write-Host "│  ⚠ RECOMMENDATION : " -NoNewline -ForegroundColor DarkYellow
            
            if ($emptySlots -gt 0) {
                $firstModule = $ramModules[0]
                $recommendSize = [math]::Round($firstModule.Capacity / 1GB, 0)
                $recommendSpeed = $firstModule.Speed
                Write-Host "RAM usage high! Add " -NoNewline -ForegroundColor Yellow
                Write-Host "$recommendSize GB ${recommendSpeed}MHz $memType" -NoNewline -ForegroundColor White
                Write-Host " module" -ForegroundColor Yellow
            } else {
                Write-Host "RAM usage high! All slots full - consider replacing with higher capacity modules" -ForegroundColor Yellow
            }
        } elseif ($emptySlots -gt 0 -and $totalRAM -lt 16) {
            Write-Host "│" -ForegroundColor DarkCyan
            Write-Host "│  💡 TIP           : " -NoNewline -ForegroundColor DarkCyan
            $firstModule = $ramModules[0]
            $recommendSize = [math]::Round($firstModule.Capacity / 1GB, 0)
            Write-Host "Consider adding $recommendSize GB modules to empty slots for better performance" -ForegroundColor DarkGray
        }
    }
    Write-Host "└─" -ForegroundColor DarkCyan
    
    # ══════════════════════════════════════════════════════════════════════════
    # Storage Information
    # ══════════════════════════════════════════════════════════════════════════
    
    Write-Host "`n┌─ Storage Devices" -ForegroundColor DarkCyan
    
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
        
        Write-Host "│" -ForegroundColor DarkCyan
        Write-Host "│  ═══ Disk $diskNumber ═══" -ForegroundColor DarkCyan
        Write-Host "│  Model         : " -NoNewline -ForegroundColor DarkGray
        Write-Host $model -ForegroundColor White
        Write-Host "│  Capacity      : " -NoNewline -ForegroundColor DarkGray
        Write-Host "$size GB" -ForegroundColor White
        Write-Host "│  Type          : " -NoNewline -ForegroundColor DarkGray
        
        $typeDisplay = switch ($mediaType) {
            "HDD" { "HDD (Hard Disk Drive)" }
            "SSD" { "SSD (Solid State Drive)" }
            "SCM" { "Storage Class Memory" }
            default { $mediaType }
        }
        Write-Host $typeDisplay -ForegroundColor White
        
        Write-Host "│  Interface     : " -NoNewline -ForegroundColor DarkGray
        Write-Host $busType -ForegroundColor White
        Write-Host "│  Serial Number : " -NoNewline -ForegroundColor DarkGray
        Write-Host $serialNumber -ForegroundColor White
        Write-Host "│  Health Status : " -NoNewline -ForegroundColor DarkGray
        
        switch ($health) {
            "Healthy" { Write-Host "✓ $health" -ForegroundColor Green }
            "Warning" { Write-Host "⚠ $health" -ForegroundColor DarkYellow }
            "Unhealthy" { Write-Host "✗ $health" -ForegroundColor Red }
            default { Write-Host $health -ForegroundColor White }
        }
        
        # Get partitions and volumes for this disk
        $volumes = Get-Partition | Where-Object { $_.DiskNumber -eq $diskNumber } | 
                   Get-Volume | Where-Object { $_.DriveLetter }
        
        if ($volumes) {
            Write-Host "│" -ForegroundColor DarkCyan
            Write-Host "│  Volumes:" -ForegroundColor DarkCyan
            
            foreach ($volume in $volumes) {
                $driveLetter = $volume.DriveLetter
                $volumeSize = [math]::Round($volume.Size / 1GB, 2)
                $volumeFree = [math]::Round($volume.SizeRemaining / 1GB, 2)
                $volumeUsed = $volumeSize - $volumeFree
                $volumeUsedPercent = [math]::Round(($volumeUsed / $volumeSize) * 100, 1)
                
                Write-Host "│    ├─ Drive $driveLetter`:" -ForegroundColor DarkCyan
                Write-Host "│    │  Total  : " -NoNewline -ForegroundColor DarkGray
                Write-Host "$volumeSize GB" -ForegroundColor White
                Write-Host "│    │  Used   : " -NoNewline -ForegroundColor DarkGray
                Write-Host "$volumeUsed GB " -NoNewline -ForegroundColor White
                
                if ($volumeUsedPercent -lt 70) {
                    Write-Host "($volumeUsedPercent%)" -ForegroundColor Green
                } elseif ($volumeUsedPercent -lt 85) {
                    Write-Host "($volumeUsedPercent%)" -ForegroundColor DarkYellow
                } else {
                    Write-Host "($volumeUsedPercent%)" -ForegroundColor Red
                }
                
                Write-Host "│    │  Free   : " -NoNewline -ForegroundColor DarkGray
                Write-Host "$volumeFree GB " -NoNewline -ForegroundColor White
                Write-Host "($([math]::Round(100 - $volumeUsedPercent, 1))%)" -ForegroundColor DarkGray
                
                if ($volumeUsedPercent -ge 85) {
                    Write-Host "│    │  ⚠ Warning: Low disk space!" -ForegroundColor Red
                }
            }
        }
    }
    Write-Host "└─" -ForegroundColor DarkCyan
    
    # ══════════════════════════════════════════════════════════════════════════
    # Performance Summary
    # ══════════════════════════════════════════════════════════════════════════
    
    Write-Host "`n┌─ Performance Summary" -ForegroundColor DarkCyan
    
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
    
    Write-Host "│  Status           : " -NoNewline -ForegroundColor DarkGray
    
    if ($issues.Count -eq 0) {
        Write-Host "✓ All systems nominal" -ForegroundColor Green
    } else {
        Write-Host "⚠ $($issues.Count) issue(s) detected" -ForegroundColor DarkYellow
        foreach ($issue in $issues) {
            Write-Host "│    • $issue" -ForegroundColor Yellow
        }
    }
    
    Write-Host "└─" -ForegroundColor DarkCyan
    
    Write-Host ""
}

# Aliases
Set-Alias -Name sysinfo -Value Get-SystemDetails -Scope Global
Set-Alias -Name sys -Value Get-SystemDetails -Scope Global