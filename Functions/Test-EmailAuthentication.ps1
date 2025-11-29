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
    
    function Write-SectionHeader {
        param([string]$Title)
        Write-Host "`n[$Title]" -ForegroundColor Yellow
    }
    
    function Write-Success {
        param([string]$Message)
        Write-Host "  ✔ $Message" -ForegroundColor Green
    }
    
    function Write-Failure {
        param([string]$Message)
        Write-Host "  ✖ $Message" -ForegroundColor Red
    }
    
    function Write-Warning {
        param([string]$Message)
        Write-Host "  ⚠ $Message" -ForegroundColor Yellow
    }
    
    function Write-Info {
        param([string]$Message)
        Write-Host "  ℹ $Message" -ForegroundColor Cyan
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
    
    # ══════════════════════════════════════════════════════════════════════════
    # Main Header
    # ══════════════════════════════════════════════════════════════════════════
    
    Write-Host "`n═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Email Authentication Check: $Domain" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
    
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
                'outlook\.com|protection\.outlook' { 'Microsoft 365'; break }
                'google\.com|googlemail' { 'Google Workspace'; break }
                'mail\.protection\.outlook' { 'Microsoft 365 (EOP)'; break }
                'proofpoint' { 'Proofpoint'; break }
                'mimecast' { 'Mimecast'; break }
                'barracuda' { 'Barracuda'; break }
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
            Write-Host "    $spfRecord" -ForegroundColor Gray
            
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
                '-' { "FAIL (hard fail - rejects unauthorized mail)"; 'Green'; break }
                '~' { "SOFTFAIL (flags but doesn't reject)"; 'Yellow'; break }
                '+' { "PASS (allows all - not recommended!)"; 'Red'; break }
                '?' { "NEUTRAL (no policy)"; 'Red'; break }
                default { "NOT SPECIFIED"; 'Red' }
            }
            
            Write-Host "    Policy: $($allPolicy[0])" -ForegroundColor $allPolicy[1]
            
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
            Write-Host "    $dmarcRecord" -ForegroundColor Gray
            
            $results.DMARC.Found = $true
            $results.DMARC.Record = $dmarcRecord
            
            # Parse policy
            if ($dmarcRecord -match 'p=([^;]+)') {
                $policy = $Matches[1]
                $results.DMARC.Policy = $policy
                
                $policyDesc = switch ($policy) {
                    'none'       { "MONITOR ONLY (no enforcement)"; 'Yellow'; break }
                    'quarantine' { "QUARANTINE (suspicious mail to spam)"; 'Cyan'; break }
                    'reject'     { "REJECT (blocks unauthorized mail)"; 'Green'; break }
                    default      { "UNKNOWN"; 'Red' }
                }
                
                Write-Host "    Policy: $($policyDesc[0])" -ForegroundColor $policyDesc[1]
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
    if ($DKIMSelectors) {
        $selectors = $DKIMSelectors
    }
    elseif ($results.SPF.Platform -match 'Microsoft|365') {
        $selectors = @('selector1', 'selector2')
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
    
    $foundDKIM = $false
    
    foreach ($selector in $selectors) {
        try {
            $dkimName = "$selector._domainkey.$Domain"
            $dkimRecords = Get-SafeDNS -Name $dkimName -Type TXT
            $dkimRecord = $dkimRecords.Strings -join ""
            
            if ($dkimRecord -match "v=DKIM1") {
                Write-Success "DKIM found (selector: $selector)"
                
                # Truncate very long keys for display
                $displayKey = if ($dkimRecord.Length -gt 100) {
                    "$($dkimRecord.Substring(0, 97))..."
                } else {
                    $dkimRecord
                }
                Write-Host "    $displayKey" -ForegroundColor Gray
                
                $results.DKIM.Found = $true
                $results.DKIM.Selector = $selector
                $results.DKIM.Record = $dkimRecord
                
                # Analyze key strength
                if ($dkimRecord -match 'k=rsa') {
                    Write-Info "Key type: RSA"
                    
                    # Estimate key size (rough estimate from base64 length)
                    if ($dkimRecord.Length -gt 500) {
                        Write-Success "Strong key (likely 2048+ bit)"
                    } else {
                        Write-Warning "Weak key (likely 1024 bit or less)"
                    }
                }
                
                $foundDKIM = $true
                break
            }
        }
        catch {
            # Selector not found, continue to next
        }
    }
    
    if (-not $foundDKIM) {
        Write-Failure "DKIM record NOT found"
        Write-Info "Tested selectors: $($selectors -join ', ')"
        Write-Info "You may need to specify custom selectors with -DKIMSelectors"
    }
    
    # ══════════════════════════════════════════════════════════════════════════
    # BIMI Record
    # ══════════════════════════════════════════════════════════════════════════
    
    Write-SectionHeader "BIMI (Brand Indicators for Message Identification)"
    
    try {
        $bimiRecords = Get-SafeDNS -Name "default._bimi.$Domain" -Type TXT
        $bimiRecord = $bimiRecords.Strings | Where-Object { $_ -match "^v=BIMI1" } | Select-Object -First 1
        
        if ($bimiRecord) {
            Write-Success "BIMI record found"
            Write-Host "    $bimiRecord" -ForegroundColor Gray
            
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
            Write-Failure "BIMI record NOT found"
            Write-Info "BIMI displays your brand logo in supported email clients"
        }
    }
    catch {
        Write-Failure "BIMI lookup failed: $_"
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
                Write-Host "    $mtaStsRecord" -ForegroundColor Gray
                
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
    
    Write-Host "`n═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Security Summary" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
    
    $score = 0
    $maxScore = 4
    
    if ($results.MX.Count -gt 0) { $score++ }
    if ($results.SPF.Found) { $score++ }
    if ($results.DKIM.Found) { $score++ }
    if ($results.DMARC.Found) { $score++ }
    
    Write-Host "`nSecurity Score: $score / $maxScore" -ForegroundColor $(
        if ($score -eq $maxScore) { 'Green' }
        elseif ($score -ge 3) { 'Yellow' }
        else { 'Red' }
    )
    
    Write-Host "`nConfiguration Status:" -ForegroundColor White
    Write-Host "  MX:    $(if ($results.MX.Count -gt 0) { '✔' } else { '✖' })" -ForegroundColor $(if ($results.MX.Count -gt 0) { 'Green' } else { 'Red' })
    Write-Host "  SPF:   $(if ($results.SPF.Found) { '✔' } else { '✖' })" -ForegroundColor $(if ($results.SPF.Found) { 'Green' } else { 'Red' })
    Write-Host "  DKIM:  $(if ($results.DKIM.Found) { '✔' } else { '✖' })" -ForegroundColor $(if ($results.DKIM.Found) { 'Green' } else { 'Red' })
    Write-Host "  DMARC: $(if ($results.DMARC.Found) { '✔' } else { '✖' })" -ForegroundColor $(if ($results.DMARC.Found) { 'Green' } else { 'Red' })
    Write-Host "  BIMI:  $(if ($results.BIMI.Found) { '✔' } else { '○' })" -ForegroundColor $(if ($results.BIMI.Found) { 'Green' } else { 'Gray' }) -NoNewline
    Write-Host " (optional)" -ForegroundColor Gray
    
    # Recommendations
    if ($score -lt $maxScore) {
        Write-Host "`nRecommendations:" -ForegroundColor Yellow
        
        if (-not $results.SPF.Found) {
            Write-Host "  • Configure SPF to authorize mail servers" -ForegroundColor White
        }
        if (-not $results.DKIM.Found) {
            Write-Host "  • Enable DKIM to sign outgoing messages" -ForegroundColor White
        }
        if (-not $results.DMARC.Found) {
            Write-Host "  • Implement DMARC for authentication and reporting" -ForegroundColor White
        }
        if ($results.DMARC.Found -and $results.DMARC.Policy -eq 'none') {
            Write-Host "  • Upgrade DMARC policy from 'none' to 'quarantine' or 'reject'" -ForegroundColor White
        }
    }
    
    Write-Host ""
    
    # ══════════════════════════════════════════════════════════════════════════
    # Export Results
    # ══════════════════════════════════════════════════════════════════════════
    
    if ($ExportResults) {
        $exportPath = "email-auth-$Domain-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
        $results | ConvertTo-Json -Depth 5 | Set-Content $exportPath
        Write-Host "✔ Results exported to: $exportPath" -ForegroundColor Green
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