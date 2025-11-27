function tech {
    Write-Host "`n=== CBIT Technician Menu ===" -ForegroundColor Cyan
    Write-Host "1) Net-Test"
    Write-Host "2) Public IP"
    Write-Host "3) Renew Network"
    Write-Host "4) Flush DNS"
    Write-Host "5) Check Email DNS"
    Write-Host "Q) Quit"

    switch (Read-Host "Select") {
        "1" { Net-Test }
        "2" { publicip }
        "3" { renew-safe }
        "4" { ipconfig /flushdns }
        "5" { Test-EmailDNS }
    }
}
