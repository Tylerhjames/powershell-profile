function Get-BitLockerInformation {
    <#
    .SYNOPSIS
        Interactive BitLocker management interface
    .DESCRIPTION
        Check status, enable, or disable BitLocker on drives with an easy menu
    .NOTES
        Requires Administrator privileges
    #>

    # Check for Administrator privileges
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-NOT $isAdmin) {
        Write-Color "`nERROR: This function requires Administrator privileges!" 'Bad'
        Write-Color "Please run PowerShell as Administrator and try again.`n" 'Warn'
        return
    }

    function Show-BitLockerStatus {
        Write-Color "`n========================================" 'Header'
        Write-Color "    BitLocker Status Report" 'Header'
        Write-Color "========================================`n" 'Header'

        $volumes = Get-BitLockerVolume

        if ($volumes.Count -eq 0) {
            Write-Color "No volumes found.`n" 'Warn'
            return $null
        }

        $statusTable = @()

        foreach ($volume in $volumes) {
            $statusTable += [PSCustomObject]@{
                'Drive'              = $volume.MountPoint
                'Status'             = $volume.VolumeStatus
                'Protected'          = $volume.ProtectionStatus
                'Encrypted'          = "$($volume.EncryptionPercentage)%"
                'Key Protectors'     = ($volume.KeyProtector | Measure-Object).Count
            }
        }

        $statusTable | Format-Table -AutoSize
        return $volumes
    }

    function Enable-BitLockerOnDrive {
        param ([string]$DriveLetter)

        Write-Color "`nEnabling BitLocker on drive $DriveLetter..." 'Detail'

        $volume = Get-BitLockerVolume -MountPoint $DriveLetter -ErrorAction SilentlyContinue
        if (-not $volume) {
            Write-Color "ERROR: Drive $DriveLetter not found!`n" 'Bad'
            return
        }

        if ($volume.ProtectionStatus -eq "On") {
            Write-Color "Drive $DriveLetter is already protected by BitLocker.`n" 'Good'
            return
        }

        Write-Color "`nSelect encryption method:" 'Header'
        Write-Host "1. Password protection"
        Write-Host "2. Recovery Key (saved to Desktop)"
        Write-Host "3. TPM (system drives only)"
        $encMethod = Read-Host "Enter choice (1-3)"

        try {
            switch ($encMethod) {
                "1" {
                    $password = Read-Host "Enter password" -AsSecureString
                    $passwordConfirm = Read-Host "Confirm password" -AsSecureString

                    $pwd1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($password))
                    $pwd2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($passwordConfirm))

                    if ($pwd1 -ne $pwd2) {
                        Write-Color "ERROR: Passwords do not match!`n" 'Bad'
                        return
                    }

                    Enable-BitLocker -MountPoint $DriveLetter -PasswordProtector -Password $password
                }
                "2" {
                    Enable-BitLocker -MountPoint $DriveLetter -RecoveryKeyProtector -RecoveryKeyPath "$env:USERPROFILE\Desktop"
                    Write-Color "`nRecovery key saved to Desktop!" 'Good'
                }
                "3" {
                    $tpm = Get-Tpm
                    if ($tpm.TpmPresent -and $tpm.TpmReady) {
                        Enable-BitLocker -MountPoint $DriveLetter -TpmProtector
                        Add-BitLockerKeyProtector -MountPoint $DriveLetter -RecoveryPasswordProtector
                    } else {
                        Write-Color "ERROR: TPM is not available or ready!`n" 'Bad'
                        return
                    }
                }
                default {
                    Write-Color "Invalid selection!`n" 'Bad'
                    return
                }
            }

            Write-Color "`nBitLocker encryption started successfully!" 'Good'
            Write-Color "Encryption will continue in the background.`n" 'Detail'

        } catch {
            Write-Color "ERROR: Failed to enable BitLocker - $($_.Exception.Message)`n" 'Bad'
        }
    }

    function Disable-BitLockerOnDrive {
        param ([string]$DriveLetter)

        Write-Color "`nWARNING: Disabling BitLocker will decrypt the drive!" 'Warn'
        Write-Color "This will leave your data unprotected." 'Warn'
        $confirm = Read-Host "Are you sure you want to continue? (yes/no)"

        if ($confirm -ne "yes") {
            Write-Color "Operation cancelled.`n" 'Good'
            return
        }

        try {
            Write-Color "`nDisabling BitLocker on drive $DriveLetter..." 'Detail'
            Disable-BitLocker -MountPoint $DriveLetter
            Write-Color "BitLocker decryption started successfully!" 'Good'
            Write-Color "Decryption will continue in the background.`n" 'Detail'
        } catch {
            Write-Color "ERROR: Failed to disable BitLocker - $($_.Exception.Message)`n" 'Bad'
        }
    }

    function Get-RecoveryKeys {
        Write-Color "`n========================================" 'Header'
        Write-Color "    BitLocker Recovery Keys" 'Header'
        Write-Color "========================================`n" 'Header'

        $volumes = Get-BitLockerVolume | Where-Object { $_.ProtectionStatus -eq "On" }

        foreach ($volume in $volumes) {
            Write-Color "Drive: $($volume.MountPoint)" 'Header'
            $recoveryProtectors = $volume.KeyProtector | Where-Object { $_.KeyProtectorType -eq "RecoveryPassword" }

            if ($recoveryProtectors) {
                foreach ($protector in $recoveryProtectors) {
                    Write-Color "  Recovery Password: $($protector.RecoveryPassword)"
                }
            } else {
                Write-Color "  No recovery password found" 'Bad'
            }
            Write-Host ""
        }
    }

    function Show-Menu {
        Write-Color "`n========================================" 'Header'
        Write-Color "    BitLocker Management Menu" 'Header'
        Write-Color "========================================" 'Header'
        Write-Host "1. Show BitLocker Status"
        Write-Host "2. Enable BitLocker on a Drive"
        Write-Host "3. Disable BitLocker on a Drive"
        Write-Host "4. Get Recovery Keys"
        Write-Host "5. Exit"
        Write-Color "========================================" 'Header'
    }

    # Main script execution
    Clear-Host
    Write-Color "========================================" 'Header'
    Write-Color "  BitLocker Management Tool" 'Header'
    Write-Color "========================================" 'Header'

    # Initial status check
    Show-BitLockerStatus

    # Main menu loop
    do {
        Show-Menu
        $choice = Read-Host "`nEnter your choice (1-5)"

        switch ($choice) {
            "1" {
                Show-BitLockerStatus
            }
            "2" {
                $drive = Read-Host "`nEnter drive letter (e.g., C:)"
                if ($drive -notmatch "^[A-Za-z]:$") {
                    $drive = $drive + ":"
                }
                Enable-BitLockerOnDrive -DriveLetter $drive
            }
            "3" {
                $drive = Read-Host "`nEnter drive letter (e.g., C:)"
                if ($drive -notmatch "^[A-Za-z]:$") {
                    $drive = $drive + ":"
                }
                Disable-BitLockerOnDrive -DriveLetter $drive
            }
            "4" {
                Get-RecoveryKeys
            }
            "5" {
                Write-Color "`nExiting...`n" 'Detail'
                break
            }
            default {
                Write-Color "`nInvalid choice! Please select 1-5.`n" 'Bad'
            }
        }

        if ($choice -ne "5") {
            Write-Color "`nPress Enter to continue..." 'Detail'
            Read-Host
        }

    } while ($choice -ne "5")
}