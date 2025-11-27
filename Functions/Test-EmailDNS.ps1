function Test-EmailDNS {
    param(
        [Parameter(Mandatory)]
        [string]$Domain
    )

    Write-Host "=== DNS Email Authentication Check for $Domain ===" -ForegroundColor Cyan

    # MX
    Write-Host "`n[MX]" -ForegroundColor Yellow
    try {
        $mx = Resolve-DnsName -Name $Domain -Type MX -ErrorAction Stop
        $mx | Sort-Object -Property Preference | ForEach-Object {
            Write-Host "✔ MX: $($_.NameExchange) (Pref $($_.Preference))" -ForegroundColor Green
        }
    } catch {
        Write-Host "✖ MX lookup failed" -ForegroundColor Red
    }

    # SPF
    Write-Host "`n[SPF]" -ForegroundColor Yellow
    try {
        $spf = (Resolve-DnsName -Name $Domain -Type TXT -ErrorAction Stop).Strings |
            Where-Object { $_ -match "^v=spf1" }
        if ($spf) {
            Write-Host "✔ SPF Found:" -ForegroundColor Green
            Write-Host "  $spf"
        } else {
            Write-Host "✖ SPF NOT found" -ForegroundColor Red
        }
    } catch {
        Write-Host "✖ SPF lookup failed" -ForegroundColor Red
    }

    # Detect Microsoft 365
    $isM365 = $false
    if ($spf -match "spf.protection.outlook.com") { $isM365 = $true }

    # DMARC
    Write-Host "`n[DMARC]" -ForegroundColor Yellow
    try {
        $dmarc = (Resolve-DnsName -Name "_dmarc.$Domain" -Type TXT -ErrorAction Stop).Strings
        if ($dmarc) {
            Write-Host "✔ DMARC Found:" -ForegroundColor Green
            Write-Host "  $dmarc"

            if ($dmarc -match "p=none")      { Write-Host "  Policy: NONE (monitor only)" -ForegroundColor DarkYellow }
            if ($dmarc -match "p=quarantine"){ Write-Host "  Policy: QUARANTINE" -ForegroundColor Yellow }
            if ($dmarc -match "p=reject")    { Write-Host "  Policy: REJECT (enforced)" -ForegroundColor Green }
        } else {
            Write-Host "✖ DMARC NOT found" -ForegroundColor Red
        }
    } catch {
        Write-Host "✖ DMARC lookup failed" -ForegroundColor Red
    }

    # DKIM
    Write-Host "`n[DKIM]" -ForegroundColor Yellow

    if ($isM365) {
        $selectors = "selector1","selector2"
    } else {
        $selectors = "selector1","selector2","default","dkim","smtp","mail"
    }

    $found = $false
    foreach ($sel in $selectors) {
        try {
            $dkim = (Resolve-DnsName "$sel._domainkey.$Domain" -Type TXT -Server 8.8.8.8 -ErrorAction Stop).Strings
            if ($dkim -match "v=DKIM1") {
                Write-Host "✔ DKIM Found ($sel)" -ForegroundColor Green
                Write-Host "  $dkim"
                $found = $true
                break
            }
        } catch {}
    }

    if (-not $found) {
        Write-Host "✖ DKIM NOT found (or unknown selector)" -ForegroundColor Red
    }

    # BIMI
    Write-Host "`n[BIMI]" -ForegroundColor Yellow
    try {
        $bimi = (Resolve-DnsName "default._bimi.$Domain" -Type TXT -ErrorAction Stop).Strings
        if ($bimi -match "v=BIMI1") {
            Write-Host "✔ BIMI Found" -ForegroundColor Green
            Write-Host "  $bimi"
        } else {
            Write-Host "✖ BIMI record found but invalid" -ForegroundColor Red
        }
    } catch {
        Write-Host "✖ BIMI NOT found" -ForegroundColor Red
    }

    Write-Host "`n=== DONE ==="
}
