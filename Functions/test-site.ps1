function Test-Site {
    param([string]$Target)

    if (-not $Target) { 
        $Target = Read-Host "Enter hostname or URL" 
    }

    Write-Host "`nResolving..." -ForegroundColor Cyan
    try {
        Resolve-DnsName $Target -ErrorAction Stop
        Write-Host "✅ DNS resolved" -ForegroundColor Green
    }
    catch {
        Write-Host "❌ DNS resolution failed" -ForegroundColor Red
    }

    Write-Host "`nPinging..." -ForegroundColor Cyan
    if (Test-Connection $Target -Count 2 -Quiet) {
        Write-Host "✅ Ping successful" -ForegroundColor Green
    }
    else {
        Write-Host "❌ Ping failed" -ForegroundColor Red
    }

    Write-Host "`nTesting HTTPS..." -ForegroundColor Cyan
    try {
        $r = Invoke-WebRequest "https://$Target" -UseBasicParsing -TimeoutSec 5
        Write-Host "✅ HTTP Status: $($r.StatusCode)" -ForegroundColor Green
    }
    catch {
        Write-Host "❌ HTTPS connection failed" -ForegroundColor Red
    }
}
