function Invoke-InternetSpeedTest {
    <#
    .SYNOPSIS
        Internet speed test using Speedtest.net CLI (Ookla)
    
    .DESCRIPTION
        Downloads (if needed) and runs the official Speedtest.net CLI.
        Results are parsed and displayed with performance ratings.
        
        The CLI binary is cached in: ~/Documents/Git/powershell-profile/bin/
    
    .PARAMETER Force
        Force re-download of Speedtest CLI even if already present
    
    .PARAMETER AcceptLicense
        Automatically accept Speedtest license (skips prompt on first run)
    
    .EXAMPLE
        Invoke-InternetSpeedTest
        Run internet speed test
    
    .EXAMPLE
        Invoke-InternetSpeedTest -Force
        Force re-download CLI and run test
    #>
    
    [CmdletBinding()]
    param(
        [switch]$Force,
        [switch]$AcceptLicense
    )
    
    # ══════════════════════════════════════════════════════════════════════════
    # Configuration
    # ══════════════════════════════════════════════════════════════════════════
    
    $binRoot = Join-Path $HOME 'Documents\Git\powershell-profile\bin'
    $speedtestExe = Join-Path $binRoot 'speedtest.exe'
    $downloadUrl = 'https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-win64.zip'
    
    # ══════════════════════════════════════════════════════════════════════════
    # Helper Functions
    # ══════════════════════════════════════════════════════════════════════════
    
    function Install-SpeedtestCLI {
        Write-Host "`n📦 Speedtest CLI not found. Installing..." -ForegroundColor Cyan
        
        # Create bin directory if needed
        if (-not (Test-Path $binRoot)) {
            Write-Host "   Creating bin directory..." -ForegroundColor Gray
            New-Item -ItemType Directory -Path $binRoot -Force | Out-Null
        }
        
        $zipPath = Join-Path $binRoot 'speedtest.zip'
        
        try {
            # Download with progress
            Write-Host "   Downloading from Ookla..." -ForegroundColor Gray
            
            $ProgressPreference = 'SilentlyContinue'  # Faster downloads
            Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
            $ProgressPreference = 'Continue'
            
            Write-Host "   ✓ Downloaded" -ForegroundColor Green
            
            # Extract
            Write-Host "   Extracting archive..." -ForegroundColor Gray
            Expand-Archive -Path $zipPath -DestinationPath $binRoot -Force
            
            # Cleanup
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            
            # Verify installation
            if (Test-Path $speedtestExe) {
                Write-Host "   ✓ Installation complete`n" -ForegroundColor Green
                return $true
            } else {
                throw "Extraction succeeded but speedtest.exe not found"
            }
        }
        catch {
            Write-Host "   ✗ Installation failed: $_" -ForegroundColor Red
            Write-Host "`nTroubleshooting:" -ForegroundColor Yellow
            Write-Host "  • Check internet connection" -ForegroundColor Gray
            Write-Host "  • Verify Ookla website is accessible" -ForegroundColor Gray
            Write-Host "  • Try manual download: $downloadUrl" -ForegroundColor Gray
            return $false
        }
    }
    
    function Test-SpeedtestVersion {
        try {
            $versionOutput = & $speedtestExe --version 2>&1
            if ($versionOutput -match 'Speedtest') {
                return $true
            }
        } catch {}
        return $false
    }
    
    # ══════════════════════════════════════════════════════════════════════════
    # Main Execution
    # ══════════════════════════════════════════════════════════════════════════
    
    Write-Host "`n═══════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Internet Speed Test (Speedtest.net)" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════`n" -ForegroundColor Cyan
    
    # Check if CLI exists or force reinstall
    if ($Force -or -not (Test-Path $speedtestExe)) {
        if (-not (Install-SpeedtestCLI)) {
            return
        }
    }
    
    # Verify CLI is functional
    if (-not (Test-SpeedtestVersion)) {
        Write-Host "⚠️  Speedtest CLI appears corrupted. Reinstalling..." -ForegroundColor Yellow
        if (-not (Install-SpeedtestCLI)) {
            return
        }
    }
    
    # Build arguments
    $arguments = @('--format=json', '--progress=no')
    
    if ($AcceptLicense) {
        $arguments += '--accept-license'
        $arguments += '--accept-gdpr'
    }
    
    # Run speed test
    Write-Host "🌐 Running Speedtest.net analysis..." -ForegroundColor Cyan
    Write-Host "   (This may take 20-30 seconds)`n" -ForegroundColor Gray
    
    try {
        $jsonOutput = & $speedtestExe @arguments 2>&1
        
        # Check for errors
        if ($LASTEXITCODE -ne 0) {
            Write-Host "❌ Speedtest CLI returned error code: $LASTEXITCODE" -ForegroundColor Red
            Write-Host "`nRaw output:" -ForegroundColor Yellow
            Write-Host $jsonOutput
            return
        }
        
        # Parse JSON
        $result = $jsonOutput | ConvertFrom-Json -ErrorAction Stop
        
    }
    catch {
        Write-Host "❌ Failed to run or parse Speedtest results" -ForegroundColor Red
        Write-Host "   Error: $_" -ForegroundColor Yellow
        
        if ($jsonOutput) {
            Write-Host "`n   Raw output:" -ForegroundColor Gray
            Write-Host "   $jsonOutput"
        }
        
        Write-Host "`n   Try running with -Force to reinstall CLI" -ForegroundColor Yellow
        return
    }
    
    # ══════════════════════════════════════════════════════════════════════════
    # Parse and Display Results
    # ══════════════════════════════════════════════════════════════════════════
    
    $downloadMbps = [math]::Round(($result.download.bandwidth * 8) / 1MB, 2)
    $uploadMbps = [math]::Round(($result.upload.bandwidth * 8) / 1MB, 2)
    $latencyMs = [math]::Round($result.ping.latency, 1)
    $jitterMs = [math]::Round($result.ping.jitter, 1)
    
    # Server info
    $serverName = $result.server.name
    $serverLocation = "$($result.server.location), $($result.server.country)"
    
    # ISP info
    $ispName = $result.isp
    
    Write-Host "═══════════════════════════════════════" -ForegroundColor Green
    Write-Host "  Results" -ForegroundColor Green
    Write-Host "═══════════════════════════════════════`n" -ForegroundColor Green
    
    Write-Host "Server:      $serverName" -ForegroundColor White
    Write-Host "Location:    $serverLocation" -ForegroundColor White
    Write-Host "ISP:         $ispName`n" -ForegroundColor White
    
    Write-Host "Download:    $downloadMbps Mbps" -ForegroundColor Cyan
    Write-Host "Upload:      $uploadMbps Mbps" -ForegroundColor Cyan
    Write-Host "Latency:     $latencyMs ms" -ForegroundColor Cyan
    Write-Host "Jitter:      $jitterMs ms`n" -ForegroundColor Cyan
    
    # Performance rating
    $rating = if ($downloadMbps -ge 500) {
        @{ Message = "🚀 Excellent - Premium internet speeds!"; Color = 'Green' }
    } elseif ($downloadMbps -ge 200) {
        @{ Message = "✅ Great - Above-average performance"; Color = 'Green' }
    } elseif ($downloadMbps -ge 100) {
        @{ Message = "✔️  Good - Typical broadband speeds"; Color = 'Cyan' }
    } elseif ($downloadMbps -ge 50) {
        @{ Message = "⚠️  Fair - Below typical speeds"; Color = 'Yellow' }
    } else {
        @{ Message = "❌ Poor - Possible ISP issues or congestion"; Color = 'Red' }
    }
    
    Write-Host $rating.Message -ForegroundColor $rating.Color
    
    # Latency rating
    if ($latencyMs -le 20) {
        Write-Host "⚡ Excellent latency for gaming/video calls" -ForegroundColor Green
    } elseif ($latencyMs -le 50) {
        Write-Host "✔️  Good latency" -ForegroundColor Cyan
    } elseif ($latencyMs -le 100) {
        Write-Host "⚠️  Fair latency" -ForegroundColor Yellow
    } else {
        Write-Host "❌ High latency - may affect real-time applications" -ForegroundColor Red
    }
    
    Write-Host "`n📊 Result URL: $($result.result.url)" -ForegroundColor Gray
    Write-Host ""
}

# Alias
Set-Alias -Name speedtest -Value Invoke-InternetSpeedTest -Scope Global