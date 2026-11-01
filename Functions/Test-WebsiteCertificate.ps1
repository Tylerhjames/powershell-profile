function Test-WebsiteCertificate {
    <#
    .SYNOPSIS
    Read-only HTTP response, redirect and TLS certificate check.
    .DESCRIPTION
    Sends unauthenticated GET requests, reads response headers only, and retains
    certificate validation. Uses system proxy settings without supplying credentials.
    Does not modify certificates, settings or servers. Clipboard is opt-in.
    .EXAMPLE
    Test-WebsiteCertificate -Target https://example.com -NoPrompt -PassThru
    #>
    [CmdletBinding()]
    param(
        [string]$Target,
        [ValidateRange(500,30000)][int]$TimeoutMs=10000,
        [ValidateRange(0,10)][int]$MaxRedirects=5,
        [switch]$NoPrompt,
        [switch]$PassThru
    )
    $ErrorActionPreference='Stop'
function New-WcClipboardHtml {
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
function Copy-WcReport {
        param([string]$Text)
        # Windows clipboard HTML + UnicodeText, on an STA runspace. No temporary
        # files, browser, network request, or raw ANSI escapes in the clipboard.
        $html=New-WcClipboardHtml $Text
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
    function Write-WcColor([string]$Text,[string]$Tone='Detail') {
        if (Get-Command Write-Color -ErrorAction SilentlyContinue) { Write-Color $Text $Tone }
        else { $colors=@{Header='Gray';Good='DarkGreen';Warn='DarkYellow';Bad='DarkRed';Detail='DarkGray'}; Write-Host $Text -ForegroundColor $colors[$Tone] }
    }
    function ConvertTo-WcUri([string]$Value) {
        $value=$Value.Trim()
        if ($value -match '[\x00-\x20\x7f\\]') { throw 'Enter a hostname or HTTP(S) URL without spaces or control characters.' }
        if ($value -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $value='https://'+$value }
        $uri=$null
        if (-not [uri]::TryCreate($value,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -notin @('http','https') -or $uri.UserInfo -or -not $uri.Host -or $uri.Port -lt 1) { throw 'Use an HTTP(S) URL without embedded credentials.' }
        $builder=[UriBuilder]::new($uri); $builder.Fragment=''
        $builder.Uri
    }
    function Format-WcUrl([uri]$Uri) {
        # Query values can contain tokens; never include them in the ticket.
        $text=$Uri.GetLeftPart([UriPartial]::Path)
        if ($Uri.Query) { $text+='?[query omitted]' }
        $text
    }
    function Protect-WcText([string]$Text) { $Text -replace '[\x00-\x1f\x7f-\x9f]',' ' }
    function Invoke-WcHop([uri]$Uri,[int]$WaitMs) {
        [RoamingProfile.WebsiteProbe]::Check($Uri.AbsoluteUri,$WaitMs).GetAwaiter().GetResult()
    }
    function Get-WcReport([object[]]$Hops,[string]$Outcome,[long]$Elapsed) {
        $lines=[Collections.Generic.List[string]]::new()
        $lines.Add('🌐 WEBSITE & CERTIFICATE CHECK')
        $lines.Add("Time: $([DateTimeOffset]::Now.ToString('yyyy-MM-dd HH:mm:ss zzz')) | Computer: $env:COMPUTERNAME")
        $lines.Add("Total: ${Elapsed}ms | Per-request timeout: ${TimeoutMs}ms")
        $lines.Add('──────────────────────────────────────────────────')
        $lines.Add('🔎 RESPONSE & REDIRECTS')
        foreach ($hop in $Hops) {
            $icon=if ($hop.Status -ge 200 -and $hop.Status -lt 300) {'✓'} elseif ($hop.Status -ge 300 -and $hop.Status -lt 400) {'⚠'} else {'✗'}
            $lines.Add("$icon $(Format-WcUrl ([uri]$hop.Url))")
            $lines.Add("  HTTP: $(if ($hop.Status) {$hop.Status} else {'No response'}) | Headers received / failure: $($hop.Milliseconds)ms")
            # Exception text may echo URLs containing tokens. Keep it in PassThru only.
            if ($hop.Error) { $lines.Add('✗ Request failed (DNS, connection, TLS or timeout); see assessment and certificate details.') }
            if (([uri]$hop.Url).Scheme -eq 'http') { $lines.Add('⚠ HTTP: connection is unencrypted; no TLS certificate.') }
            elseif ($hop.CertificateSeen) {
                $lines.Add('🔎 CERTIFICATE')
                $lines.Add("  Subject: $(Protect-WcText $hop.Subject)")
                $lines.Add("  Issuer: $(Protect-WcText $hop.Issuer)")
                $lines.Add("  SHA-1 thumbprint (identifier): $($hop.Thumbprint)")
                $lines.Add("$(if ($hop.NameMatches) {'✓'} else {'✗'}) Hostname match: $($hop.NameMatches)")
                $lines.Add("$(if ($hop.PolicyErrors -eq 'None') {'✓'} else {'✗'}) OS certificate validation: $($hop.PolicyErrors)")
                if ($hop.ChainStatus) { $lines.Add("  Chain: $(Protect-WcText $hop.ChainStatus)") }
                $days=[math]::Floor(($hop.NotAfterUtc.ToUniversalTime()-[datetime]::UtcNow).TotalDays)
                $expiryIcon=if ($days -lt 0) {'✗'} elseif ($days -le 30) {'⚠'} else {'✓'}
                $lines.Add("$expiryIcon Expires: $($hop.NotAfterUtc.ToString('yyyy-MM-dd HH:mm:ss')) UTC | $days days remaining")
                $lines.Add("  Valid from: $($hop.NotBeforeUtc.ToString('yyyy-MM-dd HH:mm:ss')) UTC")
            } else { $lines.Add('⚠ Certificate unavailable: TLS handshake did not provide one.') }
        }
        $lines.Add('──────────────────────────────────────────────────')
        $lines.Add('📋 ASSESSMENT')
        $lines.Add($Outcome)
        if ($Hops.Count) { $lines.Add("Last attempted URL: $(Format-WcUrl ([uri]$Hops[-1].Url))") }
        $lines.Add('GET headers only; no login, cookies, settings changes or certificate bypass.')
        $lines.Add('Timing includes DNS/connect/TLS/headers as applicable; page rendering and application health were not tested.')
        $lines.Add('System proxy applies. Certificate checks may contact issuer/revocation services.')
        $lines.Add('Ticket includes hostnames and paths; URL queries are omitted.')
        $lines -join "`n"
    }

    Write-WcColor "`n  ═══════════════════════════════════════════════════════" Header
    Write-WcColor '    🌐  WEBSITE & CERTIFICATE CHECK' Header
    Write-WcColor '    HTTP response • Redirects • TLS • Ticket summary'
    Write-WcColor "  ═══════════════════════════════════════════════════════`n" Header
    if (-not $Target) {
        if ($NoPrompt) { throw 'Supply -Target with -NoPrompt.' }
        Write-WcColor '  Enter a hostname or HTTP(S) URL. Default: HTTPS. Enter alone returns to TECH.'
        $Target=Read-Host 'Website'
        if (-not $Target) { if (Get-Command Complete-TechMenuReturn -ErrorAction SilentlyContinue) { Complete-TechMenuReturn }; return }
    }
    $uri=ConvertTo-WcUri $Target
    if (-not ('RoamingProfile.WebsiteProbe' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'WebsiteProbe.cs') }
    $hops=[Collections.Generic.List[object]]::new()
    $visited=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $outcome=''
    for ($index=0; $index -le $MaxRedirects; $index++) {
        if (-not $visited.Add($uri.AbsoluteUri)) { $outcome='✗ Redirect loop detected.'; break }
        Write-WcColor "  → Checking $(Format-WcUrl $uri) ..." Header
        $hop=Invoke-WcHop $uri $TimeoutMs
        $hops.Add($hop)
        if ($hop.Error) { $outcome=if ($hop.CertificateSeen -and $hop.PolicyErrors -ne 'None') {'✗ TLS certificate validation failed. No HTTP request was sent over the rejected TLS connection.'} elseif ($hop.Error -eq 'Request timed out.') {'✗ Request timed out; check connectivity, VPN and server response.'} else {'✗ Request failed. Check DNS, connectivity, proxy and TLS availability.'}; break }
        if ($hop.Status -notin @(301,302,303,307,308)) {
            $outcome=if ($hop.Status -ge 200 -and $hop.Status -lt 300) {'✓ Website returned a successful HTTP response.'} elseif ($hop.Status -in @(401,403)) {'⚠ Server responded but access requires authentication or was denied.'} else {"⚠ Server returned HTTP $($hop.Status)."}
            break
        }
        if (-not $hop.Location) { $outcome='⚠ Redirect response has no Location header.'; break }
        try { $next=ConvertTo-WcUri ([uri]::new($uri,$hop.Location).AbsoluteUri) }
        catch { $outcome='✗ Redirect target is invalid, unsupported or contains credentials.'; break }
        if ($uri.Scheme -eq 'https' -and $next.Scheme -eq 'http') { $outcome='⚠ HTTPS-to-HTTP downgrade stopped.'; break }
        if ($index -eq $MaxRedirects) { $outcome="⚠ Redirect limit ($MaxRedirects) reached."; break }
        $uri=$next
    }
    $timer.Stop()
    $summary=Get-WcReport $hops.ToArray() $outcome $timer.ElapsedMilliseconds
    function Show-WcLines([string]$Text) {
        foreach ($line in ($Text -split "`n")) {
            $tone=if ($line -match '^✓') {'Good'} elseif ($line -match '^⚠') {'Warn'} elseif ($line -match '^✗') {'Bad'} elseif ($line -match '^🌐|^🔎|^📋|^─') {'Header'} else {'Detail'}
            Write-WcColor $line $tone
        }
    }
    Write-WcColor "`n  ┌─ RESPONSE & REDIRECTS ──────────────────────────" Header
    foreach ($hop in $hops) {
        $tone=if ($hop.Status -ge 200 -and $hop.Status -lt 300) {'Good'} elseif ($hop.Status -ge 300 -and $hop.Status -lt 400) {'Warn'} else {'Bad'}
        $icon=if ($tone -eq 'Good') {'✓'} elseif ($tone -eq 'Warn') {'⚠'} else {'✗'}
        Write-WcColor "  $icon $(Format-WcUrl ([uri]$hop.Url))" $tone
        Write-WcColor "    HTTP $(if ($hop.Status) {$hop.Status} else {'unavailable'}) · $($hop.Milliseconds) ms"
        if ($hop.CertificateSeen) {
            Write-WcColor "    Certificate: $(Protect-WcText $hop.Subject)"
            $days=[math]::Floor(($hop.NotAfterUtc.ToUniversalTime()-[datetime]::UtcNow).TotalDays)
            $certTone=if ($hop.PolicyErrors -ne 'None') {'Bad'} elseif ($days -le 30) {'Warn'} else {'Good'}
            Write-WcColor "    Validation: $($hop.PolicyErrors) · Expires $($hop.NotAfterUtc.ToString('yyyy-MM-dd')) ($days days)" $certTone
            Write-WcColor "    Issuer: $(Protect-WcText $hop.Issuer)"
        } elseif (([uri]$hop.Url).Scheme -eq 'http') { Write-WcColor '    ⚠ Unencrypted HTTP — no certificate.' Warn }
        else { Write-WcColor '    Certificate unavailable.' Warn }
    }
    Write-WcColor "`n  ┌─ ASSESSMENT ───────────────────────────────────" Header
    Show-WcLines $outcome
    Write-WcColor "  Total: $($timer.ElapsedMilliseconds) ms · Page rendering and login not tested."
    if (-not $NoPrompt) {
        :actions while ($true) {
            Write-WcColor "`n  [C] Copy ticket summary    [D] Details" Header
            Write-WcColor ('─' * 63) Detail
            Write-WcColor '[Q] Return to menu...' Header
            switch ((Read-Host 'Choose [Enter: back]').ToUpperInvariant()) {
                'C' { try { Copy-WcReport $summary; Write-WcColor '  ✓ Copied with colors and plain-text fallback.' Good } catch { Write-WcColor "  ✗ Copy failed: $($_.Exception.Message)" Bad } }
                'D' { Show-WcLines $summary }
                {$_ -in @('','Q')} { if (Get-Command Complete-TechMenuReturn -ErrorAction SilentlyContinue) { Complete-TechMenuReturn }; break actions }
                default { Write-WcColor '  Choose C, D or Q.' Warn }
            }
        }
    }
    if ($PassThru) { [pscustomobject]@{Hops=$hops.ToArray();Assessment=$outcome;Milliseconds=$timer.ElapsedMilliseconds;Summary=$summary} }
}
