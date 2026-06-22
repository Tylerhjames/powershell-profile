function FlushMe {
    <#
    .SYNOPSIS
    Flushes DNS cache and safely renews DHCP lease with RDP session detection.
    .DESCRIPTION
    Combined DNS flush + DHCP release/renew. Detects remote sessions and
    prompts before performing operations that could disconnect you.
    #>

    # Detect remote session via RDP session name or terminal services env var
    $isRemote = ($env:SESSIONNAME -match 'RDP') -or
                ($env:SESSIONNAME -ne 'Console') -or
                ($null -ne $env:CLIENTNAME -and $env:CLIENTNAME -ne '' -and $env:CLIENTNAME -ne $env:COMPUTERNAME)

    if ($isRemote) {
        Write-Host "`n⚠ You are in a remote session — renewing DHCP may disconnect you!" -ForegroundColor Yellow
        $choice = Read-Host "Type YES to continue"
        if ($choice -notmatch '^yes$') {
            Write-Host "Cancelled." -ForegroundColor Gray
            return
        }
    }

    Write-Host "Flushing DNS cache..." -ForegroundColor Cyan
    ipconfig /flushdns | Out-Null

    Write-Host "Releasing IP..." -ForegroundColor Cyan
    ipconfig /release | Out-Null

    Write-Host "Renewing IP..." -ForegroundColor Cyan
    ipconfig /renew | Out-Null

    Write-Host "Network renewed" -ForegroundColor Green
    ipconfig | Select-String 'IPv4|Subnet|Gateway'
}

Set-Alias -Name Renew-Safe -Value FlushMe -Scope Global
