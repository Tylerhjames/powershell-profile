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
        Write-Color "`n$global:CbitWarnGlyph You are in a remote session — renewing DHCP may disconnect you!" 'Warn'
        $choice = Read-Host "Type YES to continue"
        if ($choice -notmatch '^yes$') {
            Write-Color "Cancelled." 'Detail'
            return
        }
    }

    Write-Color "Flushing DNS cache..." 'Detail'
    ipconfig /flushdns | Out-Null

    Write-Color "Releasing IP..." 'Detail'
    ipconfig /release | Out-Null

    Write-Color "Renewing IP..." 'Detail'
    ipconfig /renew | Out-Null

    Write-Color "Network renewed" 'Good'
    ipconfig | Select-String 'IPv4|Subnet|Gateway'
}

Set-Alias -Name Renew-Safe -Value FlushMe -Scope Global
