function Get-IPInfo {
    Write-Host "`n🖥  System Name: $env:COMPUTERNAME" -ForegroundColor Cyan
    Write-Host "🌐 Local IPv4:" -ForegroundColor Cyan
    Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.IPAddress -notlike '169.*'} | Format-Table IPAddress, InterfaceAlias -AutoSize

    Write-Host "`n🚪 Default Gateway:" -ForegroundColor Cyan
    Get-NetIPConfiguration | Select-Object -ExpandProperty IPv4DefaultGateway | Format-Table NextHop -AutoSize

    Write-Host "`n📡 DNS Servers:" -ForegroundColor Cyan
    Get-DnsClientServerAddress -AddressFamily IPv4 | Format-Table ServerAddresses, InterfaceAlias -AutoSize

    Write-Host "`n🌍 Public IP:" -ForegroundColor Cyan
    try {
        (Invoke-WebRequest -UseBasicParsing "https://api.ipify.org").Content
    }
    catch {
        Write-Host "Unable to retrieve public IP" -ForegroundColor Yellow
    }
    Write-Host ""
}
