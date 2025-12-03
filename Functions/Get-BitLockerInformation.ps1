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
    if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsRole]::Administrator)) {
        Write-Host "`nERROR: This function requires Administrator privileges!" -ForegroundColor Red
        Write-Host "Please run PowerShell as Administrator and try again.`n" -ForegroundColor Yellow
        return
    }

    function Show-BitLockerStatus {
        Write-Host "`n========================================" -ForegroundColor DarkGreen
        Write-Host "    BitLocker Status Report" -ForegroundColor DarkGreen
        Write-Host "========================================`n" -ForegroundColor DarkGreen
        
        $volumes = Get-BitLockerVolume
        
        if ($volumes.Count -eq 0) {
            Write-Host "No volumes found.`n" -ForegroundColor Yellow
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
        
        Write-Host "`nEnabling BitLocker on drive $DriveLetter..." -ForegroundColor Yellow
        
        $volume = Get-BitLockerVolume -MountPoint $DriveLetter -ErrorAction SilentlyContinue
        if (-not $volume) {
            Write-Host "ERROR: Drive $DriveLetter not found!`n" -ForegroundColor Red
            return
        }
        
        if ($volume.ProtectionStatus -eq "On") {
            Write-Host "Drive $DriveLetter is already protected by BitLocker.`n" -ForegroundColor Green
            return
        }
        
        Write-Host "`nSelect encryption method:" -ForegroundColor DarkGreen
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
                        Write-Host "ERROR: Passwords do not match!`n" -ForegroundColor Red
                        return
                    }
                    
                    Enable-BitLocker -MountPoint $DriveLetter -PasswordProtector -Password $password
                }
                "2" {
                    Enable-BitLocker -MountPoint $DriveLetter -RecoveryKeyProtector -RecoveryKeyPath "$env:USERPROFILE\Desktop"
                    Write-Host "`nRecovery key saved to Desktop!" -ForegroundColor Green
                }
                "3" {
                    $tpm = Get-Tpm
                    if ($tpm.TpmPresent -and $tpm.TpmReady) {
                        Enable-BitLocker -MountPoint $DriveLetter -TpmProtector
                        Add-BitLockerKeyProtector -MountPoint $DriveLetter -RecoveryPasswordProtector
                    } else {
                        Write-Host "ERROR: TPM is not available or ready!`n" -ForegroundColor Red
                        return
                    }
                }
                default {
                    Write-Host "Invalid selection!`n" -ForegroundColor Red
                    return
                }
            }
            
            Write-Host "`nBitLocker encryption started successfully!" -ForegroundColor Green
            Write-Host "Encryption will continue in the background.`n" -ForegroundColor Yellow
            
        } catch {
            Write-Host "ERROR: Failed to enable BitLocker - $($_.Exception.Message)`n" -ForegroundColor Red
        }
    }

    function Disable-BitLockerOnDrive {
        param ([string]$DriveLetter)
        
        Write-Host "`nWARNING: Disabling BitLocker will decrypt the drive!" -ForegroundColor Yellow
        Write-Host "This will leave your data unprotected." -ForegroundColor Yellow
        $confirm = Read-Host "Are you sure you want to continue? (yes/no)"
        
        if ($confirm -ne "yes") {
            Write-Host "Operation cancelled.`n" -ForegroundColor DarkGreen
            return
        }
        
        try {
            Write-Host "`nDisabling BitLocker on drive $DriveLetter..." -ForegroundColor Yellow
            Disable-BitLocker -MountPoint $DriveLetter
            Write-Host "BitLocker decryption started successfully!" -ForegroundColor Green
            Write-Host "Decryption will continue in the background.`n" -ForegroundColor Yellow
        } catch {
            Write-Host "ERROR: Failed to disable BitLocker - $($_.Exception.Message)`n" -ForegroundColor Red
        }
    }

    function Get-RecoveryKeys {
        Write-Host "`n========================================" -ForegroundColor DarkGreen
        Write-Host "    BitLocker Recovery Keys" -ForegroundColor DarkGreen
        Write-Host "========================================`n" -ForegroundColor DarkGreen
        
        $volumes = Get-BitLockerVolume | Where-Object { $_.ProtectionStatus -eq "On" }
        
        foreach ($volume in $volumes) {
            Write-Host "Drive: $($volume.MountPoint)" -ForegroundColor Yellow
            $recoveryProtectors = $volume.KeyProtector | Where-Object { $_.KeyProtectorType -eq "RecoveryPassword" }
            
            if ($recoveryProtectors) {
                foreach ($protector in $recoveryProtectors) {
                    Write-Host "  Recovery Password: $($protector.RecoveryPassword)" -ForegroundColor Green
                }
            } else {
                Write-Host "  No recovery password found" -ForegroundColor Red
            }
            Write-Host ""
        }
    }

    function Show-Menu {
        Write-Host "`n========================================" -ForegroundColor DarkGreen
        Write-Host "    BitLocker Management Menu" -ForegroundColor DarkGreen
        Write-Host "========================================" -ForegroundColor DarkGreen
        Write-Host "1. Show BitLocker Status" -ForegroundColor White
        Write-Host "2. Enable BitLocker on a Drive" -ForegroundColor White
        Write-Host "3. Disable BitLocker on a Drive" -ForegroundColor White
        Write-Host "4. Get Recovery Keys" -ForegroundColor White
        Write-Host "5. Exit" -ForegroundColor White
        Write-Host "========================================" -ForegroundColor DarkGreen
    }

    # Main script execution
    Clear-Host
    Write-Host "========================================" -ForegroundColor DarkGreen
    Write-Host "  BitLocker Management Tool" -ForegroundColor DarkGreen
    Write-Host "========================================" -ForegroundColor DarkGreen

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
                Write-Host "`nExiting...`n" -ForegroundColor DarkGreen
                break
            }
            default {
                Write-Host "`nInvalid choice! Please select 1-5.`n" -ForegroundColor Red
            }
        }
        
        if ($choice -ne "5") {
            Write-Host "`nPress Enter to continue..." -ForegroundColor Gray
            Read-Host
        }
        
    } while ($choice -ne "5")
}