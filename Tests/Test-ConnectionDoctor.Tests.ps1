param([string]$Source=(Join-Path $PSScriptRoot '../Functions/Test-ConnectionDoctor.ps1'))
$ErrorActionPreference='Stop'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors -join "`n") }
. $Source
foreach ($definition in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -match '-Cd'},$true)) { . ([scriptblock]::Create($definition.Extent.Text)) }
$script:passed=0
function Assert($Condition,$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:passed++; Write-Host "PASS: $Message" }
function Reject([scriptblock]$Code) { $failed=$false; try { & $Code | Out-Null } catch { $failed=$true }; Assert $failed 'Invalid input rejected' }
Assert ((ConvertTo-CdTarget 'https://example.test:8443/a?token=secret').Name -eq 'example.test') 'URL path/query excluded'
Assert ((ConvertTo-CdTarget 'https://example.test:8443/').UrlPort -eq 8443) 'URL port detected'
Reject { ConvertTo-CdTarget '[::1]' }
Reject { ConvertTo-CdTarget 'http://[::1]/' }
Reject { Test-ConnectionDoctor -Target localhost -ComparisonServer '::1' -NoPrompt }
Assert ((ConvertTo-CdTarget 'server.example.').Name -eq 'server.example.') 'FQDN accepted'
Reject { ConvertTo-CdTarget 'https://user:password@example.test' }
Reject { ConvertTo-CdTarget "host`ncommand" }
Reject { ConvertTo-CdTarget '-oProxyCommand=bad' }
Reject { ConvertTo-CdTarget 'host:22' }
Reject { ConvertTo-CdTarget 'a..b' }
Reject { Test-ConnectionDoctor -NoPrompt }
Reject { Test-ConnectionDoctor -Target localhost -Port 65536 -NoPrompt }
Reject { Test-ConnectionDoctor -Target localhost -ComparisonServer 'bad server' -NoPrompt }
$ip=Resolve-CdSystem '127.0.0.1' 1000
Assert ($ip.Status -like 'Literal IP*' -and $ip.Addresses[0] -eq '127.0.0.1') 'Literal skips DNS'
Assert ((Resolve-CdSystem localhost 3000).Addresses.Count -gt 0) 'System resolution returns localhost addresses'

# Native cmdlet fixtures: no DNS queries, route changes, or clipboard writes.
$script:dnsCalls=[Collections.Generic.List[string]]::new()
$script:dnsFail=$false
function Resolve-DnsName {
    param($Name,$Server,$Type,[switch]$DnsOnly,[switch]$NoHostsFile,[switch]$QuickTimeout,$ErrorAction)
    Assert ($DnsOnly -and $NoHostsFile -and $QuickTimeout -and $Type -eq 'A') 'IPv4-only DNS query options'
    $script:dnsCalls.Add($Server)
    if ($script:dnsFail) { throw 'Simulated resolver timeout' }
    [pscustomobject]@{Type='CNAME';NameHost='service.example';TTL=120}
    [pscustomobject]@{Type='A';IPAddress='127.0.0.1';TTL=60}
}
function Get-NetAdapter { param($ErrorAction) [pscustomobject]@{Status='Up';InterfaceIndex=1}; [pscustomobject]@{Status='Down';InterfaceIndex=2} }
function Get-DnsClientServerAddress {
    param($ErrorAction,$AddressFamily)
    Assert ($AddressFamily -eq 'IPv4') 'IPv4-only resolver inventory requested'
    [pscustomobject]@{InterfaceIndex=1;ServerAddresses=@('fec0:0:0:ffff::1','192.0.2.53','192.0.2.54','192.0.2.53')}
    [pscustomobject]@{InterfaceIndex=2;ServerAddresses=@('192.0.2.99')}
}
function Find-NetRoute {
    param($RemoteIPAddress,$ErrorAction)
    [pscustomobject]@{IPAddress='127.0.0.1';InterfaceAlias='Loopback'}
    [pscustomobject]@{DestinationPrefix='127.0.0.0/8';NextHop='0.0.0.0'}
}
function Set-Clipboard { throw 'Unexpected clipboard modification' }
function Read-Host { throw 'Unexpected prompt in noninteractive test' }
$resolvers=@(Get-CdResolvers)
Assert ($resolvers.Count -eq 2 -and '192.0.2.99' -notin $resolvers) 'Only unique active-adapter resolvers'
$answer=Resolve-CdComparison localhost '192.0.2.53'
Assert ($answer.Status -eq 'Answered' -and $answer.Details[0] -like 'CNAME*TTL 120*') 'CNAME and TTL reported'
$script:dnsFail=$true
Assert ((Resolve-CdComparison localhost '192.0.2.53').Status -eq 'Query failed') 'Resolver failure captured without crash'
$script:dnsFail=$false
Assert ((Get-CdDnsFinding @($answer)).StartsWith('One resolver')) 'Single answer is not agreement'
Assert ((Get-CdDnsFinding @($answer,$answer)).Contains('matching')) 'Identical answer sets agree'
$other=[pscustomobject]@{Status='Answered';Addresses=@('192.0.2.100')}
Assert ((Get-CdDnsFinding @($answer,$other)).Contains('not proof')) 'DNS difference is not labeled misconfiguration'
Assert ((Get-CdRoute '127.0.0.1').Interface -eq 'Loopback') 'Selected route/source captured'

$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$listener.Start()
$port=$listener.LocalEndpoint.Port
try {
    $tcp=Test-CdTcp '127.0.0.1' $port 1000
    Assert ($tcp.Status -eq 'Connected' -and $tcp.LocalEndpoint) 'Actual loopback TCP connection and source'
    $report=Test-ConnectionDoctor -Target '127.0.0.1' -Port $port -NoPrompt -PassThru
    Assert ($report.Probes[0].Tcp.Status -eq 'Connected') 'Full literal-IP workflow'
    Assert ($report.DnsQueries.Count -eq 0) 'No DNS comparison for IP literal'
    Assert ($report.Summary.Contains('does not verify TLS') -and $report.Summary.Contains('Selected route:')) 'Ticket summary includes limits and route'
    $script:dnsCalls.Clear()
    $report=Test-ConnectionDoctor -Target localhost -Port $port -NoPrompt -PassThru
    Assert ($script:dnsCalls.Count -eq 2 -and '8.8.8.8' -notin $script:dnsCalls) 'No unsolicited public resolver'
    $script:dnsCalls.Clear()
    $null=Test-ConnectionDoctor -Target localhost -Port $port -ComparisonServer '192.0.2.55' -NoPrompt -PassThru
    Assert ('192.0.2.55' -in $script:dnsCalls -and $script:dnsCalls.Count -eq 3) 'Explicit comparator queried only on request'
} finally { $listener.Stop() }
$tcp=Test-CdTcp '127.0.0.1' $port 5000
Assert ($tcp.Status -eq 'Refused') 'Closed loopback port distinguished from timeout'
function Find-NetRoute { param($RemoteIPAddress,$ErrorAction) throw 'Simulated missing module/access' }
$report=Test-ConnectionDoctor -Target '127.0.0.1' -Port $port -NoPrompt -PassThru
Assert ($report.Probes[0].Route.Status -eq 'Unavailable' -and $report.Summary.Contains('Simulated missing')) 'Route errors degrade gracefully'
Assert ($report.Assessment.Contains('cannot identify the cause')) 'Failed TCP avoids unsupported diagnosis'
# Menu retry/custom/default/cancel tests use numbered fallback to avoid console IO.
$script:menuAnswers=[Collections.Generic.Queue[string]]::new()
function Read-Host { param($Prompt) if (-not $script:menuAnswers.Count) { throw "Unexpected prompt: $Prompt" }; $script:menuAnswers.Dequeue() }
$script:menuAnswers.Enqueue('3')
Assert ((Select-CdService -Numbered) -eq 22) 'Service list chooses SSH'
$script:menuAnswers.Enqueue('')
Assert ((Select-CdService -Numbered -SuggestedPort 80) -eq 80) 'URL-suggested service default'
foreach ($entry in @('bad','6','70000','8443')) { $script:menuAnswers.Enqueue($entry) }
Assert ((Select-CdService -Numbered) -eq 8443) 'Invalid entries retry; custom port accepted'
$script:menuAnswers.Enqueue('Q')
Assert ($null -eq (Select-CdService -Numbered)) 'Service selection cancels safely'
$html=New-CdClipboardHtml "🩺 CONNECTION DOCTOR`n✓ Connected`n⚠ Warning`n✗ Failure`n<&>"
Assert ($html.Contains('#8fa880') -and $html.Contains('#b08946') -and $html.Contains('#963c3c')) 'Rich clipboard uses toolkit status palette'
Assert ($html.Contains('&lt;&amp;&gt;')) 'Rich clipboard escapes report content'
$offsets=@{}
foreach ($field in @('StartHTML','EndHTML','StartFragment','EndFragment')) { $null=$html -match "$field`:(\d+)"; $offsets[$field]=[int]$Matches[1] }
$bytes=[Text.Encoding]::UTF8.GetBytes($html)
$fragment=[Text.Encoding]::UTF8.GetString($bytes,$offsets.StartFragment,($offsets.EndFragment-$offsets.StartFragment))
Assert ($fragment.StartsWith('<div') -and $fragment.EndsWith('</div>') -and [Net.WebUtility]::HtmlDecode($fragment).Contains('🩺')) 'UTF-8 clipboard fragment offsets include emoji correctly'
Assert ($offsets.EndHTML -eq $bytes.Length) 'Clipboard document byte length correct'
# Actual interactive report exit without clipboard changes.
$script:menuAnswers.Enqueue('D'); $script:menuAnswers.Enqueue('Q')
$null=Test-ConnectionDoctor -Target 127.0.0.1 -Port $port -PassThru
Assert ($script:menuAnswers.Count -eq 0) 'Details and Back actions return normally'
Write-Host "All $script:passed Connection Doctor checks passed. Only loopback TCP was used; DNS and route cmdlets were mocked."
