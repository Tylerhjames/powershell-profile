function Test-Internet {
    Write-Host "`n🌐 Testing Internet Connectivity..." -ForegroundColor Cyan

    # Test DNS resolution
    Write-Host "`n🔎 DNS Test:" -ForegroundColor Yellow
    try {
        Resolve-DnsName "www.microsoft.com" -ErrorAction Stop | Out-Null
        Write-Host "✅ DNS resolution successful" -ForegroundColor Green
    }
    catch {
        Write-Host "❌ DNS resolution failed" -ForegroundColor Red
    }

    # Test Default Gateway
    Write-Host "`n🚪 Gateway Test:" -ForegroundColor Yellow
    try {
        $gateway = (Get-NetIPConfiguration | Where-Object {$_.IPv4DefaultGateway} | Select-Object -First 1).IPv4DefaultGateway.NextHop
        if ($gateway) {
            if (Test-Connection -ComputerName $gateway -Quiet -Count 2) {
                Write-Host "✅ Gateway reachable ($gateway)" -ForegroundColor Green
            } else {
                Write-Host "❌ Gateway unreachable ($gateway)" -ForegroundColor Red
            }
        }
        else {
            Write-Host "⚠ No default gateway detected" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "❌ Gateway test failed" -ForegroundColor Red
    }

    # Test Public Ping
    Write-Host "`n🛰 WAN Ping Test:" -ForegroundColor Yellow
    if (Test-Connection -ComputerName "8.8.8.8" -Quiet -Count 2) {
        Write-Host "✅ Internet ping reachable (8.8.8.8)" -ForegroundColor Green
    } else {
        Write-Host "❌ Internet ping failed" -ForegroundColor Red
    }

    # Test HTTPS capability
    Write-Host "`n🔐 HTTPS Test:" -ForegroundColor Yellow
    try {
        $response = Invoke-WebRequest -Uri "https://www.microsoft.com" -UseBasicParsing -TimeoutSec 5
        if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
            Write-Host "✅ HTTPS access confirmed" -ForegroundColor Green
        } else {
            Write-Host "❌ HTTPS returned unexpected status: $($response.StatusCode)" -ForegroundColor Red
        }
    }
    catch {
        Write-Host "❌ HTTPS access failed" -ForegroundColor Red
    }

    Write-Host "`n✅ Connectivity test complete.`n" -ForegroundColor Cyan
}
