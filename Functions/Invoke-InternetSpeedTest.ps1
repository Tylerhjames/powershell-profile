function Invoke-InternetSpeedTest {

    $binRoot = Join-Path $HOME 'Documents\Git\powershell-profile\bin'
    $speedtestExe = Join-Path $binRoot 'speedtest.exe'
    $zipPath = Join-Path $binRoot 'speedtest.zip'
    $downloadUrl = "https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-win64.zip"

    if (!(Test-Path $binRoot)) { New-Item -ItemType Directory -Path $binRoot | Out-Null }

    if (!(Test-Path $speedtestExe)) {
        Write-Host "Downloading Speedtest CLI..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath
        Expand-Archive -Path $zipPath -DestinationPath $binRoot -Force
        Remove-Item $zipPath -Force
    }

    Write-Host "`nRunning Speedtest.net CLI..." -ForegroundColor Cyan

    $json = & $speedtestExe --accept-license --accept-gdpr --format=json --progress=no
    if (-not $json) {
        Write-Host "Speedtest CLI failed to run." -ForegroundColor Red
        return
    }

    $result = $json | ConvertFrom-Json

    $down = [math]::Round(($result.download.bandwidth * 8) / 1MB,2)
    $up   = [math]::Round(($result.upload.bandwidth   * 8) / 1MB,2)
    $lat  = [math]::Round($result.ping.latency,1)

    Write-Host "`n=== Internet Speed (Speedtest.net) ===" -ForegroundColor Cyan
    Write-Host "Download: $down Mbps"
    Write-Host "Upload:   $up Mbps"
    Write-Host "Latency:  $lat ms"

    if ($down -ge 400)      { $grade = "Excellent WAN performance ✅" }
    elseif ($down -ge 100) { $grade = "Typical ISP throughput ✅" }
    else                   { $grade = "Possible ISP throttling / congestion ⚠️" }

    Write-Host "`n$grade`n"
}
