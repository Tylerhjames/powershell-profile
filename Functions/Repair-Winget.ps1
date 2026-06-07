# ══════════════════════════════════════════════════════════════════════════════
# Repair-Winget — escalating winget self-repair
# ══════════════════════════════════════════════════════════════════════════════
# Why: roaming between machines, winget breaks three different ways:
#   Tier 1: winget.exe exists but %LOCALAPPDATA%\Microsoft\WindowsApps fell off
#           the user PATH (instant fix — session + persisted to HKCU).
#   Tier 2: App Installer is staged machine-wide but not registered for the
#           current account (common on fresh/elevated/secondary-admin logons).
#           Fixed via Add-AppxPackage -RegisterByFamilyName — no download.
#   Tier 3: Actually missing/broken. Microsoft's documented repair path:
#           Install-Module Microsoft.WinGet.Client; Repair-WinGetPackageManager
#           https://learn.microsoft.com/windows/package-manager/winget/troubleshooting
# Each tier re-tests and returns as soon as winget resolves. Cheapest fix wins.
# Note: winget CLI is unsupported in SYSTEM context (per MS docs) — we bail out.

function Repair-Winget {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $wingetUserDir = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'

    function Test-WingetResolves {
        # Refresh isn't needed for $env:Path edits (same session), but a prior
        # Appx registration drops winget.exe into the WindowsApps dir, so make
        # sure that dir is in the session PATH before testing.
        if (($env:Path -split ';') -notcontains $wingetUserDir -and (Test-Path "$wingetUserDir\winget.exe")) {
            $env:Path = "$($env:Path.TrimEnd(';'));$wingetUserDir"
        }
        return [bool](Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue)
    }

    # ── Pre-flight ──
    if (Test-WingetResolves) {
        Write-Verbose 'winget already resolves — nothing to repair.'
        return $true
    }
    if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
        Write-Warning 'winget CLI is not supported in SYSTEM context (MSIX packages cannot register for LocalSystem). Use the Microsoft.WinGet.Client module cmdlets instead.'
        return $false
    }

    # ── Tier 1: PATH repair ──
    if (Test-Path "$wingetUserDir\winget.exe") {
        Write-Host '⚙ winget.exe found but not on PATH — repairing PATH...' -ForegroundColor Yellow

        # Session PATH (fixes this shell immediately)
        $env:Path = "$($env:Path.TrimEnd(';'));$wingetUserDir"

        # Persist to HKCU. Raw registry read/write (not [Environment]::Set...)
        # so existing %VAR% expandable entries in the user PATH aren't
        # flattened to literal values.
        try {
            $regKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
            $raw = [string]$regKey.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $already = ($raw -split ';') | Where-Object {
                $_ -ieq '%LOCALAPPDATA%\Microsoft\WindowsApps' -or $_ -ieq $wingetUserDir
            }
            if (-not $already) {
                $newRaw = '%LOCALAPPDATA%\Microsoft\WindowsApps'
                if ($raw) { $newRaw = "$($raw.TrimEnd(';'));$newRaw" }
                $regKey.SetValue('Path', $newRaw, [Microsoft.Win32.RegistryValueKind]::ExpandString)
                Write-Verbose 'Persisted WindowsApps dir to HKCU\Environment Path.'
            }
            $regKey.Dispose()
        }
        catch {
            Write-Warning "Session PATH fixed, but persisting to registry failed: $_"
        }

        if (Test-WingetResolves) {
            Write-Host '✓ winget repaired (PATH)' -ForegroundColor DarkGreen
            return $true
        }
    }

    # ── Tier 2: re-register App Installer for this user ──
    # The package is often still staged under C:\Program Files\WindowsApps;
    # registration is per-user and is what creates the winget.exe alias.
    # Shelled to powershell.exe because the Appx module is unreliable under
    # PS 7 without the WinPS compatibility shim.
    Write-Host '⚙ Re-registering App Installer for current user...' -ForegroundColor Yellow
    & powershell.exe -NoProfile -NonInteractive -Command 'Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop' 2>$null
    if ($LASTEXITCODE -eq 0 -and (Test-WingetResolves)) {
        Write-Host '✓ winget repaired (package re-registered)' -ForegroundColor DarkGreen
        return $true
    }

    # ── Tier 3: full repair via Microsoft.WinGet.Client (MS-documented path) ──
    Write-Host '⚙ winget missing — running full repair (Microsoft.WinGet.Client / Repair-WinGetPackageManager). This downloads from PSGallery and may take a minute...' -ForegroundColor Yellow
    try {
        if (-not (Get-Module -ListAvailable Microsoft.WinGet.Client)) {
            if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
                Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -ErrorAction Stop | Out-Null
            }
            Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery -Scope CurrentUser -ErrorAction Stop | Out-Null
        }
        Import-Module Microsoft.WinGet.Client -ErrorAction Stop

        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($isAdmin) {
            # -AllUsers provisions for every account on the box — covers the
            # elevated/secondary-admin scenario so the fix sticks for both.
            Repair-WinGetPackageManager -AllUsers -Force -Latest -ErrorAction Stop
        } else {
            Repair-WinGetPackageManager -Force -Latest -ErrorAction Stop
        }
    }
    catch {
        Write-Warning "Repair-WinGetPackageManager failed: $_"
        return $false
    }

    if (Test-WingetResolves) {
        Write-Host '✓ winget repaired (full reinstall)' -ForegroundColor DarkGreen
        return $true
    }

    Write-Warning 'winget still not resolving after all repair tiers. A new shell (or reboot) may be required; otherwise install App Installer from the Microsoft Store.'
    return $false
}
