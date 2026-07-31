function Test-EmailAuthentication {
    <#
    .SYNOPSIS
        Tests email authentication DNS records (SPF, DKIM, DMARC, BIMI, MX)
    
    .DESCRIPTION
        Comprehensive email security checker that validates:
        - MX records (mail server configuration)
        - SPF (Sender Policy Framework)
        - DKIM (DomainKeys Identified Mail) with smart selector detection
        - DMARC (Domain-based Message Authentication, Reporting & Conformance)
        - BIMI (Brand Indicators for Message Identification)
        
        Automatically detects Microsoft 365 configurations and uses appropriate
        DKIM selectors. Provides detailed policy analysis and recommendations.
    
    .PARAMETER Domain
        The domain name to check (e.g., example.com)
    
    .PARAMETER DKIMSelectors
        Custom DKIM selectors to test (optional, auto-detected for M365)
    
    .PARAMETER IncludeMTA_STS
        Also check for MTA-STS policy (email encryption in transit)
    
    .PARAMETER ExportResults
        Export results to JSON file
    
    .EXAMPLE
        Test-EmailAuthentication -Domain contoso.com
        Check email authentication for contoso.com
    
    .EXAMPLE
        Test-EmailAuthentication -Domain example.com -IncludeMTA_STS
        Check authentication including MTA-STS policy
    
    .EXAMPLE
        Test-EmailAuthentication -Domain company.com -ExportResults
        Check and save results to JSON file
    
    .NOTES
        Author: Tyler James
        Common DKIM selectors tested: selector1, selector2 (M365), default, dkim, google, k1, k2
    #>
    
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [ValidateNotNullOrEmpty()]
        [string]$Domain,
        
        [Parameter()]
        [string[]]$DKIMSelectors,
        
        [Parameter()]
        [switch]$IncludeMTA_STS,
        
        [Parameter()]
        [switch]$ExportResults
    )
    
    # ══════════════════════════════════════════════════════════════════════════
    # Configuration
    # ══════════════════════════════════════════════════════════════════════════
    
    $results = @{
        Domain    = $Domain
        Timestamp = Get-Date
        MX        = @()
        SPF       = @{ Found = $false; Record = $null; Platform = $null }
        DMARC     = @{ Found = $false; Record = $null; Policy = $null }
        DKIM      = @{ Found = $false; Selector = $null; Record = $null }
        BIMI      = @{ Found = $false; Record = $null }
        MTA_STS   = @{ Found = $false; Record = $null }
    }
    
    # ══════════════════════════════════════════════════════════════════════════
    # Helper Functions
    # ══════════════════════════════════════════════════════════════════════════
    
    # Per-section severity tracking: the summary derives each section's status
    # from the WORST finding emitted in that section (Fail > Warn > OK/Info),
    # not from "a record exists" — so a ✗ detail line can never sit under a
    # ✓ summary. Hashtable contents are mutable from nested function scopes.
    $SectionState = @{ Current = $null; Worst = @{} }
    $SeverityRank = @{ OK = 0; Info = 0; Warn = 1; Fail = 2 }

    function Set-SectionSeverity {
        param([string]$Level)
        $s = $SectionState.Current
        if (-not $s) { return }
        $r = $SeverityRank[$Level]
        if (-not $SectionState.Worst.ContainsKey($s) -or $r -gt $SectionState.Worst[$s]) {
            $SectionState.Worst[$s] = $r
        }
    }

    function Write-SectionHeader {
        param([string]$Title)
        $SectionState.Current = ($Title -split '[ (]')[0]
        Write-Color "`n[$Title]" 'Header'
    }

    function Write-Success {
        param([string]$Message)
        Set-SectionSeverity 'OK'
        Write-Color "  $global:CbitCheck $Message" 'Good'
    }

    function Write-Failure {
        param([string]$Message)
        Set-SectionSeverity 'Fail'
        Write-Color "  $global:CbitCross $Message" 'Bad'
    }

    function Write-Warning {
        param([string]$Message)
        Set-SectionSeverity 'Warn'
        Write-Color "  $global:CbitWarnGlyph $Message" 'Warn'
    }

    function Write-Info {
        param([string]$Message)
        Set-SectionSeverity 'Info'
        Write-Color "  ℹ $Message" 'Detail'
    }
    
    function Get-SafeDNS {
        param(
            [string]$Name,
            [string]$Type = 'A',
            [string]$Server = '8.8.8.8'
        )
        
        try {
            $result = Resolve-DnsName -Name $Name -Type $Type -Server $Server -ErrorAction Stop -DnsOnly
            return $result
        }
        catch {
            return $null
        }
    }

    function Get-RsaKeyBits {
        # Classify RSA key size from the base64 p= tag by DECODED DER byte
        # length. String-length heuristics undercount: DNS TXT records split
        # into 255-byte character-strings (RFC 1035), and a 2048-bit key's
        # ~392-char p= value ALWAYS spans two strings.
        param([string]$Base64Key)
        try {
            $len = [Convert]::FromBase64String($Base64Key).Length
            if     ($len -ge 520) { 4096 }
            elseif ($len -ge 270) { 2048 }
            elseif ($len -ge 140) { 1024 }
            else                  { 0 }
        } catch { 0 }
    }

    function Get-DkimPValue {
        # Extract the base64 p= value from a rejoined DKIM TXT record
        param([string]$DkimRecord)
        $tag = ($DkimRecord -split ';').Trim() | Where-Object { $_ -match '^p=' } | Select-Object -First 1
        if ($tag) { ($tag -replace '^p=') -replace '\s' } else { '' }
    }

    # ══════════════════════════════════════════════════════════════════════════
    # Main Header
    # ══════════════════════════════════════════════════════════════════════════
    
    Write-Color "`n═══════════════════════════════════════════════════════════" 'Header'
    Write-Color "  Email Authentication Check: $Domain" 'Header'
    Write-Color "═══════════════════════════════════════════════════════════" 'Header'

    # ══════════════════════════════════════════════════════════════════════════
    # MX Records
    # ══════════════════════════════════════════════════════════════════════════
    
    Write-SectionHeader "MX Records (Mail Servers)"
    
    try {
        $mxRecords = Get-SafeDNS -Name $Domain -Type MX
        
        if ($mxRecords) {
            $sortedMX = $mxRecords | Sort-Object Preference
            
            foreach ($mx in $sortedMX) {
                Write-Success "Priority $($mx.Preference): $($mx.NameExchange)"
                $results.MX += @{
                    Priority = $mx.Preference
                    Server   = $mx.NameExchange
                }
            }
            
            # Detect email platform
            $mxString = ($sortedMX.NameExchange -join " ").ToLower()
            $platform = switch -Regex ($mxString) {
                'mail\.protection\.outlook' { 'Microsoft 365 (EOP)'; break }
                'outlook\.com'              { 'Microsoft 365'; break }
                'google\.com|googlemail'    { 'Google Workspace'; break }
                'proofpoint'                { 'Proofpoint'; break }
                'mimecast'                  { 'Mimecast'; break }
                'barracuda'                 { 'Barracuda'; break }
                default { 'Unknown/Self-hosted' }
            }
            
            Write-Info "Platform detected: $platform"
            $results.SPF.Platform = $platform
        }
        else {
            Write-Failure "No MX records found"
        }
    }
    catch {
        Write-Failure "MX lookup failed: $_"
    }
    
    # ══════════════════════════════════════════════════════════════════════════
    # SPF Record
    # ══════════════════════════════════════════════════════════════════════════
    
    Write-SectionHeader "SPF (Sender Policy Framework)"
    
    try {
        $txtRecords = Get-SafeDNS -Name $Domain -Type TXT
        $spfRecord = $txtRecords.Strings | Where-Object { $_ -match "^v=spf1" } | Select-Object -First 1
        
        if ($spfRecord) {
            Write-Success "SPF record found"
            Write-Color "    $spfRecord" 'Detail'
            
            $results.SPF.Found = $true
            $results.SPF.Record = $spfRecord
            
            # Analyze SPF record
            $mechanisms = @{
                'include:' = ($spfRecord | Select-String -Pattern 'include:([^\s]+)' -AllMatches).Matches.Groups | 
                             Where-Object { $_.Name -eq 1 } | ForEach-Object { $_.Value }
                'ip4:'     = ($spfRecord | Select-String -Pattern 'ip4:([^\s]+)' -AllMatches).Matches.Groups | 
                             Where-Object { $_.Name -eq 1 } | ForEach-Object { $_.Value }
                'a'        = $spfRecord -match '\sa\s|\sa$'
                'mx'       = $spfRecord -match '\smx\s|\smx$'
                'all'      = if ($spfRecord -match '([~\-\+\?])all') { $Matches[1] } else { $null }
            }
            
            # Show includes
            if ($mechanisms['include:']) {
                Write-Info "Includes: $($mechanisms['include:'] -join ', ')"
            }
            
            # Show all policy
            $allPolicy = switch ($mechanisms['all']) {
                '-' { "FAIL (hard fail - rejects unauthorized mail)"; 'Good'; break }
                '~' { "SOFTFAIL (flags but doesn't reject)"; 'Warn'; break }
                '+' { "PASS (allows all - not recommended!)"; 'Bad'; break }
                '?' { "NEUTRAL (no policy)"; 'Bad'; break }
                default { "NOT SPECIFIED"; 'Bad' }
            }

            Write-Color "    Policy: $($allPolicy[0])" $allPolicy[1]
            Set-SectionSeverity $(switch ($allPolicy[1]) { 'Bad' { 'Fail' } 'Warn' { 'Warn' } default { 'OK' } })
            
            # DNS lookup count warning
            $lookupCount = ($mechanisms['include:'].Count + 
                           ($mechanisms['a'] ? 1 : 0) + 
                           ($mechanisms['mx'] ? 1 : 0))
            
            if ($lookupCount -gt 10) {
                Write-Warning "SPF has $lookupCount DNS lookups (RFC limit: 10)"
                Write-Info "Consider flattening your SPF record to reduce lookups"
            }
        }
        else {
            Write-Failure "SPF record NOT found"
            Write-Info "Without SPF, your emails may be marked as spam"
        }
    }
    catch {
        Write-Failure "SPF lookup failed: $_"
    }
    
    # ══════════════════════════════════════════════════════════════════════════
    # DMARC Record
    # ══════════════════════════════════════════════════════════════════════════
    
    Write-SectionHeader "DMARC (Domain-based Message Authentication)"
    
    try {
        $dmarcRecords = Get-SafeDNS -Name "_dmarc.$Domain" -Type TXT
        $dmarcRecord = $dmarcRecords.Strings | Where-Object { $_ -match "^v=DMARC1" } | Select-Object -First 1
        
        if ($dmarcRecord) {
            Write-Success "DMARC record found"
            Write-Color "    $dmarcRecord" 'Detail'
            
            $results.DMARC.Found = $true
            $results.DMARC.Record = $dmarcRecord
            
            # Parse policy
            if ($dmarcRecord -match 'p=([^;]+)') {
                $policy = $Matches[1]
                $results.DMARC.Policy = $policy
                
                $policyDesc = switch ($policy) {
                    'none'       { "$global:CbitWarnGlyph MONITOR ONLY (no enforcement)"; 'Bad'; break }
                    'quarantine' { "QUARANTINE (suspicious mail to spam)"; ''; break }
                    'reject'     { "REJECT (blocks unauthorized mail)"; 'Good'; break }
                    default      { "UNKNOWN"; 'Bad' }
                }

                Write-Color "    Policy: $($policyDesc[0])" $policyDesc[1]
                Set-SectionSeverity $(switch ($policyDesc[1]) { 'Bad' { 'Fail' } 'Warn' { 'Warn' } default { 'OK' } })
            }
            
            # Parse percentage
            if ($dmarcRecord -match 'pct=(\d+)') {
                $pct = $Matches[1]
                Write-Info "Applied to $pct% of mail"
                
                if ($pct -lt 100) {
                    Write-Warning "Consider increasing to 100% for full protection"
                }
            }
            
            # Parse reporting addresses
            if ($dmarcRecord -match 'rua=([^;]+)') {
                Write-Info "Aggregate reports: $($Matches[1])"
            }
            if ($dmarcRecord -match 'ruf=([^;]+)') {
                Write-Info "Forensic reports: $($Matches[1])"
            }
        }
        else {
            Write-Failure "DMARC record NOT found"
            Write-Info "DMARC provides email authentication and reporting"
        }
    }
    catch {
        Write-Failure "DMARC lookup failed: $_"
    }
    
    # ══════════════════════════════════════════════════════════════════════════
    # DKIM Records
    # ══════════════════════════════════════════════════════════════════════════
    
    Write-SectionHeader "DKIM (DomainKeys Identified Mail)"
    
    # Determine selectors to test
    $m365Mode = $false
    if ($DKIMSelectors) {
        $selectors = $DKIMSelectors
    }
    elseif ($results.SPF.Platform -match 'Microsoft|365') {
        $selectors = @('selector1', 'selector2')
        $m365Mode = $true
        Write-Info "Testing Microsoft 365 selectors"
    }
    elseif ($results.SPF.Platform -match 'Google') {
        $selectors = @('google', 'default')
        Write-Info "Testing Google Workspace selectors"
    }
    else {
        $selectors = @('default', 'selector1', 'selector2', 'dkim', 'k1', 'k2', 'mail', 'smtp')
        Write-Info "Testing common DKIM selectors"
    }
    
    $foundSelectors = @()

    if ($m365Mode) {
        # M365 publishes the DKIM public key only for the ACTIVE selector; the
        # inactive selector's CNAME resolves but carries no TXT until the next
        # rotation publishes it (signing flips ~96h later). CNAME and TXT are
        # therefore separate failure domains: the customer owns the two CNAMEs
        # in their zone, Microsoft owns the terminal TXT. Receivers only ever
        # query the selector named in the s= header of actual mail.
        foreach ($selector in $selectors) {
            $dkimName = "$selector._domainkey.$Domain"
            $cname = Get-SafeDNS -Name $dkimName -Type CNAME | Where-Object Type -eq 'CNAME'
            $txt   = Get-SafeDNS -Name $dkimName -Type TXT   | Where-Object Type -eq 'TXT'

            # Rejoin 255-byte TXT splits before parsing (RFC 1035)
            $dkimRecord = if ($txt) { ($txt | Select-Object -First 1).Strings -join '' } else { '' }

            if ($dkimRecord -match 'v=DKIM1') {
                $bits = Get-RsaKeyBits (Get-DkimPValue $dkimRecord)
                if ($bits -ge 2048) {
                    Write-Success "$selector signing key found - RSA $bits-bit"
                }
                elseif ($bits -gt 0) {
                    Write-Warning "$selector key is RSA $bits-bit - below 2048"
                }
                else {
                    Write-Warning "$selector key found but size unknown (p= tag missing or malformed)"
                }
                if (-not $cname) {
                    Write-Warning "$selector published as direct TXT - unsupported for M365, key rotation unmanaged"
                }
                $foundSelectors += $selector
                $results.DKIM.Found = $true
                if (-not $results.DKIM.Record) { $results.DKIM.Record = $dkimRecord }
            }
            elseif ($cname) {
                Write-Info "$selector inactive - key unpublished until rotation (normal for M365)"
            }
            else {
                Write-Failure "$selector CNAME missing - publish it; blocks DKIM key rotation"
            }
        }

        if ($foundSelectors.Count -eq 0) {
            Write-Failure "No selector resolves to a key - domain is not DKIM signing"
        }
    }
    else {
        # Non-M365 platforms: every published selector is expected to carry a
        # key, so absence of a TXT is simply "not found" — the M365
        # inactive-selector downgrade does not apply here.
        foreach ($selector in $selectors) {
            try {
                $dkimName = "$selector._domainkey.$Domain"
                $dkimRecords = Get-SafeDNS -Name $dkimName -Type TXT
                $dkimRecord = ($dkimRecords | Where-Object Type -eq 'TXT' | Select-Object -First 1).Strings -join ''

                if ($dkimRecord -match "v=DKIM1") {
                    Write-Success "DKIM found (selector: $selector)"

                    # Truncate very long keys for display
                    $displayKey = if ($dkimRecord.Length -gt 100) {
                        "$($dkimRecord.Substring(0, 97))..."
                    } else {
                        $dkimRecord
                    }
                    Write-Color "    $displayKey" 'Detail'

                    $results.DKIM.Found = $true
                    if (-not $results.DKIM.Record) { $results.DKIM.Record = $dkimRecord }

                    # Analyze key strength by decoded DER length of the p= tag
                    if ($dkimRecord -match 'k=rsa|p=') {
                        $bits = Get-RsaKeyBits (Get-DkimPValue $dkimRecord)
                        if ($bits -ge 2048) {
                            Write-Success "Key strength: RSA $bits-bit"
                        }
                        elseif ($bits -gt 0) {
                            Write-Warning "Weak key: RSA $bits-bit - below 2048"
                        }
                        else {
                            Write-Warning "Key size unknown (p= tag missing or malformed)"
                        }
                    }

                    $foundSelectors += $selector
                }
            }
            catch {
                # Selector not found, continue to next
            }
        }

        if ($foundSelectors.Count -eq 0) {
            Write-Failure "DKIM record NOT found"
            Write-Info "Tested selectors: $($selectors -join ', ')"
            Write-Info "You may need to specify custom selectors with -DKIMSelectors"
        }
        elseif ($DKIMSelectors) {
            # User-specified selectors: report any that didn't resolve
            $notFound = @($DKIMSelectors | Where-Object { $foundSelectors -notcontains $_ })
            if ($notFound.Count -gt 0) {
                Write-Warning "Specified selector(s) not found: $($notFound -join ', ')"
            }
        }
    }

    $results.DKIM.Selector = $foundSelectors -join ', '
    
    # ══════════════════════════════════════════════════════════════════════════
    # BIMI Record
    # ══════════════════════════════════════════════════════════════════════════
    
    Write-SectionHeader "BIMI (Brand Indicators for Message Identification)"
    
    try {
        $bimiRecords = Get-SafeDNS -Name "default._bimi.$Domain" -Type TXT
        $bimiRecord = $bimiRecords.Strings | Where-Object { $_ -match "^v=BIMI1" } | Select-Object -First 1
        
        if ($bimiRecord) {
            Write-Success "BIMI record found"
            Write-Color "    $bimiRecord" 'Detail'
            
            $results.BIMI.Found = $true
            $results.BIMI.Record = $bimiRecord
            
            # Parse logo URL
            if ($bimiRecord -match 'l=([^;]+)') {
                Write-Info "Logo URL: $($Matches[1])"
            }
            
            # Check for VMC
            if ($bimiRecord -match 'a=([^;]+)') {
                Write-Success "VMC (Verified Mark Certificate) configured"
                Write-Info "VMC URL: $($Matches[1])"
            } else {
                Write-Warning "No VMC found (required for brand logo display in Gmail/Yahoo)"
            }
        }
        else {
            Write-Warning "BIMI record not found (optional)"
            Write-Info "BIMI displays your brand logo in supported email clients"
        }
    }
    catch {
        Write-Warning "BIMI lookup failed: $_"
    }
    
    # ══════════════════════════════════════════════════════════════════════════
    # MTA-STS (Optional)
    # ══════════════════════════════════════════════════════════════════════════
    
    if ($IncludeMTA_STS) {
        Write-SectionHeader "MTA-STS (SMTP TLS Reporting)"
        
        try {
            $mtaStsRecords = Get-SafeDNS -Name "_mta-sts.$Domain" -Type TXT
            $mtaStsRecord = $mtaStsRecords.Strings | Where-Object { $_ -match "^v=STSv1" } | Select-Object -First 1
            
            if ($mtaStsRecord) {
                Write-Success "MTA-STS record found"
                Write-Color "    $mtaStsRecord" 'Detail'
                
                $results.MTA_STS.Found = $true
                $results.MTA_STS.Record = $mtaStsRecord
                
                # Check for policy file
                $policyUrl = "https://mta-sts.$Domain/.well-known/mta-sts.txt"
                Write-Info "Policy URL: $policyUrl"
                
                try {
                    $policyResponse = Invoke-WebRequest -Uri $policyUrl -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
                    Write-Success "Policy file accessible"
                } catch {
                    Write-Failure "Policy file not accessible"
                }
            }
            else {
                Write-Failure "MTA-STS record NOT found"
                Write-Info "MTA-STS enforces TLS encryption for email in transit"
            }
        }
        catch {
            Write-Failure "MTA-STS lookup failed: $_"
        }
    }
    
    # ══════════════════════════════════════════════════════════════════════════
    # Summary & Recommendations
    # ══════════════════════════════════════════════════════════════════════════
    
    Write-Color "`n═══════════════════════════════════════════════════════════" 'Header'
    Write-Color "  Security Summary" 'Header'
    Write-Color "═══════════════════════════════════════════════════════════" 'Header'
    
    # Section status = worst finding emitted in that section, not mere record
    # existence — a ✗ or ⚠ in the detail lines surfaces here.
    function Get-SectionStatus {
        param([string]$Key, [bool]$Found)
        $worst = if ($SectionState.Worst.ContainsKey($Key)) { $SectionState.Worst[$Key] } else { 0 }
        if (-not $Found -or $worst -ge 2) { ,@($global:CbitCross, 'Bad') }
        elseif ($worst -eq 1)             { ,@($global:CbitWarnGlyph, 'Warn') }
        else                              { ,@($global:CbitCheck, 'Good') }
    }

    $status = @{
        MX    = Get-SectionStatus 'MX'    ($results.MX.Count -gt 0)
        SPF   = Get-SectionStatus 'SPF'   $results.SPF.Found
        DKIM  = Get-SectionStatus 'DKIM'  $results.DKIM.Found
        DMARC = Get-SectionStatus 'DMARC' $results.DMARC.Found
    }

    $score = 0
    $maxScore = 4
    foreach ($k in 'MX', 'SPF', 'DKIM', 'DMARC') {
        if ($status[$k][1] -ne 'Bad') { $score++ }
    }

    Write-Color "`nSecurity Score: $score / $maxScore" $(
        if ($score -eq $maxScore) { 'Good' }
        elseif ($score -ge 3) { 'Warn' }
        else { 'Bad' }
    )

    Write-Color "`nConfiguration Status:" 'Header'
    Write-Color "  MX:    $($status.MX[0])"    $status.MX[1]
    Write-Color "  SPF:   $($status.SPF[0])"   $status.SPF[1]
    Write-Color "  DKIM:  $($status.DKIM[0])"  $status.DKIM[1]
    Write-Color "  DMARC: $($status.DMARC[0])" $status.DMARC[1]
    Write-Color "  BIMI:  $(if ($results.BIMI.Found) { $global:CbitCheck } else { '○' })" $(if ($results.BIMI.Found) { 'Good' } else { 'Detail' }) -NoNewline
    Write-Color " (optional)" 'Detail'

    # Recommendations
    if ($score -lt $maxScore) {
        Write-Color "`nRecommendations:" 'Header'

        if (-not $results.SPF.Found) {
            Write-Host "  • Configure SPF to authorize mail servers"
        }
        if (-not $results.DKIM.Found) {
            Write-Host "  • Enable DKIM to sign outgoing messages"
        }
        if (-not $results.DMARC.Found) {
            Write-Host "  • Implement DMARC for authentication and reporting"
        }
        if ($results.DMARC.Found -and $results.DMARC.Policy -eq 'none') {
            Write-Host "  • Upgrade DMARC policy from 'none' to 'quarantine' or 'reject'"
        }
    }
    
    Write-Host ""
    
    # ══════════════════════════════════════════════════════════════════════════
    # Export Results
    # ══════════════════════════════════════════════════════════════════════════
    
    if ($ExportResults) {
        $exportPath = "email-auth-$Domain-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
        $results | ConvertTo-Json -Depth 5 | Set-Content $exportPath
        Write-Color "$global:CbitCheck Results exported to: $exportPath" 'Good'
    }
    
    # Store in global variable for easy access
    $Global:LastEmailAuthCheck = $results
}

# ══════════════════════════════════════════════════════════════════════════════
# Aliases
# ══════════════════════════════════════════════════════════════════════════════

Set-Alias -Name Test-EmailDNS -Value Test-EmailAuthentication -Scope Global  # Backward compatibility
Set-Alias -Name Check-EmailDNS -Value Test-EmailAuthentication -Scope Global
Set-Alias -Name Test-DMARC -Value Test-EmailAuthentication -Scope Global