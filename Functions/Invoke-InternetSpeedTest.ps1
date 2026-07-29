function Invoke-InternetSpeedTest {
    <#
    .SYNOPSIS
        Internet speed test using Speedtest.net CLI (Ookla)
    
    .DESCRIPTION
        Downloads (if needed) and runs the official Speedtest.net CLI.
        Results are parsed and displayed with performance ratings.
        
        The CLI binary is cached in: C:\Git\powershell-profile\bin\
    
    .PARAMETER Force
        Force re-download of Speedtest CLI even if already present
    
    .PARAMETER AcceptLicense
        Accept the Speedtest license/GDPR terms (defaults to $true). Required for every
        non-interactive run, since output is captured (2>&1) and the CLI cannot prompt.
        Suppress with -AcceptLicense:$false.
    
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
        [switch]$AcceptLicense = $true
    )
    
    # ══════════════════════════════════════════════════════════════════════════
    # Configuration
    # ══════════════════════════════════════════════════════════════════════════
    
    # Derive bin path from script location for portability across workstations
    $binRoot = if ($PSScriptRoot) { Join-Path (Split-Path $PSScriptRoot -Parent) 'bin' }
               else { 'C:\Git\powershell-profile\bin' }
    $speedtestExe = Join-Path $binRoot 'speedtest.exe'
    $downloadUrl = 'https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-win64.zip'
    
    # ══════════════════════════════════════════════════════════════════════════
    # Helper Functions
    # ══════════════════════════════════════════════════════════════════════════
    
    function Install-SpeedtestCLI {
        Write-Color "`n📦 Speedtest CLI not found. Installing..." 'Header'

        # Create bin directory if needed
        if (-not (Test-Path $binRoot)) {
            Write-Color "   Creating bin directory..." 'Detail'
            New-Item -ItemType Directory -Path $binRoot -Force | Out-Null
        }
        
        $zipPath = Join-Path $binRoot 'speedtest.zip'
        
        try {
            # Download with progress
            Write-Color "   Downloading from Ookla..." 'Detail'
            
            $ProgressPreference = 'SilentlyContinue'  # Faster downloads
            Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
            $ProgressPreference = 'Continue'
            
            Write-Color "   $($global:CbitCheck) Downloaded" 'Good'

            # Extract
            Write-Color "   Extracting archive..." 'Detail'
            Expand-Archive -Path $zipPath -DestinationPath $binRoot -Force
            
            # Cleanup
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            
            # Verify installation
            if (Test-Path $speedtestExe) {
                Write-Color "   $($global:CbitCheck) Installation complete`n" 'Good'
                return $true
            } else {
                throw "Extraction succeeded but speedtest.exe not found"
            }
        }
        catch {
            Write-Color "   $($global:CbitCross) Installation failed: $_" 'Bad'
            Write-Color "`nTroubleshooting:" 'Warn'
            Write-Color "  • Check internet connection" 'Detail'
            Write-Color "  • Verify Ookla website is accessible" 'Detail'
            Write-Color "  • Try manual download: $downloadUrl" 'Detail'
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
    
    Write-Color "`n═══════════════════════════════════════" 'Header'
    Write-Color "  Internet Speed Test (Speedtest.net)" 'Header'
    Write-Color "═══════════════════════════════════════`n" 'Header'
    
    # Check if CLI exists or force reinstall
    if ($Force -or -not (Test-Path $speedtestExe)) {
        if (-not (Install-SpeedtestCLI)) {
            return
        }
    }
    
    # Verify CLI is functional
    if (-not (Test-SpeedtestVersion)) {
        Write-Color "$($global:CbitWarnGlyph)  Speedtest CLI appears corrupted. Reinstalling..." 'Warn'
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
    Write-Color "🌐 Running Speedtest.net analysis..." 'Header'
    Write-Color "   (This may take 20-30 seconds)`n" 'Detail'
    
    try {
        $jsonOutput = & $speedtestExe @arguments 2>&1
        
        # Check for errors
        if ($LASTEXITCODE -ne 0) {
            Write-Color "$($global:CbitCross) Speedtest CLI returned error code: $LASTEXITCODE" 'Bad'
            Write-Color "`nRaw output:" 'Detail'
            Write-Host $jsonOutput
            return
        }
        
        # Parse JSON. On a first run the CLI records license acceptance and prints a
        # banner to stderr; 2>&1 merges it ahead of the JSON, so isolate the JSON object
        # (starts at the first '{') before converting.
        $rawText = ($jsonOutput | Out-String)
        $braceIdx = $rawText.IndexOf('{')
        $jsonText = if ($braceIdx -ge 0) { $rawText.Substring($braceIdx) } else { $rawText }
        $result = $jsonText | ConvertFrom-Json -ErrorAction Stop
        
    }
    catch {
        Write-Color "$($global:CbitCross) Failed to run or parse Speedtest results" 'Bad'
        Write-Color "   Error: $_" 'Warn'

        if ($jsonOutput) {
            Write-Color "`n   Raw output:" 'Detail'
            Write-Host "   $jsonOutput"
        }

        Write-Color "`n   Try running with -Force to reinstall CLI" 'Header'
        return
    }
    
    # ══════════════════════════════════════════════════════════════════════════
    # Parse and Display Results
    # ══════════════════════════════════════════════════════════════════════════
    
    $downloadMbps = [math]::Round(($result.download.bandwidth * 8) / 1000000, 2)
    $uploadMbps = [math]::Round(($result.upload.bandwidth * 8) / 1000000, 2)
    $latencyMs = [math]::Round($result.ping.latency, 1)
    $jitterMs = [math]::Round($result.ping.jitter, 1)
    
    # Server info
    $serverName = $result.server.name
    $serverLocation = "$($result.server.location), $($result.server.country)"
    
    # ISP info
    $ispName = $result.isp
    
    Write-Color "═══════════════════════════════════════" 'Header'
    Write-Color "  Results" 'Header'
    Write-Color "═══════════════════════════════════════`n" 'Header'

    Write-Color "Server:      $serverName"
    Write-Color "Location:    $serverLocation"
    Write-Color "ISP:         $ispName`n"

    Write-Color "Download:    $downloadMbps Mbps"
    Write-Color "Upload:      $uploadMbps Mbps"
    Write-Color "Latency:     $latencyMs ms"
    Write-Color "Jitter:      $jitterMs ms`n"

    # Performance rating
    $rating = if ($downloadMbps -ge 500) {
        @{ Message = "$($global:CbitCheck) Excellent - Premium internet speeds!"; Color = 'Good' }
    } elseif ($downloadMbps -ge 200) {
        @{ Message = "$($global:CbitCheck) Great - Above-average performance"; Color = 'Good' }
    } elseif ($downloadMbps -ge 100) {
        @{ Message = "$($global:CbitCheck)  Good - Typical broadband speeds"; Color = 'Good' }
    } elseif ($downloadMbps -ge 50) {
        @{ Message = "$($global:CbitWarnGlyph)  Fair - Below typical speeds"; Color = 'Warn' }
    } else {
        @{ Message = "$($global:CbitCross) Poor - Possible ISP issues or congestion"; Color = 'Bad' }
    }

    Write-Color $rating.Message $rating.Color

    # Latency rating
    if ($latencyMs -le 20) {
        Write-Color "⚡ Excellent latency for gaming/video calls" 'Good'
    } elseif ($latencyMs -le 50) {
        Write-Color "$($global:CbitCheck)  Good latency" 'Good'
    } elseif ($latencyMs -le 100) {
        Write-Color "$($global:CbitWarnGlyph)  Fair latency" 'Warn'
    } else {
        Write-Color "$($global:CbitCross) High latency - may affect real-time applications" 'Bad'
    }

    Write-Color "`n📊 Result URL: $($result.result.url)" 'Detail'
    Write-Host ""
}

# Alias
Set-Alias -Name speedtest -Value Invoke-InternetSpeedTest -Scope Global