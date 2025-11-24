function PublicIP {
    $endpoints = @(
        "https://api.ipify.org",
        "https://ifconfig.me/ip",
        "https://ident.me"
    )

    foreach ($url in $endpoints) {
        try {
            $ip = Invoke-RestMethod $url -TimeoutSec 4
            if ($ip -and $ip -match '^\d{1,3}(\.\d{1,3}){3}$') {
                Write-Host "🌐 Public IP: $ip" -ForegroundColor Green
                return
            }
        }
        catch { }
    }

    Write-Host "❌ Unable to retrieve public IP from any provider" -ForegroundColor Red
}
function PublicIP {
    $endpoints = @(
        "https://api.ipify.org",
        "https://ifconfig.me/ip",
        "https://ident.me"
    )

    foreach ($url in $endpoints) {
        try {
            $ip = Invoke-RestMethod $url -TimeoutSec 4
            if ($ip -and $ip -match '^\d{1,3}(\.\d{1,3}){3}$') {
                Write-Host "🌐 Public IP: $ip" -ForegroundColor Green
                return
            }
        }
        catch { }
    }

    Write-Host "❌ Unable to retrieve public IP from any provider" -ForegroundColor Red
}
