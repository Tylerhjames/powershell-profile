# Optional PowerShell 7 feedback provider; install per user on each workstation.
function Initialize-RoamingCommandNotFound {
    [CmdletBinding()]
    param([string]$LoaderPath = $PROFILE.CurrentUserCurrentHost)

    if ($PSVersionTable.PSVersion -lt [version]'7.4' -or $env:OS -ne 'Windows_NT') { return }

    # PowerToys appends an unconditional import outside the Git-managed profile.
    # Migrate only that marked block, preserving all other loader customizations.
    try {
        if ($LoaderPath -and (Test-Path -LiteralPath $LoaderPath)) {
            $text = [IO.File]::ReadAllText($LoaderPath)
            $pattern = '(?ms)(^#f45873b3-b655-43a6-b217-97c00aa0db58 PowerToys CommandNotFound module\r?\n)(.*?)(^#f45873b3-b655-43a6-b217-97c00aa0db58[ \t]*$)'
            $updated = [regex]::Replace($text, $pattern, {
                param($match)
                $body = [regex]::Replace($match.Groups[2].Value,
                    '(?m)^Import-Module -Name Microsoft\.WinGet\.CommandNotFound[ \t]*\r?$',
                    '# CommandNotFound is initialized by the roaming profile (with dependency repair).')
                $match.Groups[1].Value + $body + $match.Groups[3].Value
            })
            if ($updated -cne $text) {
                Copy-Item -LiteralPath $LoaderPath -Destination ($LoaderPath + '.commandnotfound-' + [guid]::NewGuid().ToString('N') + '.bak') -ErrorAction Stop
                [IO.File]::WriteAllText($LoaderPath, $updated, [Text.UTF8Encoding]::new($true))
            }
        }
    } catch {
        Write-Warning "Could not migrate the PowerToys profile import: $($_.Exception.Message)"
    }

    try {
        foreach ($dependency in @(
            @{ Name = 'Microsoft.WinGet.Client'; MinimumVersion = '1.11.460' },
            @{ Name = 'Microsoft.WinGet.CommandNotFound'; MinimumVersion = '1.0.6' }
        )) {
            try {
                Import-Module @dependency -Global -ErrorAction Stop
            } catch {
                Write-Host "Setting up $($dependency.Name) for this workstation..."
                Install-Module @dependency -Scope CurrentUser -Repository PSGallery -Force -ErrorAction Stop
                Import-Module @dependency -Global -ErrorAction Stop
            }
        }
    } catch {
        Write-Warning "Command suggestions unavailable; automatic setup will retry next startup. $($_.Exception.Message)"
    }
}
