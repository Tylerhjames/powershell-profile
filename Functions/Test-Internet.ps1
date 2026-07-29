function Test-Internet {
    Write-Color "`n🌐 Testing Internet Connectivity..." 'Header'

    # Test DNS resolution
    Write-Color "`n🔎 DNS Test:" 'Header'
    try {
        Resolve-DnsName "www.microsoft.com" -ErrorAction Stop | Out-Null
        Write-Color "$global:CbitCheck DNS resolution successful" 'Good'
    }
    catch {
        Write-Color "$global:CbitCross DNS resolution failed" 'Bad'
    }

    # Test Default Gateway
    Write-Color "`n🚪 Gateway Test:" 'Header'
    try {
        $gateway = (Get-NetIPConfiguration | Where-Object {$_.IPv4DefaultGateway} | Select-Object -First 1).IPv4DefaultGateway.NextHop
        if ($gateway) {
            if (Test-Connection -ComputerName $gateway -Quiet -Count 2) {
                Write-Color "$global:CbitCheck Gateway reachable ($gateway)" 'Good'
            } else {
                Write-Color "$global:CbitCross Gateway unreachable ($gateway)" 'Bad'
            }
        }
        else {
            Write-Color "$global:CbitWarnGlyph No default gateway detected" 'Warn'
        }
    }
    catch {
        Write-Color "$global:CbitCross Gateway test failed" 'Bad'
    }

    # Test Public Ping
    Write-Color "`n🛰 WAN Ping Test:" 'Header'
    if (Test-Connection -ComputerName "8.8.8.8" -Quiet -Count 2) {
        Write-Color "$global:CbitCheck Internet ping reachable (8.8.8.8)" 'Good'
    } else {
        Write-Color "$global:CbitCross Internet ping failed" 'Bad'
    }

    # Test HTTPS capability
    Write-Color "`n🔐 HTTPS Test:" 'Header'
    try {
        $response = Invoke-WebRequest -Uri "https://www.microsoft.com" -UseBasicParsing -TimeoutSec 5
        if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
            Write-Color "$global:CbitCheck HTTPS access confirmed" 'Good'
        } else {
            Write-Color "$global:CbitCross HTTPS returned unexpected status: $($response.StatusCode)" 'Bad'
        }
    }
    catch {
        Write-Color "$global:CbitCross HTTPS access failed" 'Bad'
    }

    Write-Color "`n$global:CbitCheck Connectivity test complete.`n" 'Good'
}
