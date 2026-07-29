function Invoke-ServerInventory {
    <#
    .SYNOPSIS
    Collects comprehensive server hardware and role inventory.

    .DESCRIPTION
    Gathers system, CPU, memory, storage, network, OS, services, firewall, and
    installed software details. Conditionally collects Hyper-V, iSCSI, DHCP,
    FSMO, and Group Policy data based on detected roles. Outputs both a raw
    text file and a formatted HTML report.

    Auto-detects physical vs virtual and appends -HVS or -VM to filenames.
    Safe to run on production systems — read-only, no changes made.

    .PARAMETER OutputPath
    Directory for output files. Defaults to C:\CBIT\Audit.

    .EXAMPLE
    Invoke-ServerInventory

    .EXAMPLE
    Invoke-ServerInventory -OutputPath "D:\Audits"
    #>
    [CmdletBinding()]
    param(
        [string]$OutputPath = "C:\CBIT\Audit"
    )

    # ── Verify we're on a server OS (warn but don't block) ──
    $osCaption = (Get-CimInstance Win32_OperatingSystem).Caption
    if ($osCaption -notmatch 'Server') {
        Write-Color "$global:CbitWarnGlyph This appears to be a workstation OS ($osCaption). Some sections may be incomplete." 'Warn'
    }

    if (!(Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }

    # ════════════════════════════════════════════════════════════════════════
    # Detect physical vs virtual
    # ════════════════════════════════════════════════════════════════════════

    $csModel = (Get-CimInstance Win32_ComputerSystem).Model
    $isVirtual = $csModel -match 'Virtual|VMware|KVM|Xen|HVM|QEMU'
    $machineType = if ($isVirtual) { "VM" } else { "HVS" }

    $dateStamp = Get-Date -Format 'yyyy-MM-dd'
    $baseName = "$($env:COMPUTERNAME)-${machineType}_inventory_${dateStamp}"
    $outFile = Join-Path $OutputPath "$baseName.txt"
    $htmlFile = Join-Path $OutputPath "$baseName.html"

    Write-Color "Collecting inventory for $($env:COMPUTERNAME) ($machineType)..." 'Header'

    # ════════════════════════════════════════════════════════════════════════
    # COLLECT DATA
    # ════════════════════════════════════════════════════════════════════════

    $cs = Get-CimInstance Win32_ComputerSystem
    $bb = Get-CimInstance Win32_BaseBoard
    $bios = Get-CimInstance Win32_BIOS
    $os = Get-CimInstance Win32_OperatingSystem
    $cpus = Get-CimInstance Win32_Processor
    $memSticks = Get-CimInstance Win32_PhysicalMemory
    $disks = Get-CimInstance Win32_DiskDrive
    $volumes = Get-Volume | Where-Object { $_.DriveLetter }

    $adaptersWithIPs = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' }).InterfaceAlias | Select-Object -Unique
    $netAdapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -or $_.Name -in $adaptersWithIPs }
    $ipConfig = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' }

    $software = @()
    $software += Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue
    $software += Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue
    $software = $software | Where-Object { $_.DisplayName } |
        Select-Object DisplayName, DisplayVersion, Publisher, InstallDate | Sort-Object DisplayName -Unique

    $services = Get-Service | Where-Object Status -eq 'Running' |
        Select-Object Name, DisplayName, StartType | Sort-Object DisplayName

    $shares = Get-SmbShare -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*$' }
    $fwProfiles = Get-NetFirewallProfile -ErrorAction SilentlyContinue

    $customFwRules = @()
    try {
        $customFwRules = Get-NetFirewallRule -Enabled True -ErrorAction SilentlyContinue | Where-Object {
            ($null -eq $_.Group -or $_.Group -eq '' -or $_.Group -notmatch '^@') -and
            $_.DisplayName -notmatch '^ms-resource:'
        } | Select-Object DisplayName, Direction, Action, Profile -Unique | Sort-Object Direction, DisplayName
    } catch {}

    # Roles & Features (server only — graceful skip on workstations)
    $roles = @()
    try { $roles = Get-WindowsFeature -ErrorAction Stop | Where-Object Installed | Select-Object Name, DisplayName } catch {}

    # System info with baseboard fallback
    $sysManufacturer = if ($cs.Manufacturer -and $cs.Manufacturer.Trim()) { $cs.Manufacturer.Trim() } else { $bb.Manufacturer }
    $sysModel = if ($cs.Model -and $cs.Model.Trim()) { $cs.Model.Trim() } else { "$($bb.Manufacturer) $($bb.Product)" }
    $totalGB = [math]::Round(($memSticks | Measure-Object -Property Capacity -Sum).Sum / 1GB, 1)

    $domainRole = switch ($cs.DomainRole) {
        0 { "Standalone Workstation" }; 1 { "Member Workstation" }; 2 { "Standalone Server" }
        3 { "Member Server" }; 4 { "Backup Domain Controller" }; 5 { "Primary Domain Controller" }
        default { "Unknown ($($cs.DomainRole))" }
    }
    $isDomainJoined = $cs.DomainRole -ge 1 -and $cs.DomainRole -ne 2
    $isDC = $cs.DomainRole -ge 4
    $collected = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    # ── Role detection for conditional sections ──
    $hvInstalled = $false
    try { $hvInstalled = (Get-WindowsFeature -Name Hyper-V -ErrorAction SilentlyContinue).Installed } catch {}

    $dhcpInstalled = $false
    try { $dhcpInstalled = (Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue).Installed } catch {}

    # ── Conditional: Hyper-V ──
    $vms = @(); $vSwitches = @()
    if ($hvInstalled) {
        try { $vms = Get-VM } catch { $vms = @() }
        try { $vSwitches = Get-VMSwitch } catch { $vSwitches = @() }
    }

    # ── Conditional: IP Routes ──
    $ipRoutes = @()
    try {
        $ipRoutes = Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
            $_.DestinationPrefix -notmatch '^127\.' -and
            $_.DestinationPrefix -notmatch '^169\.254\.' -and
            $_.DestinationPrefix -notmatch '^224\.' -and
            $_.DestinationPrefix -ne '255.255.255.255/32'
        } | Select-Object DestinationPrefix, NextHop, RouteMetric, InterfaceAlias, @{
            N='Type';E={
                if ($_.DestinationPrefix -eq '0.0.0.0/0') { 'Default Gateway' }
                elseif ($_.NextHop -eq '0.0.0.0') { 'Connected' }
                else { 'Static/DHCP' }
            }
        } | Sort-Object Type, DestinationPrefix
    } catch {}

    # ── Conditional: iSCSI ──
    $iscsiSessions = @(); $iscsiConnections = @()
    $iscsiActive = $false
    try {
        $iscsiSvc = Get-Service -Name MSiSCSI -ErrorAction SilentlyContinue
        if ($iscsiSvc -and $iscsiSvc.Status -eq 'Running') {
            $iscsiActive = $true
            $iscsiSessions = Get-IscsiSession -ErrorAction SilentlyContinue |
                Select-Object SessionIdentifier, TargetNodeAddress, IsConnected, IsPersistent,
                @{N='InitiatorPortal';E={$_.InitiatorPortalAddress}},
                @{N='TargetPortal';E={$_.TargetPortalAddress}}
            $iscsiConnections = Get-IscsiConnection -ErrorAction SilentlyContinue |
                Select-Object ConnectionIdentifier, InitiatorAddress, TargetAddress, InitiatorPortNumber, TargetPortNumber
        }
    } catch {}

    # ── Conditional: FSMO Roles (DC only) ──
    $fsmoOutput = $null
    if ($isDC) {
        try { $fsmoOutput = (netdom query fsmo 2>&1 | Out-String).Trim() } catch {}
    }

    # ── Conditional: DHCP Scopes ──
    $dhcpV4Scopes = @()
    if ($dhcpInstalled) {
        try {
            $dhcpV4Scopes = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue |
                Select-Object ScopeId, Name, SubnetMask, StartRange, EndRange, State,
                @{N='LeaseDuration';E={$_.LeaseDuration.ToString()}}
        } catch {}
    }

    # ── Conditional: Applied Group Policy ──
    $gpApplied = $null
    if ($isDomainJoined) {
        try { $gpApplied = (gpresult /r /scope:computer 2>&1 | Out-String).Trim() } catch {}
    }

    # ── Custom Scheduled Tasks ──
    $customTasks = @()
    try {
        $customTasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
            $_.TaskPath -notmatch '^\\Microsoft\\' -and
            $_.TaskName -notmatch '^User_Feed_Synchronization' -and
            $_.TaskName -notmatch '^CreateExplorerShellUnelevatedTask' -and
            $_.Author -notmatch '^Microsoft' -and
            $_.State -ne 'Disabled'
        } | Select-Object TaskName, TaskPath, State, @{
            N='Author';E={ if ($_.Author) { $_.Author } else { '(not set)' } }
        }, @{
            N='NextRun';E={
                try {
                    $info = $_ | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
                    if ($info.NextRunTime -and $info.NextRunTime -ne [datetime]::MinValue) { $info.NextRunTime.ToString('yyyy-MM-dd HH:mm') } else { 'N/A' }
                } catch { 'N/A' }
            }
        }, @{
            N='LastRun';E={
                try {
                    $info = $_ | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
                    if ($info.LastRunTime -and $info.LastRunTime.Year -gt 1999) { $info.LastRunTime.ToString('yyyy-MM-dd HH:mm') } else { 'Never' }
                } catch { 'Never' }
            }
        }, @{
            N='LastResult';E={
                try {
                    $info = $_ | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
                    if ($null -ne $info.LastTaskResult) { '0x{0:X}' -f $info.LastTaskResult } else { 'N/A' }
                } catch { 'N/A' }
            }
        } | Sort-Object TaskPath, TaskName
    } catch {}

    # ════════════════════════════════════════════════════════════════════════
    # TEXT OUTPUT
    # ════════════════════════════════════════════════════════════════════════

    $output = @()
    $output += "=== INVENTORY: $($cs.Name) ==="
    $output += "Machine Type: $machineType"
    $output += "Collected: $collected"
    $output += ""

    $output += "=== SYSTEM ==="
    $output += "Name:          $($cs.Name)"
    $output += "Manufacturer:  $sysManufacturer"
    $output += "Model:         $sysModel"
    $output += "Total RAM:     $totalGB GB"
    $output += ""

    $output += "=== BASEBOARD ==="
    $output += ($bb | Select-Object Manufacturer, Product, SerialNumber | Format-List | Out-String)

    $output += "=== BIOS ==="
    $output += ($bios | Select-Object SMBIOSBIOSVersion, ReleaseDate, SerialNumber | Format-List | Out-String)

    $output += "=== DOMAIN INFO ==="
    $output += "Domain: $($cs.Domain)"
    $output += "Domain Role: $domainRole"
    $output += ""

    $output += "=== CPU ==="
    $output += ($cpus | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed | Format-List | Out-String)

    $output += "=== MEMORY SUMMARY ==="
    $output += "Total Installed: ${totalGB} GB across $($memSticks.Count) DIMMs"
    $output += ""
    $output += "=== MEMORY DETAIL ==="
    $output += ($memSticks | Select-Object BankLabel, @{N='CapacityGB';E={[math]::Round($_.Capacity/1GB,1)}}, Speed, PartNumber, Manufacturer | Format-Table -AutoSize | Out-String -Width 300)

    $output += "=== PHYSICAL DISKS ==="
    $output += ($disks | Select-Object Model, @{N='SizeGB';E={[math]::Round($_.Size/1GB,1)}}, MediaType, InterfaceType, SerialNumber | Format-Table -AutoSize | Out-String -Width 300)

    $output += "=== STORAGE VOLUMES ==="
    $output += ($volumes | Select-Object DriveLetter, FileSystemLabel, @{N='SizeGB';E={[math]::Round($_.Size/1GB,1)}}, @{N='FreeGB';E={[math]::Round($_.SizeRemaining/1GB,1)}}, HealthStatus | Format-Table -AutoSize | Out-String -Width 300)

    $output += "=== NETWORK ADAPTERS ==="
    $output += ($netAdapters | Select-Object Name, Status, InterfaceDescription, MacAddress, LinkSpeed | Format-Table -AutoSize | Out-String -Width 300)

    $output += "=== IP CONFIGURATION ==="
    $output += ($ipConfig | Select-Object InterfaceAlias, IPAddress, PrefixLength | Format-Table -AutoSize | Out-String -Width 300)

    $output += "=== IP ROUTES ==="
    if ($ipRoutes.Count -gt 0) {
        $output += ($ipRoutes | Format-Table -AutoSize | Out-String -Width 300)
    } else {
        $output += "No routes collected."
        $output += ""
    }

    if ($iscsiActive) {
        $output += "=== iSCSI SESSIONS ==="
        if ($iscsiSessions.Count -gt 0) {
            $output += ($iscsiSessions | Format-Table -AutoSize | Out-String -Width 300)
        } else {
            $output += "iSCSI Initiator service is running but no active sessions."
            $output += ""
        }
        $output += "=== iSCSI CONNECTIONS ==="
        if ($iscsiConnections.Count -gt 0) {
            $output += ($iscsiConnections | Format-Table -AutoSize | Out-String -Width 300)
        } else {
            $output += "No active iSCSI connections."
            $output += ""
        }
    }

    if ($hvInstalled) {
        $output += "=== HYPER-V VMs ==="
        $output += ($vms | Select-Object Name, State, Generation, ProcessorCount, @{N='MemoryGB';E={[math]::Round($_.MemoryAssigned/1GB,1)}}, @{N='DynamicMemory';E={$_.DynamicMemoryEnabled}}, Version, Status | Format-Table -AutoSize | Out-String -Width 300)
        $output += "=== HYPER-V VIRTUAL SWITCHES ==="
        $output += ($vSwitches | Select-Object Name, SwitchType, NetAdapterInterfaceDescription | Format-Table -AutoSize | Out-String -Width 300)
    }

    if ($isDC -and $fsmoOutput) {
        $output += "=== FSMO ROLES ==="
        $output += $fsmoOutput
        $output += ""
    }

    if ($dhcpInstalled -and $dhcpV4Scopes.Count -gt 0) {
        $output += "=== DHCP SCOPES (IPv4) ==="
        $output += ($dhcpV4Scopes | Format-Table -AutoSize | Out-String -Width 300)
    }

    if ($isDomainJoined -and $gpApplied) {
        $output += "=== APPLIED GROUP POLICY (Computer) ==="
        $output += $gpApplied
        $output += ""
    }

    $output += "=== CUSTOM SCHEDULED TASKS ==="
    if ($customTasks.Count -gt 0) {
        $output += ($customTasks | Format-Table -AutoSize | Out-String -Width 300)
    } else {
        $output += "No custom scheduled tasks found."
        $output += ""
    }

    $output += "=== INSTALLED SOFTWARE ==="
    $output += ($software | Format-Table -AutoSize | Out-String -Width 300)

    $output += "=== RUNNING SERVICES ==="
    $output += ($services | Format-Table -AutoSize | Out-String -Width 300)

    $output += "=== SHARED FOLDERS ==="
    $output += ($shares | Select-Object Name, Path, Description | Format-Table -AutoSize | Out-String -Width 300)

    $output += "=== FIREWALL PROFILE STATUS ==="
    $output += ($fwProfiles | Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction | Format-Table -AutoSize | Out-String -Width 300)

    $output += "=== CUSTOM FIREWALL RULES (Non-Windows) ==="
    $output += ($customFwRules | Format-Table -AutoSize | Out-String -Width 300)

    $output += "=== OS ==="
    $output += ($os | Select-Object Caption, Version, BuildNumber, OSArchitecture, LastBootUpTime | Format-List | Out-String)

    $output += "=== ROLES & FEATURES ==="
    if ($roles.Count -gt 0) {
        $output += ($roles | Format-Table -AutoSize | Out-String -Width 300)
    } else {
        $output += "Get-WindowsFeature not available (workstation OS)."
        $output += ""
    }

    $output | Out-File -FilePath $outFile -Encoding UTF8

    # ════════════════════════════════════════════════════════════════════════
    # HTML OUTPUT
    # ════════════════════════════════════════════════════════════════════════

    function ConvertTo-HtmlTable {
        param([array]$Data, [string[]]$Properties)
        if (!$Data -or $Data.Count -eq 0) { return "<p class='empty'>No data found.</p>" }
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.Append("<table><thead><tr>")
        foreach ($prop in $Properties) { [void]$sb.Append("<th>$prop</th>") }
        [void]$sb.Append("</tr></thead><tbody>")
        foreach ($row in $Data) {
            [void]$sb.Append("<tr>")
            foreach ($prop in $Properties) {
                $val = $row.$prop
                if ($null -eq $val) { $val = "" }
                [void]$sb.Append("<td>$([System.Web.HttpUtility]::HtmlEncode($val.ToString()))</td>")
            }
            [void]$sb.Append("</tr>")
        }
        [void]$sb.Append("</tbody></table>")
        return $sb.ToString()
    }

    function ConvertTo-HtmlPre {
        param([string]$Text)
        if (!$Text) { return "<p class='empty'>No data collected.</p>" }
        return "<pre class='preblock'>$([System.Web.HttpUtility]::HtmlEncode($Text))</pre>"
    }

    Add-Type -AssemblyName System.Web

    $typeTag = if ($machineType -eq "HVS") { "PHYSICAL HOST" } else { "VIRTUAL MACHINE" }
    $typeColor = if ($machineType -eq "HVS") { "#4fc3f7" } else { "#81c784" }

    $memRows = $memSticks | Select-Object BankLabel, @{N='CapacityGB';E={[math]::Round($_.Capacity/1GB,1)}}, Speed, PartNumber, Manufacturer
    $diskRows = $disks | Select-Object Model, @{N='SizeGB';E={[math]::Round($_.Size/1GB,1)}}, MediaType, InterfaceType, SerialNumber
    $volRows = $volumes | Select-Object DriveLetter, FileSystemLabel, @{N='SizeGB';E={[math]::Round($_.Size/1GB,1)}}, @{N='FreeGB';E={[math]::Round($_.SizeRemaining/1GB,1)}}, HealthStatus
    $adapterRows = $netAdapters | Select-Object Name, Status, InterfaceDescription, MacAddress, LinkSpeed
    $ipRows = $ipConfig | Select-Object InterfaceAlias, IPAddress, PrefixLength
    $vmRows = $vms | Select-Object Name, State, Generation, ProcessorCount, @{N='MemoryGB';E={[math]::Round($_.MemoryAssigned/1GB,1)}}, @{N='DynamicMemory';E={$_.DynamicMemoryEnabled}}, Version, Status
    $vSwitchRows = $vSwitches | Select-Object Name, SwitchType, NetAdapterInterfaceDescription
    $shareRows = $shares | Select-Object Name, Path, Description
    $fwProfileRows = $fwProfiles | Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction

    # Build nav dynamically
    $navItems = [System.Collections.ArrayList]::new()
    [void]$navItems.Add(@{id='overview';label='Overview'})
    [void]$navItems.Add(@{id='baseboard';label='Baseboard / BIOS'})
    [void]$navItems.Add(@{id='memory';label='Memory'})
    [void]$navItems.Add(@{id='disks';label='Physical Disks'})
    [void]$navItems.Add(@{id='volumes';label='Storage Volumes'})
    [void]$navItems.Add(@{id='network';label='Network'})
    [void]$navItems.Add(@{id='ip';label='IP Configuration'})
    [void]$navItems.Add(@{id='routes';label='IP Routes'})
    if ($iscsiActive) {
        [void]$navItems.Add(@{id='iscsi';label='iSCSI'})
    }
    if ($hvInstalled) {
        [void]$navItems.Add(@{id='vms';label='Hyper-V VMs'})
        [void]$navItems.Add(@{id='vswitches';label='Virtual Switches'})
    }
    if ($isDC -and $fsmoOutput) { [void]$navItems.Add(@{id='fsmo';label='FSMO Roles'}) }
    if ($dhcpInstalled -and $dhcpV4Scopes.Count -gt 0) { [void]$navItems.Add(@{id='dhcp';label='DHCP Scopes'}) }
    if ($isDomainJoined -and $gpApplied) { [void]$navItems.Add(@{id='gpo';label='Group Policy'}) }
    [void]$navItems.Add(@{id='tasks';label='Scheduled Tasks'})
    [void]$navItems.Add(@{id='software';label='Installed Software'})
    [void]$navItems.Add(@{id='services';label='Running Services'})
    [void]$navItems.Add(@{id='shares';label='Shared Folders'})
    [void]$navItems.Add(@{id='firewall';label='Firewall'})
    [void]$navItems.Add(@{id='fwrules';label='Custom FW Rules'})
    [void]$navItems.Add(@{id='os';label='OS'})
    [void]$navItems.Add(@{id='roles';label='Roles & Features'})

    $navHtml = ""
    foreach ($item in $navItems) {
        $navHtml += "<a href='#$($item.id)' class='nav-link'>$($item.label)</a>`n"
    }

    # Build conditional HTML sections
    $iscsiSectionHtml = ""
    if ($iscsiActive) {
        $sessTable = if ($iscsiSessions.Count -gt 0) {
            ConvertTo-HtmlTable -Data $iscsiSessions -Properties 'TargetNodeAddress','IsConnected','IsPersistent','InitiatorPortal','TargetPortal'
        } else { "<p class='empty'>iSCSI Initiator running but no active sessions.</p>" }
        $connTable = if ($iscsiConnections.Count -gt 0) {
            ConvertTo-HtmlTable -Data $iscsiConnections -Properties 'ConnectionIdentifier','InitiatorAddress','TargetAddress','InitiatorPortNumber','TargetPortNumber'
        } else { "<p class='empty'>No active iSCSI connections.</p>" }
        $iscsiSectionHtml = @"
<section id="iscsi">
  <h2>iSCSI</h2>
  <h3>Sessions</h3>
  $sessTable
  <h3 style="margin-top:20px;">Connections</h3>
  $connTable
</section>
"@
    }

    $hvSectionsHtml = ""
    if ($hvInstalled) {
        $hvSectionsHtml = @"
<section id="vms">
  <h2>Hyper-V Virtual Machines</h2>
  $(ConvertTo-HtmlTable -Data $vmRows -Properties 'Name','State','Generation','ProcessorCount','MemoryGB','DynamicMemory','Version','Status')
</section>

<section id="vswitches">
  <h2>Hyper-V Virtual Switches</h2>
  $(ConvertTo-HtmlTable -Data $vSwitchRows -Properties 'Name','SwitchType','NetAdapterInterfaceDescription')
</section>
"@
    }

    $fsmoSectionHtml = ""
    if ($isDC -and $fsmoOutput) {
        $fsmoSectionHtml = @"
<section id="fsmo">
  <h2>FSMO Roles</h2>
  $(ConvertTo-HtmlPre -Text $fsmoOutput)
</section>
"@
    }

    $dhcpSectionHtml = ""
    if ($dhcpInstalled -and $dhcpV4Scopes.Count -gt 0) {
        $dhcpSectionHtml = @"
<section id="dhcp">
  <h2>DHCP Scopes (IPv4)</h2>
  $(ConvertTo-HtmlTable -Data $dhcpV4Scopes -Properties 'ScopeId','Name','SubnetMask','StartRange','EndRange','State','LeaseDuration')
</section>
"@
    }

    $gpoSectionHtml = ""
    if ($isDomainJoined -and $gpApplied) {
        $gpoSectionHtml = @"
<section id="gpo">
  <h2>Applied Group Policy (Computer)</h2>
  $(ConvertTo-HtmlPre -Text $gpApplied)
</section>
"@
    }

    $tasksSectionHtml = @"
<section id="tasks">
  <h2>Custom Scheduled Tasks</h2>
  $(if ($customTasks.Count -gt 0) {
      ConvertTo-HtmlTable -Data $customTasks -Properties 'TaskName','TaskPath','State','Author','NextRun','LastRun','LastResult'
  } else { "<p class='empty'>No custom scheduled tasks found.</p>" })
</section>
"@

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>$($cs.Name) — Inventory Report</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  html { scroll-behavior: smooth; scroll-padding-top: 16px; }
  body { background: #0d1117; color: #c9d1d9; font-family: 'Segoe UI', Consolas, monospace; line-height: 1.5; }

  .sidebar { position: fixed; top: 0; left: 0; width: 200px; height: 100vh; background: #010409; border-right: 1px solid #21262d; padding: 16px 0; overflow-y: auto; z-index: 10; }
  .sidebar .logo { padding: 8px 16px 20px; font-size: 13px; font-weight: 700; color: #58a6ff; letter-spacing: 1px; border-bottom: 1px solid #21262d; margin-bottom: 8px; }
  .nav-link { display: block; padding: 6px 16px; font-size: 12px; color: #8b949e; text-decoration: none; border-left: 2px solid transparent; transition: all 0.15s ease; }
  .nav-link:hover { color: #c9d1d9; background: #161b22; }
  .nav-link.active { color: #58a6ff; border-left-color: #58a6ff; background: #161b22; }

  .main { margin-left: 200px; padding: 32px 40px; max-width: 1200px; }

  .header { border-bottom: 2px solid #30363d; padding-bottom: 20px; margin-bottom: 32px; }
  .header h1 { font-size: 28px; color: #e6edf3; font-weight: 600; letter-spacing: -0.5px; }
  .header .meta { display: flex; gap: 24px; margin-top: 8px; font-size: 13px; color: #8b949e; flex-wrap: wrap; }
  .tag { display: inline-block; padding: 2px 10px; border-radius: 3px; font-size: 12px; font-weight: 600; letter-spacing: 0.5px; }

  .summary-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; margin-bottom: 32px; }
  .summary-card { background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 16px; }
  .summary-card .label { font-size: 11px; color: #8b949e; text-transform: uppercase; letter-spacing: 0.5px; }
  .summary-card .value { font-size: 20px; color: #e6edf3; font-weight: 600; margin-top: 4px; }
  .summary-card .detail { font-size: 12px; color: #8b949e; margin-top: 2px; }

  section { margin-bottom: 28px; }
  section h2 { font-size: 15px; color: #8b949e; text-transform: uppercase; letter-spacing: 1px; margin-bottom: 12px; padding-bottom: 6px; border-bottom: 1px solid #21262d; }
  section h3 { font-size: 13px; color: #8b949e; margin-bottom: 8px; }

  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  thead th { background: #161b22; color: #8b949e; text-align: left; padding: 8px 12px; font-weight: 600; text-transform: uppercase; font-size: 11px; letter-spacing: 0.5px; border-bottom: 2px solid #30363d; position: sticky; top: 0; }
  tbody td { padding: 7px 12px; border-bottom: 1px solid #21262d; color: #c9d1d9; white-space: nowrap; }
  tbody tr:hover { background: #161b22; }

  .kv-grid { display: grid; grid-template-columns: 160px 1fr; gap: 4px 16px; font-size: 13px; }
  .kv-grid .k { color: #8b949e; } .kv-grid .v { color: #e6edf3; }

  .preblock { background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 16px; font-size: 12px; color: #c9d1d9; overflow-x: auto; white-space: pre-wrap; word-wrap: break-word; line-height: 1.6; }
  .empty { color: #484f58; font-style: italic; font-size: 13px; }
  .footer { margin-top: 40px; padding-top: 16px; border-top: 1px solid #21262d; font-size: 11px; color: #484f58; }

  @media print {
    .sidebar { display: none; }
    .main { margin-left: 0; }
    body { background: #fff; color: #000; }
    thead th { background: #f0f0f0; color: #000; }
    tbody td { color: #000; border-color: #ccc; }
    .summary-card { border-color: #ccc; }
    .header h1 { color: #000; }
    .preblock { background: #f5f5f5; border-color: #ccc; color: #000; }
  }
</style>
</head>
<body>

<nav class="sidebar">
  <div class="logo">CBIT INVENTORY</div>
  $navHtml
</nav>

<div class="main">

<div class="header" id="overview">
  <h1>$($cs.Name) <span class="tag" style="background:${typeColor}22;color:${typeColor};margin-left:12px;">$typeTag</span></h1>
  <div class="meta">
    <span>Collected: $collected</span>
    <span>$sysManufacturer — $sysModel</span>
    <span>$($os.Caption)</span>
  </div>
</div>

<div class="summary-grid">
  <div class="summary-card">
    <div class="label">CPU</div>
    <div class="value">$($cpus[0].NumberOfCores)C / $($cpus[0].NumberOfLogicalProcessors)T</div>
    <div class="detail">$($cpus[0].Name)</div>
  </div>
  <div class="summary-card">
    <div class="label">Memory</div>
    <div class="value">${totalGB} GB</div>
    <div class="detail">$($memSticks.Count) DIMMs @ $($memSticks[0].Speed) MHz</div>
  </div>
  <div class="summary-card">
    <div class="label">OS</div>
    <div class="value">$($os.Caption -replace 'Microsoft Windows ','')</div>
    <div class="detail">Build $($os.BuildNumber)</div>
  </div>
  <div class="summary-card">
    <div class="label">Domain</div>
    <div class="value">$($cs.Domain)</div>
    <div class="detail">$domainRole</div>
  </div>
  $(if ($hvInstalled) { @"
  <div class="summary-card">
    <div class="label">Hyper-V VMs</div>
    <div class="value">$($vms.Count)</div>
    <div class="detail">$(($vms | Where-Object State -eq 'Running').Count) running</div>
  </div>
"@
  })
  $(if ($iscsiActive -and $iscsiSessions.Count -gt 0) { @"
  <div class="summary-card">
    <div class="label">iSCSI</div>
    <div class="value">$($iscsiSessions.Count) sessions</div>
    <div class="detail">$(($iscsiSessions | Where-Object IsConnected -eq `$true).Count) connected</div>
  </div>
"@
  })
</div>

<section id="baseboard">
  <h2>Baseboard / BIOS</h2>
  <div class="kv-grid">
    <span class="k">Board</span><span class="v">$($bb.Manufacturer) $($bb.Product)</span>
    <span class="k">Board Serial</span><span class="v">$($bb.SerialNumber)</span>
    <span class="k">BIOS Version</span><span class="v">$($bios.SMBIOSBIOSVersion)</span>
    <span class="k">BIOS Date</span><span class="v">$($bios.ReleaseDate)</span>
    <span class="k">System Serial</span><span class="v">$($bios.SerialNumber)</span>
  </div>
</section>

<section id="memory">
  <h2>Memory Detail</h2>
  $(ConvertTo-HtmlTable -Data $memRows -Properties 'BankLabel','CapacityGB','Speed','PartNumber','Manufacturer')
</section>

<section id="disks">
  <h2>Physical Disks</h2>
  $(ConvertTo-HtmlTable -Data $diskRows -Properties 'Model','SizeGB','MediaType','InterfaceType','SerialNumber')
</section>

<section id="volumes">
  <h2>Storage Volumes</h2>
  $(ConvertTo-HtmlTable -Data $volRows -Properties 'DriveLetter','FileSystemLabel','SizeGB','FreeGB','HealthStatus')
</section>

<section id="network">
  <h2>Network Adapters</h2>
  $(ConvertTo-HtmlTable -Data $adapterRows -Properties 'Name','Status','InterfaceDescription','MacAddress','LinkSpeed')
</section>

<section id="ip">
  <h2>IP Configuration</h2>
  $(ConvertTo-HtmlTable -Data $ipRows -Properties 'InterfaceAlias','IPAddress','PrefixLength')
</section>

<section id="routes">
  <h2>IP Routes</h2>
  $(ConvertTo-HtmlTable -Data $ipRoutes -Properties 'DestinationPrefix','NextHop','RouteMetric','InterfaceAlias','Type')
</section>

$iscsiSectionHtml

$hvSectionsHtml

$fsmoSectionHtml

$dhcpSectionHtml

$gpoSectionHtml

$tasksSectionHtml

<section id="software">
  <h2>Installed Software</h2>
  $(ConvertTo-HtmlTable -Data $software -Properties 'DisplayName','DisplayVersion','Publisher','InstallDate')
</section>

<section id="services">
  <h2>Running Services</h2>
  $(ConvertTo-HtmlTable -Data $services -Properties 'Name','DisplayName','StartType')
</section>

<section id="shares">
  <h2>Shared Folders</h2>
  $(ConvertTo-HtmlTable -Data $shareRows -Properties 'Name','Path','Description')
</section>

<section id="firewall">
  <h2>Firewall Profile Status</h2>
  $(ConvertTo-HtmlTable -Data $fwProfileRows -Properties 'Name','Enabled','DefaultInboundAction','DefaultOutboundAction')
</section>

<section id="fwrules">
  <h2>Custom Firewall Rules (Non-Windows)</h2>
  $(ConvertTo-HtmlTable -Data $customFwRules -Properties 'DisplayName','Direction','Action','Profile')
</section>

<section id="os">
  <h2>Operating System</h2>
  <div class="kv-grid">
    <span class="k">OS</span><span class="v">$($os.Caption)</span>
    <span class="k">Version</span><span class="v">$($os.Version)</span>
    <span class="k">Build</span><span class="v">$($os.BuildNumber)</span>
    <span class="k">Architecture</span><span class="v">$($os.OSArchitecture)</span>
    <span class="k">Last Boot</span><span class="v">$($os.LastBootUpTime)</span>
  </div>
</section>

<section id="roles">
  <h2>Roles &amp; Features</h2>
  $(ConvertTo-HtmlTable -Data $roles -Properties 'Name','DisplayName')
</section>

<div class="footer">
  Generated by CBIT Server Inventory Script &mdash; $collected
</div>

</div>

<script>
  var sections = document.querySelectorAll('section[id], .header[id]');
  var navLinks = document.querySelectorAll('.nav-link');
  var observer = new IntersectionObserver(function(entries) {
    entries.forEach(function(entry) {
      if (entry.isIntersecting) {
        navLinks.forEach(function(link) { link.classList.remove('active'); });
        var active = document.querySelector('.nav-link[href="#' + entry.target.id + '"]');
        if (active) active.classList.add('active');
      }
    });
  }, { rootMargin: '-10% 0px -80% 0px' });
  sections.forEach(function(s) { observer.observe(s); });
</script>

</body>
</html>
"@

    $html | Out-File -FilePath $htmlFile -Encoding UTF8

    Write-Color "$global:CbitCheck Inventory complete" 'Good'
    Write-Color "   Text: $outFile" 'Detail'
    Write-Color "   HTML: $htmlFile" 'Detail'
}
Set-Alias -Name inventory -Value Invoke-ServerInventory -Scope Global
Set-Alias -Name serverinv -Value Invoke-ServerInventory -Scope Global
