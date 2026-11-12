. (Join-Path $PSScriptRoot 'RoamingSshKeys.ps1')

function global:Initialize-RoamingSsh {
    <#
    .SYNOPSIS
    Link shared SSH host settings and optionally import an existing resident key.
    .DESCRIPTION
    Run once per computer. Connect only the selected key when importing. On
    Windows, import requires an elevated PowerShell session and a local FIDO PIN.
    No keys are generated. Existing identity files are never overwritten.
    .EXAMPLE
    Initialize-RoamingSsh -ImportKey Nano
    #>
    [CmdletBinding()]
    param([string]$ImportKey)

    $ErrorActionPreference = 'Stop'
    $record=$null
    if ($ImportKey) {
        $record=@(Get-RoamingSshKeys | Where-Object Name -IEQ $ImportKey)
        if ($record.Count -ne 1) { throw 'Unknown key name. Register it through SSH & YubiKey Setup first.' }
        $record=$record[0]
    }
    $sshDir = Join-Path $HOME '.ssh'
    $config = Join-Path $sshDir 'config'
    $shared = Join-Path (Split-Path $PSScriptRoot -Parent) 'SSH\roaming.conf'
    if (-not (Test-Path -LiteralPath $shared)) { throw "Shared SSH settings missing: $shared" }
    $null = New-Item -ItemType Directory -Path $sshDir -Force
    # Relative Includes are based on ~/.ssh in both Git and native OpenSSH.
    $includePath = [IO.Path]::GetRelativePath($sshDir, $shared).Replace('\', '/')
    if ([IO.Path]::IsPathRooted($includePath)) {
        throw 'Place the profile checkout on the same drive as your Windows user profile for a portable SSH Include.'
    }
    $include = 'Include "' + $includePath + '"'
    $existing = if (Test-Path -LiteralPath $config) { [IO.File]::ReadAllText($config) } else { '' }
    if (@($existing -split '\r?\n' | ForEach-Object { $_.Trim() }) -notcontains $include) {
        if (Test-Path -LiteralPath $config) {
            Copy-Item -LiteralPath $config -Destination "$config.before-roaming-$([guid]::NewGuid().ToString('N'))"
        }
        # Reset Host/Match context before Include; preserve local settings first.
        [IO.File]::AppendAllText($config, "`n# Roaming profile host settings`nHost *`n$include`nHost *`n", [Text.UTF8Encoding]::new($false))
    }
    Write-Host 'Shared SSH host settings linked. Existing local settings take precedence.'
    if (-not $ImportKey) { return }

    $keygen = Get-RoamingSshKeygen
    $name = $record.FileName
    $publicLabel = $record.PublicLabel
    $expected = $record.Fingerprint
    $target = Join-Path $sshDir $name
    if ((Test-Path -LiteralPath $target) -or (Test-Path -LiteralPath "$target.pub")) {
        throw "Identity already exists: $target. Preserved without overwriting; use ssh -G arca to inspect configuration."
    }
    # Keep recovered files in the user's SSH directory, never in the Git repo.
    $importDir = Join-Path $sshDir ('resident-import-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $importDir
    $savedPath = $env:PATH
    Push-Location $importDir
    try {
        $env:PATH = "$(Split-Path $keygen -Parent);$savedPath"
        Write-Host "Connect ONLY the $ImportKey. Enter its PIN locally and touch when prompted."
        Write-Host 'Press Enter twice at the optional FILE passphrase prompts if you want no file passphrase.'
        $device = Get-RoamingSshFidoDevice
        Invoke-RoamingSshKeygen $keygen @('-K') -Device $device | Out-Host
        $matches = @(foreach ($pub in Get-ChildItem -LiteralPath $importDir -Filter '*.pub') {
            $fp = Get-RoamingSshFingerprint $keygen $pub.FullName
            if ($fp -ceq $expected) { $pub }
        })
        if ($matches.Count -ne 1) { throw "Expected exactly one matching $ImportKey identity; found $($matches.Count). Files retained at $importDir" }
        Copy-RoamingSshIdentity $matches[0].FullName $target $publicLabel
        Write-Host "Verified and imported $ImportKey identity: $target"
        Write-Host "Recovery copies retained at $importDir. Test a server alias configured for $ImportKey."
    } finally {
        $env:PATH = $savedPath
        Pop-Location
    }
}
