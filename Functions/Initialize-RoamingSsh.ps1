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
    param([ValidateSet('Nano', 'NFC')][string]$ImportKey)

    $ErrorActionPreference = 'Stop'
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

    if (-not $IsWindows) { throw 'Automated resident-key import currently supports Windows with Git OpenSSH.' }
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) { throw 'Open PowerShell as Administrator under the SAME Windows account, then repeat this import.' }
    $gitSsh = Get-ProfileGitSsh
    if (-not $gitSsh) { throw 'Git for Windows OpenSSH is required for resident-key import.' }
    $keygen = Join-Path (Split-Path $gitSsh -Parent) 'ssh-keygen.exe'
    $name = if ($ImportKey -eq 'Nano') { 'id_tyler_5cnano_resident' } else { 'id_tyler_5nfc_resident' }
    $expected = if ($ImportKey -eq 'Nano') { 'SHA256:4i1Rjisp469kzCb4ZdqwCY3rPopj7Yu2d6m3Z6Ynu1s' } else { 'SHA256:mt+unzaPxJS88nvCqkBtZVe/ovTRG56IZSsFdcSSJWg' }
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
        $env:PATH = "$(Split-Path $gitSsh -Parent);$savedPath"
        Write-Host "Connect ONLY the $ImportKey. Enter its PIN locally and touch when prompted."
        Write-Host 'Press Enter twice at the optional FILE passphrase prompts if you want no file passphrase.'
        & $keygen -K
        if ($LASTEXITCODE -ne 0) { throw "Resident retrieval failed ($LASTEXITCODE). Files retained at $importDir" }
        $matches = @(foreach ($pub in Get-ChildItem -LiteralPath $importDir -Filter '*.pub') {
            $fp = & $keygen -lf $pub.FullName
            if ($LASTEXITCODE -eq 0 -and (("$fp" -split '\s+')[1] -eq $expected)) { $pub }
        })
        if ($matches.Count -ne 1) { throw "Expected exactly one matching $ImportKey identity; found $($matches.Count). Files retained at $importDir" }
        $handle = $matches[0].FullName.Substring(0, $matches[0].FullName.Length - 4)
        # File.Copy refuses an existing destination, including concurrent changes.
        [IO.File]::Copy($handle, $target, $false)
        [IO.File]::Copy($matches[0].FullName, "$target.pub", $false)
        Write-Host "Verified and imported $ImportKey identity: $target"
        Write-Host "Recovery copies retained at $importDir. Test with: ssh arca"
    } finally {
        $env:PATH = $savedPath
        Pop-Location
    }
}
