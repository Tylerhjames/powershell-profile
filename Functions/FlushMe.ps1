function FlushMe {
    Write-Host "Flushing DNS cache..." -ForegroundColor Cyan
    ipconfig /flushdns | Out-Null

    Write-Host "Renewing IP address..." -ForegroundColor Cyan
    ipconfig /renew | Out-Null

    # Try restarting DNS Client service
    try {
        Write-Host "Restarting DNS Client service..." -ForegroundColor Cyan
        Restart-Service -Name "Dnscache" -Force -ErrorAction Stop
    }
    catch {
        Write-Host "DNS Client service restart skipped (permissions or OS limitation)" -ForegroundColor DarkYellow
    }

    Write-Host "✅ DNS refreshed and network stack renewed" -ForegroundColor Green
}
