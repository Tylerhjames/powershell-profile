function Test-ConnectionDoctor {
    <#
    .SYNOPSIS
    Read-only destination, route, TCP and DNS comparison diagnostics.
    .DESCRIPTION
    No login, repairs, configuration changes, file exports or automatic clipboard
    writes. Network probes may appear in destination/resolver logs. Additional
    DNS servers are opt-in. TCP success does not establish application health.
    .EXAMPLE
    Test-ConnectionDoctor -Target server.example -Port 22 -NoPrompt -PassThru
    #>
    [CmdletBinding()]
    param(
        [string]$Target,
        [ValidateRange(0,65535)][int]$Port=0,
        [string]$ComparisonServer,
        [ValidateRange(250,10000)][int]$TimeoutMs=3000,
        [switch]$NoPrompt,
        [switch]$PassThru
    )
    $ErrorActionPreference='Stop'

    function Write-CdColor {
        param([string]$Text,[string]$Tone='Detail')
        if (Get-Command Write-Color -ErrorAction SilentlyContinue) { Write-Color $Text $Tone }
        else { $colors=@{Header='Gray';Good='DarkGreen';Warn='DarkYellow';Bad='DarkRed';Detail='DarkGray'}; Write-Host $Text -ForegroundColor $colors[$Tone] }
    }
    function Write-CdSection {
        param([string]$Title)
        Write-CdColor "`n  ┌─ $Title $('─' * [Math]::Max(0,48-$Title.Length))" Header
    }
    function Select-CdService {
        param([int]$SuggestedPort=443,[switch]$Numbered)
        $options=@(
            @{Name='HTTPS';Port=443;Hint='Secure website / web interface'},
            @{Name='HTTP';Port=80;Hint='Website / device web interface'},
            @{Name='SSH';Port=22;Hint='Linux server / switch console'},
            @{Name='RDP';Port=3389;Hint='Windows Remote Desktop'},
            @{Name='SMB';Port=445;Hint='Windows file share'},
            @{Name='Custom TCP port';Port=0;Hint='Enter a port from 1 to 65535'}
        )
        $selected=0
        for ($i=0;$i -lt $options.Count;$i++) { if ($options[$i].Port -eq $SuggestedPort) { $selected=$i } }
        if ($SuggestedPort -notin $options.Port) { $selected=5 }
        Write-CdSection 'SELECT SERVICE'
        $useArrows=-not ($Numbered -or [Console]::IsInputRedirected -or [Console]::IsOutputRedirected)
        if ($useArrows -and [Console]::WindowWidth -lt 64) { $useArrows=$false }
        if ($useArrows) { Write-CdColor '  ↑ ↓ select  •  Enter confirm  •  1–6 shortcut  •  Q back' }
        # Reserve rows first so scrolling does not invalidate redraw coordinates.
        if ($useArrows) { for ($blank=0;$blank -lt 7;$blank++) { Write-Host '' } }
        $row=if ($useArrows) { [Console]::CursorTop-7 } else { 0 }
        while ($true) {
            if ($useArrows) { [Console]::SetCursorPosition(0,$row) }
            for ($i=0;$i -lt $options.Count;$i++) {
                $marker=if ($i -eq $selected) {'›'} else {' '}
                $portText=if ($options[$i].Port) { "TCP $($options[$i].Port)" } else { 'TCP 1–65535' }
                $tone=if ($i -eq $selected) {'Good'} else {'Detail'}
                Write-CdColor ("  {0} [{1}] {2,-17} {3,-12}" -f $marker,($i+1),$options[$i].Name,$portText) $tone
            }
            Write-CdColor '    [Q] Return to menu...'
            if ($useArrows) {
                $key=[Console]::ReadKey($true)
                if ($key.Key -eq 'UpArrow') { $selected=($selected+$options.Count-1)%$options.Count; continue }
                if ($key.Key -eq 'DownArrow') { $selected=($selected+1)%$options.Count; continue }
                if ($key.Key -eq 'Escape' -or $key.KeyChar -match '^[Qq]$') { return $null }
                if ($key.Key -eq 'Enter') { $choice=[string]($selected+1) } else { $choice=[string]$key.KeyChar }
            } else { $choice=Read-Host "Select service [Enter: $($options[$selected].Name)]"; if (-not $choice) { $choice=[string]($selected+1) } }
            if ($choice -match '^[Qq]$') { return $null }
            if ($choice -notmatch '^[1-6]$') { if (-not $useArrows) { Write-CdColor '  Choose 1–6 or Q.' Warn }; continue }
            $item=$options[[int]$choice-1]
            if ($item.Port) { return $item.Port }
            do {
                $default=if ($SuggestedPort -notin @(22,80,443,445,3389)) { $SuggestedPort } else { 0 }
                $entry=Read-Host "Custom TCP port$(if ($default) { " [$default]" }) (Q to go back)"
                if ($entry -match '^[Qq]$') { break }
                if (-not $entry -and $default) { return $default }
                $custom=0
                if ([int]::TryParse($entry,[ref]$custom) -and $custom -ge 1 -and $custom -le 65535) { return $custom }
                Write-CdColor '  Enter a port between 1 and 65535.' Warn
            } while ($true)
            # A custom-port prompt has moved the cursor; redraw below it.
            if ($useArrows) { for ($blank=0;$blank -lt 7;$blank++) { Write-Host '' }; $row=[Console]::CursorTop-7 }
        }
    }

    function New-CdClipboardHtml {
        param([string]$Text)
        $palette=@{Header='#b2b2aa';Good='#8fa880';Warn='#b08946';Bad='#963c3c';Detail='#808078'}
        $formatted=foreach ($line in ($Text -split '\r?\n')) {
            $tone=if ($line -match '^✓|^  ✓') {'Good'} elseif ($line -match '^⚠|^  ⚠') {'Warn'} elseif ($line -match '^✗|^  ✗') {'Bad'} elseif ($line -match '^🩺|^🌐|^🔎|^📋|^─') {'Header'} else {'Detail'}
            '<div style="color:'+ $palette[$tone] +';">'+[Net.WebUtility]::HtmlEncode($line)+'</div>'
        }
        $fragment='<div style="background-color:#20201f;padding:16px;font-family:Consolas,monospace;font-size:13px;white-space:pre-wrap;">'+($formatted -join '')+'</div>'
        $prefix='<html><body><!--StartFragment-->'
        $suffix='<!--EndFragment--></body></html>'
        $template="Version:0.9`r`nStartHTML:{0:D10}`r`nEndHTML:{1:D10}`r`nStartFragment:{2:D10}`r`nEndFragment:{3:D10}`r`n"
        $utf8=[Text.Encoding]::UTF8
        $start=$utf8.GetByteCount(($template -f 0,0,0,0))
        $startFragment=$start+$utf8.GetByteCount($prefix)
        $endFragment=$startFragment+$utf8.GetByteCount($fragment)
        ($template -f $start,($endFragment+$utf8.GetByteCount($suffix)),$startFragment,$endFragment)+$prefix+$fragment+$suffix
    }
    function Copy-CdReport {
        param([string]$Text)
        # Windows clipboard HTML + UnicodeText, on an STA runspace. No temporary
        # files, browser, network request, or raw ANSI escapes in the clipboard.
        $html=New-CdClipboardHtml $Text
        $runspace=[RunspaceFactory]::CreateRunspace()
        $runspace.ApartmentState='STA'; $runspace.ThreadOptions='ReuseThread'
        $ps=[powershell]::Create()
        try {
            $runspace.Open(); $ps.Runspace=$runspace
            $null=$ps.AddScript({
                param($text,$html)
                $ErrorActionPreference='Stop'
                Add-Type -AssemblyName System.Windows.Forms
                $data=[Windows.Forms.DataObject]::new()
                $data.SetData([Windows.Forms.DataFormats]::UnicodeText,$text)
                $data.SetData([Windows.Forms.DataFormats]::Html,$html)
                [Windows.Forms.Clipboard]::SetDataObject($data,$true,5,100)
            }).AddArgument($Text).AddArgument($html)
            $null=$ps.Invoke()
            if ($ps.HadErrors) { throw ($ps.Streams.Error -join '; ') }
        } finally { $ps.Dispose(); $runspace.Dispose() }
    }

    function ConvertTo-CdTarget {
        param([string]$Value)
        $value=$Value.Trim()
        if ($value -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
            $uri=$null
            if (-not [uri]::TryCreate($value,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -notin @('http','https') -or $uri.UserInfo) { throw 'Use a hostname/IP or HTTP(S) URL without credentials.' }
            $urlIp=$null
            if ([Net.IPAddress]::TryParse($uri.DnsSafeHost.Trim('[',']'),[ref]$urlIp) -and $urlIp.AddressFamily -ne 'InterNetwork') { throw 'Connection Doctor uses IPv4 only.' }
            return [pscustomobject]@{Name=$uri.DnsSafeHost.Trim('[',']'); UrlPort=$uri.Port}
        }
        $ip=$null
        if ([Net.IPAddress]::TryParse($value.Trim('[',']'),[ref]$ip)) { if ($ip.AddressFamily -ne 'InterNetwork') { throw 'Connection Doctor uses IPv4 only.' }; return [pscustomobject]@{Name=$ip.ToString();UrlPort=0} }
        if ($value.Length -gt 253 -or $value -notmatch '^(?=.{1,253}$)[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?\.?$' -or $value.Contains('..')) { throw 'Enter a hostname or IP, not a command, username, or host:port.' }
        [pscustomobject]@{Name=$value;UrlPort=0}
    }
    function Resolve-CdSystem {
        param([string]$Name,[int]$WaitMs)
        $ip=$null
        if ([Net.IPAddress]::TryParse($Name,[ref]$ip)) { return [pscustomobject]@{Status='Literal IP (DNS skipped)';Addresses=@($ip.ToString());Error=''} }
        try {
            $task=[Net.Dns]::GetHostAddressesAsync($Name,[Net.Sockets.AddressFamily]::InterNetwork)
            if (-not $task.Wait($WaitMs)) { return [pscustomobject]@{Status='Timed out';Addresses=@();Error='System resolver exceeded wait budget; background lookup may finish later.'} }
            $addresses=@($task.Result | Where-Object AddressFamily -eq 'InterNetwork' | ForEach-Object { $_.ToString() } | Select-Object -Unique)
            [pscustomobject]@{Status= $(if ($addresses.Count) {'Resolved'} else {'No addresses'});Addresses=$addresses;Error=''}
        } catch { [pscustomobject]@{Status='Failed';Addresses=@();Error=$_.Exception.GetBaseException().Message} }
    }
    function Get-CdRoute {
        param([string]$Address)
        try {
            $items=@(Find-NetRoute -RemoteIPAddress $Address -ErrorAction Stop)
            $source=$items | Where-Object { $_.PSObject.Properties['IPAddress'] } | Select-Object -First 1
            $route=$items | Where-Object { $_.PSObject.Properties['DestinationPrefix'] } | Select-Object -First 1
            if (-not $source -or -not $route) { throw 'No complete route/source result.' }
            [pscustomobject]@{Status='Available'; Interface=$source.InterfaceAlias; Source=$source.IPAddress; Prefix=$route.DestinationPrefix; NextHop=$route.NextHop; Error=''}
        } catch { [pscustomobject]@{Status='Unavailable';Interface='';Source='';Prefix='';NextHop='';Error=$_.Exception.Message} }
    }
    function Test-CdTcp {
        param([string]$Address,[int]$ServicePort,[int]$WaitMs)
        $ip=[Net.IPAddress]::Parse($Address)
        $client=[Net.Sockets.TcpClient]::new($ip.AddressFamily)
        $timer=[Diagnostics.Stopwatch]::StartNew()
        try {
            $task=$client.ConnectAsync($ip,$ServicePort)
            if (-not $task.Wait($WaitMs)) { return [pscustomobject]@{Status='Timed out';Milliseconds=$timer.ElapsedMilliseconds;LocalEndpoint='';Error='No TCP connection within the wait budget.'} }
            [pscustomobject]@{Status='Connected';Milliseconds=$timer.ElapsedMilliseconds;LocalEndpoint="$($client.Client.LocalEndPoint)";Error=''}
        } catch {
            $errorDetail=$_.Exception.GetBaseException()
            $status=if ($errorDetail -is [Net.Sockets.SocketException] -and $errorDetail.SocketErrorCode -eq 'ConnectionRefused') { 'Refused' } else { 'Failed' }
            [pscustomobject]@{Status=$status;Milliseconds=$timer.ElapsedMilliseconds;LocalEndpoint='';Error=$errorDetail.Message}
        } finally { $timer.Stop(); $client.Dispose() }
    }
    function Get-CdResolvers {
        $up=@(Get-NetAdapter -ErrorAction Stop | Where-Object Status -eq 'Up' | ForEach-Object InterfaceIndex)
        @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.InterfaceIndex -in $up } | ForEach-Object ServerAddresses | Where-Object { $parsed=$null; [Net.IPAddress]::TryParse($_,[ref]$parsed) -and $parsed.AddressFamily -eq 'InterNetwork' } | Select-Object -Unique)
    }
    function Resolve-CdComparison {
        param([string]$Name,[string]$Server)
        try {
            $records=@(Resolve-DnsName -Name $Name -Server $Server -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop)
            $answers=@($records | Where-Object { $_.Type -eq 'A' -and $_.PSObject.Properties['IPAddress'] -and $_.IPAddress } | ForEach-Object IPAddress | Sort-Object -Unique)
            $details=@(foreach ($record in $records) {
                if ($record.Type -in @('A','CNAME')) {
                    $value=if ($record.Type -eq 'CNAME') { $record.NameHost } else { $record.IPAddress }
                    "$($record.Type) $value (TTL $($record.TTL))"
                }
            })
            [pscustomobject]@{Server=$Server;Status=$(if ($answers.Count) {'Answered'} else {'No address records'});Addresses=$answers;Details=$details;Error=''}
        } catch { [pscustomobject]@{Server=$Server;Status='Query failed';Addresses=@();Details=@();Error=$_.Exception.Message} }
    }
    function Get-CdDnsFinding {
        param([object[]]$Queries)
        $success=@($Queries | Where-Object Status -eq 'Answered')
        if ($success.Count -eq 1) { return 'One resolver answered; a second is needed to compare.' }
        if (-not $success.Count) { return 'No successful DNS answers to compare.' }
        $sets=@($success | ForEach-Object { (@($_.Addresses | Sort-Object -Unique) -join ',').ToLowerInvariant() } | Select-Object -Unique)
        if ($sets.Count -gt 1) { return 'Resolver answers differ. Split DNS, caching or load balancing may explain this; not proof of misconfiguration.' }
        'Successful resolvers returned matching address sets.'
    }

    Write-CdColor "`n  ═══════════════════════════════════════════════════════" Header
    Write-CdColor '    🩺  CONNECTION DOCTOR' Header
    Write-CdColor '    IPv4 connectivity • DNS comparison • Ticket summary' Detail
    Write-CdColor "  ═══════════════════════════════════════════════════════`n" Header
    if (-not $Target) {
        if ($NoPrompt) { throw 'Supply -Target with -NoPrompt.' }
        Write-CdColor '  Enter a hostname, IPv4 address or web URL. Enter alone returns to TECH.' Detail
        $Target=Read-Host 'Target'
        if (-not $Target) { if (Get-Command Complete-TechMenuReturn -ErrorAction SilentlyContinue) { Complete-TechMenuReturn }; return }
    }
    $destination=ConvertTo-CdTarget $Target
    if (-not $Port) {
        if ($NoPrompt) { $Port=if ($destination.UrlPort) {$destination.UrlPort} else {443} }
        else {
            $selection=Select-CdService -SuggestedPort $(if ($destination.UrlPort) {$destination.UrlPort} else {443})
            if ($null -eq $selection) { if (Get-Command Complete-TechMenuReturn -ErrorAction SilentlyContinue) { Complete-TechMenuReturn }; return }
            $Port=$selection
        }
    }
    $literal=$null
    $isIp=[Net.IPAddress]::TryParse($destination.Name,[ref]$literal)
    if (-not $isIp -and -not $NoPrompt -and -not $ComparisonServer) {
        Write-CdSection 'DNS COMPARISON'
        Write-CdColor '  Uses the configured IPv4 DNS servers on this computer.'
        Write-CdColor '  Optional: compare another resolver. It will receive the target name.'
        $ComparisonServer=Read-Host 'Additional DNS server IPv4 [Enter to skip]'
    }
    if ($ComparisonServer) {
        $serverIp=$null
        if (-not [Net.IPAddress]::TryParse($ComparisonServer,[ref]$serverIp) -or $serverIp.AddressFamily -ne 'InterNetwork') { throw 'Additional DNS server must be an IPv4 address.' }
        $ComparisonServer=$serverIp.ToString()
    }
    $notes=[Collections.Generic.List[string]]::new()
    Write-CdColor "`n  Checking $($destination.Name) · TCP $Port ..." Header
    $system=Resolve-CdSystem $destination.Name $TimeoutMs
    $probes=@(foreach ($address in @($system.Addresses | Select-Object -First 4)) {
        Write-CdColor "    → Route and TCP: $address" Detail
        [pscustomobject]@{Address=$address; Route=(Get-CdRoute $address); Tcp=(Test-CdTcp $address $Port $TimeoutMs)}
    })
    if ($system.Addresses.Count -gt 4) { $notes.Add('Only the first 4 system-resolved addresses were probed.') }
    $queries=@()
    if (-not $isIp) {
        $servers=@()
        try { $configured=@(Get-CdResolvers); $servers=@($configured | Select-Object -First 4); if ($configured.Count -gt 4) { $notes.Add('DNS comparison limited to the first 4 configured resolvers.') } }
        catch { $notes.Add("Configured DNS inventory unavailable: $($_.Exception.Message)") }
        if ($ComparisonServer) { $servers=@(@($servers)+$ComparisonServer | Select-Object -Unique) }
        $queries=@(foreach ($server in $servers) { Write-CdColor "    → DNS: $server" Detail; Resolve-CdComparison $destination.Name $server })
        if (-not $servers.Count) { $notes.Add('No DNS resolvers available for comparison.') }
    }
    $dnsFinding=if ($isIp) {'Literal IP: DNS comparison skipped.'} else { Get-CdDnsFinding $queries }
    $connected=@($probes | Where-Object { $_.Tcp.Status -eq 'Connected' })
    if (-not $probes.Count) { $conclusion='No system-resolved address: no TCP test performed. Check name resolution and the intended VPN/DNS configuration.' }
    elseif ($connected.Count -eq $probes.Count) { $conclusion='TCP connected to all tested addresses. This does not verify TLS, login or application health.' }
    elseif ($connected.Count) { $conclusion='Mixed TCP results across addresses. Check routing and service listeners; application health is not verified.' }
    else { $conclusion='No tested TCP connection succeeded. Check the route/VPN, service listener and filtering. A timeout alone cannot identify the cause.' }
    $lines=[Collections.Generic.List[string]]::new()
    $lines.Add('🩺 CONNECTION DOCTOR | IPv4')
    $lines.Add("Time: $([DateTimeOffset]::Now.ToString('yyyy-MM-dd HH:mm:ss zzz')) | Computer: $env:COMPUTERNAME")
    $lines.Add("Target: $($destination.Name) | TCP port: $Port | TCP wait: ${TimeoutMs}ms")
    $lines.Add('──────────────────────────────────────────────────')
    $lines.Add('🔎 NAME RESOLUTION')
    $lines.Add("System resolution: $($system.Status) | $($system.Addresses -join ', ') $($system.Error)")
    $lines.Add('🌐 CONNECTION & NETWORK PATH')
    foreach ($probe in $probes) {
        $icon=if ($probe.Tcp.Status -eq 'Connected') {'✓'} else {'✗'}
        $lines.Add("$icon $($probe.Address): TCP $($probe.Tcp.Status) ($($probe.Tcp.Milliseconds)ms)")
        if ($probe.Tcp.Error) { $lines.Add("  Detail: $($probe.Tcp.Error)") }
        if ($probe.Route.Status -eq 'Available') { $lines.Add("  Selected route: $($probe.Route.Prefix) via $($probe.Route.NextHop); adapter: $($probe.Route.Interface); source: $($probe.Route.Source)") }
        else { $lines.Add("  Route unavailable: $($probe.Route.Error)") }
        if ($probe.Tcp.LocalEndpoint) { $lines.Add("  Actual TCP source: $($probe.Tcp.LocalEndpoint)") }
    }
    $lines.Add('🔎 DNS COMPARISON')
    foreach ($query in $queries) {
        $icon=if ($query.Status -eq 'Answered') {'✓'} else {'⚠'}
        $lines.Add("$icon $($query.Server): $($query.Status)")
        foreach ($detail in $query.Details) { $lines.Add("  $detail") }
        if ($query.Error) { $lines.Add("  Detail: $($query.Error)") }
    }
    $lines.Add($dnsFinding)
    foreach ($note in $notes) { $lines.Add("Note: $note") }
    $lines.Add('📋 ASSESSMENT')
    $lines.Add($conclusion)
    $lines.Add('Read-only probes. No settings changed. Internal names/IPs may be included.')
    $summary=$lines -join [Environment]::NewLine
    $serviceNames=@{22='SSH';80='HTTP';443='HTTPS';3389='RDP';445='SMB'}
    $service=if ($serviceNames.ContainsKey($Port)) {$serviceNames[$Port]} else {'Custom TCP'}
    Write-CdSection 'RESULT'
    Write-CdColor "  Target     $($destination.Name)" Header
    Write-CdColor "  Service    $service · TCP $Port" Header
    if (-not $probes.Count) { Write-CdColor '  ✗ Could not resolve an IPv4 destination' Bad }
    elseif ($connected.Count -eq $probes.Count) { Write-CdColor '  ✓ TCP connection successful' Good }
    elseif ($connected.Count) { Write-CdColor '  ⚠ Some addresses connected; others did not' Warn }
    else { Write-CdColor '  ✗ TCP connection unsuccessful' Bad }
    Write-CdSection 'CONNECTION & ROUTE'
    foreach ($probe in $probes) {
        $tone=if ($probe.Tcp.Status -eq 'Connected') {'Good'} else {'Bad'}
        $icon=if ($probe.Tcp.Status -eq 'Connected') {'✓'} else {'✗'}
        Write-CdColor "  $icon $($probe.Address)   $($probe.Tcp.Status) · $($probe.Tcp.Milliseconds) ms" $tone
        if ($probe.Route.Status -eq 'Available') {
            Write-CdColor "    Adapter    $($probe.Route.Interface)"
            Write-CdColor "    Source     $($probe.Route.Source)"
            Write-CdColor "    Next hop   $($probe.Route.NextHop)"
            Write-CdColor "    Route      $($probe.Route.Prefix)"
        } else { Write-CdColor '    ⚠ Route information unavailable; see Details.' Warn }
    }
    Write-CdSection 'DNS'
    if ($isIp) { Write-CdColor '  — IP address supplied; DNS checks not needed.' }
    else {
        if ($system.Addresses.Count) { Write-CdColor "  ✓ System resolved: $($system.Addresses -join ', ')" Good }
        else { Write-CdColor "  ✗ System resolution: $($system.Status)" Bad }
        foreach ($query in $queries) {
            if ($query.Status -eq 'Answered') { Write-CdColor "  ✓ $($query.Server) → $($query.Addresses -join ', ')" Good }
            else { Write-CdColor "  ⚠ $($query.Server) — $($query.Status); see Details." Warn }
        }
        Write-CdColor "  $dnsFinding" Detail
    }
    Write-CdSection 'ASSESSMENT'
    # Short screen lines; full diagnostic messages remain available in Details.
    if (-not $probes.Count) { Write-CdColor '  Check the hostname, DNS configuration and intended VPN.' Warn }
    elseif ($connected.Count -eq $probes.Count) {
        Write-CdColor '  Network path and TCP listener are reachable.' Good
        Write-CdColor '  TLS, authentication and application health were not tested.'
    } else {
        Write-CdColor '  Check the route/VPN, service listener and filtering.' Warn
        Write-CdColor '  A timeout alone does not identify the cause.'
    }
    foreach ($note in $notes) { Write-CdColor "  ⚠ $note" Warn }
    Write-CdColor "`n  No settings changed. Ticket summary includes internal names/IPs." Detail
    if (-not $NoPrompt) {
        :reportActions while ($true) {
            Write-CdColor "`n  [C] Copy ticket summary   [D] Details" Header
            Write-CdColor ('─' * 63) Detail
            Write-CdColor '[Q] Return to menu...' Header
            switch ((Read-Host 'Choose [Enter: back]').ToUpperInvariant()) {
                'C' {
                    try { Copy-CdReport $summary; Write-CdColor '  ✓ Copied with icons + rich-text colors (plain-text fallback included).' Good }
                    catch { Write-CdColor "  ⚠ Clipboard unavailable: $($_.Exception.Message)" Warn }
                }
                'D' { Write-Host "`n$summary`n" }
                { $_ -in @('','Q') } { if (Get-Command Complete-TechMenuReturn -ErrorAction SilentlyContinue) { Complete-TechMenuReturn }; break reportActions }
                default { Write-CdColor '  Choose C, D or Q.' Warn; continue }
            }
        }
    }
    if ($PassThru) { [pscustomobject]@{Target=$destination.Name;Port=$Port;Resolution=$system;Probes=$probes;DnsQueries=$queries;DnsFinding=$dnsFinding;Assessment=$conclusion;Summary=$summary} }
}
