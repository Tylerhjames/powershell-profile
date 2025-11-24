function Renew-Safe {
    if ($env:SESSIONNAME -match "RDP" -or $env:ComputerName -ne $env:CLIENTNAME) {
        Write-Host "⚠ You are in a remote session — renewing DHCP may disconnect you!" -ForegroundColor Yellow
        $choice = Read-Host "Type YES to continue"
        if ($choice -ne "YES") { return }
    }

    Write-Host "Releasing IP..." -ForegroundColor Cyan
    ipconfig /release

    Write-Host "Renewing IP..." -ForegroundColor Cyan
    ipconfig /renew

    Write-Host "✅ Network renewed safely" -ForegroundColor Green
}
