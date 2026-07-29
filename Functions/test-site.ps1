function Test-Site {
    param([string]$Target)

    if (-not $Target) {
        $Target = Read-Host "Enter hostname or URL"
    }

    # Strip protocol prefix if provided so we don't double it
    $hostname = $Target -replace '^https?://', '' -replace '/.*$', ''

    Write-Color "`nResolving $hostname..." 'Header'
    try {
        Resolve-DnsName $hostname -ErrorAction Stop | Out-Null
        Write-Color "$global:CbitCheck DNS resolved" 'Good'
    }
    catch {
        Write-Color "$global:CbitCross DNS resolution failed: $_" 'Bad'
    }

    Write-Color "`nPinging $hostname..." 'Header'
    if (Test-Connection $hostname -Count 2 -Quiet) {
        Write-Color "$global:CbitCheck Ping successful" 'Good'
    }
    else {
        Write-Color "$global:CbitCross Ping failed (ICMP may be blocked)" 'Bad'
    }

    Write-Color "`nTesting HTTPS..." 'Header'
    try {
        $r = Invoke-WebRequest "https://$hostname" -UseBasicParsing -TimeoutSec 5
        Write-Color "$global:CbitCheck HTTP Status: $($r.StatusCode)" 'Good'
    }
    catch {
        Write-Color "$global:CbitCross HTTPS connection failed: $($_.Exception.Message)" 'Bad'
    }
}
