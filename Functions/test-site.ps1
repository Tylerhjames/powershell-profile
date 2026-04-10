function Test-Site {
    param([string]$Target)

    if (-not $Target) {
        $Target = Read-Host "Enter hostname or URL"
    }

    # Strip protocol prefix if provided so we don't double it
    $hostname = $Target -replace '^https?://', '' -replace '/.*$', ''

    Write-Host "`nResolving $hostname..." -ForegroundColor Cyan
    try {
        Resolve-DnsName $hostname -ErrorAction Stop | Out-Null
        Write-Host "✅ DNS resolved" -ForegroundColor Green
    }
    catch {
        Write-Host "❌ DNS resolution failed: $_" -ForegroundColor Red
    }

    Write-Host "`nPinging $hostname..." -ForegroundColor Cyan
    if (Test-Connection $hostname -Count 2 -Quiet) {
        Write-Host "✅ Ping successful" -ForegroundColor Green
    }
    else {
        Write-Host "❌ Ping failed (ICMP may be blocked)" -ForegroundColor Red
    }

    Write-Host "`nTesting HTTPS..." -ForegroundColor Cyan
    try {
        $r = Invoke-WebRequest "https://$hostname" -UseBasicParsing -TimeoutSec 5
        Write-Host "✅ HTTP Status: $($r.StatusCode)" -ForegroundColor Green
    }
    catch {
        Write-Host "❌ HTTPS connection failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}
