# Public metadata only. Hardware operations run only on explicit invocation.
function global:Get-RoamingSshKeys {
    param([string]$Path = (Join-Path (Split-Path $PSScriptRoot -Parent) 'SSH/keys.json'))
    $records = @(Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
    if (-not $records.Count) { throw 'SSH key registry is empty.' }
    $names=@{}; $files=@{}; $prints=@{}
    foreach ($key in $records) {
        if ($key.Name -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,31}$' -or
            $key.FileName -notmatch '^id_[A-Za-z0-9_-]{1,64}$' -or
            $key.PublicLabel -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' -or
            $key.Fingerprint -cnotmatch '^SHA256:[A-Za-z0-9+/]{43}$') { throw 'Invalid SSH key registry entry.' }
        if ($names.ContainsKey($key.Name) -or $files.ContainsKey($key.FileName) -or $prints.ContainsKey($key.Fingerprint)) { throw 'Duplicate SSH key registry entry.' }
        $names[$key.Name]=$true; $files[$key.FileName]=$true; $prints[$key.Fingerprint]=$true
    }
    $records
}
function global:Get-RoamingSshKeygen {
    if (-not $IsWindows) { throw 'Resident-key setup currently requires Windows with Git OpenSSH.' }
    $admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) { throw 'Open Administrator PowerShell under the SAME Windows account to enroll or recover a key.' }
    $ssh=Get-ProfileGitSsh
    if (-not $ssh) { throw 'Git for Windows OpenSSH is required.' }
    $exe=Join-Path (Split-Path $ssh -Parent) 'ssh-keygen.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'Git ssh-keygen is missing.' }
    $exe
}
function global:Get-RoamingSshFidoDevice {
    $devices=@(Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object { $_.FriendlyName -eq 'HID-compliant fido' -and $_.InstanceId -like 'HID\VID_1050&*' })
    if ($devices.Count -ne 1) { throw "Connect exactly one YubiKey for enrollment or recovery (found $($devices.Count))." }
    $interfaceName='##?#'+$devices[0].InstanceId.Replace('\','#')+'#{4d1e55b2-f16f-11cf-88cb-001111000030}'
    $interfaces='HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\{4d1e55b2-f16f-11cf-88cb-001111000030}'
    $match=@(Get-ChildItem -LiteralPath $interfaces -ErrorAction Stop | Where-Object PSChildName -IEQ $interfaceName)
    if ($match.Count -ne 1) { throw 'Could not resolve the connected YubiKey USB interface. No hardware operation attempted.' }
    '\\?\'+$match[0].PSChildName.Substring(4)
}
function global:Invoke-RoamingSshKeygen {
    param([string]$Executable,[string[]]$Arguments,[string]$Device)
    $saved=$env:PATH
    $savedDevice=$env:ROAMING_SSH_FIDO_DEVICE
    try {
        $env:PATH="$(Split-Path $Executable -Parent);$saved"
        if ($Device) {
            $bash=Join-Path (Split-Path $Executable -Parent) 'bash.exe'
            if (-not (Test-Path -LiteralPath $bash)) { throw 'Git Bash is required for direct USB enrollment/recovery.' }
            $env:ROAMING_SSH_FIDO_DEVICE=$Device
            & $bash --noprofile --norc (Join-Path $PSScriptRoot 'Invoke-RoamingSshEnroll.sh').Replace('\','/') @Arguments
        } else { & $Executable @Arguments }
        if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed ($LASTEXITCODE). Existing keys preserved; working files retained." }
    } finally { $env:PATH=$saved; $env:ROAMING_SSH_FIDO_DEVICE=$savedDevice }
}
function global:Get-RoamingSshFingerprint {
    param([string]$Executable,[string]$PublicPath)
    $parts=([IO.File]::ReadAllText($PublicPath).Trim() -split '\s+',3)
    if ($parts[0] -notin 'sk-ssh-ed25519@openssh.com','sk-ecdsa-sha2-nistp256@openssh.com') { throw 'Expected a FIDO security-key public key.' }
    $out=Invoke-RoamingSshKeygen $Executable @('-l','-E','sha256','-f',$PublicPath)
    $fp=([string]($out -join ' ') -split '\s+')[1]
    if ($fp -cnotmatch '^SHA256:[A-Za-z0-9+/]{43}$') { throw 'Could not verify public fingerprint.' }
    $fp
}
function global:Copy-RoamingSshIdentity {
    param([string]$PublicPath,[string]$Target,[string]$PublicLabel)
    $handle=$PublicPath.Substring(0,$PublicPath.Length-4)
    if (-not (Test-Path -LiteralPath $handle -PathType Leaf)) { throw 'Recovered identity handle is missing.' }
    if ((Test-Path -LiteralPath $Target) -or (Test-Path -LiteralPath "$Target.pub")) { throw "Identity already exists: $Target. Nothing overwritten." }
    $parts=([IO.File]::ReadAllText($PublicPath).Trim() -split '\s+',3)
    # Write the normalized public file in the recovery directory, never in Git.
    [IO.File]::WriteAllText($PublicPath,"$($parts[0]) $($parts[1]) $PublicLabel`n",[Text.UTF8Encoding]::new($false))
    [IO.File]::Copy($handle,$Target,$false)
    try { [IO.File]::Copy($PublicPath,"$Target.pub",$false) }
    catch { throw "Public-file copy failed; identity retained at $Target and $handle. Review locally before retrying. $_" }
}
function global:Add-RoamingSshKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$RegisteredKeys)
    $ErrorActionPreference='Stop'
    $name=(Read-Host 'Name for this key (letters, numbers, dash or underscore)').Trim()
    if ($name -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,31}$') { throw 'Invalid key name.' }
    $file='id_roaming_'+$name.ToLowerInvariant()
    if (@($RegisteredKeys | Where-Object { $_.Name -ieq $name -or $_.FileName -ieq $file }).Count) { throw 'Key name or identity filename is already registered.' }
    $sshDir=Join-Path $HOME '.ssh'
    $target=Join-Path $sshDir $file
    if ((Test-Path -LiteralPath $target) -or (Test-Path -LiteralPath "$target.pub")) { throw "Identity already exists: $target. Nothing overwritten." }
    Write-Host '[1] Enroll a new resident SSH credential'
    Write-Host '[2] Recover and register an existing resident credential'
    Write-Host '[Q] Cancel'
    $mode=(Read-Host 'Choose').Trim().ToUpperInvariant()
    if ($mode -eq 'Q') { return }
    if ($mode -notin '1','2') { throw 'Choose 1, 2 or Q.' }
    $keygen=Get-RoamingSshKeygen
    Write-Host 'Connect ONLY the intended key. PINs and passphrases are entered directly into OpenSSH.'
    $requirePin=$false
    $device=Get-RoamingSshFidoDevice
    Write-Host 'Using the connected YubiKey USB interface directly.'
    if ($mode -eq '1') {
        Write-Host 'A FIDO2 PIN must already be set. Type it when asked; touch only when prompted.'
        Write-Host 'A NEW credential will be added to the hardware key; no reset or deletion is performed.'
        $pin=(Read-Host 'Require PIN verification for every login? [y/N] (No keeps touch-only behavior)').Trim()
        if ($pin -notmatch '^(?i:y|yes|n|no)?$') { throw 'Choose Y or N.' }
        $requirePin=$pin -match '^(?i:y|yes)$'
    }
    if ((Read-Host 'Proceed with the selected key? Type YES').Trim() -ine 'YES') {
        Write-Host 'Cancelled. No hardware operation performed.'
        return
    }
    $work=Join-Path $sshDir ('key-setup-'+[guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path $work -Force
    Write-Host "Recovery/working files will remain in $work (outside Git)."
    $expected=$null
    if ($mode -eq '1') {
        # Unique origin avoids replacing an existing resident credential with the same label.
        $application='ssh:roaming-'+$name.ToLowerInvariant()+'-'+[guid]::NewGuid().ToString('N')
        $args=@('-t','ed25519-sk','-O','resident','-O',"application=$application",'-C',$name,'-f',(Join-Path $work 'enrolled'))
        if ($requirePin) { $args+=@('-O','verify-required') }
        Invoke-RoamingSshKeygen $keygen $args -Device $device | Out-Host
        $expected=Get-RoamingSshFingerprint $keygen (Join-Path $work 'enrolled.pub')
        Write-Host "Created $expected. Now recover it from the same key to verify portability."
    }
    $recovery=Join-Path $work 'recovered'
    $null=New-Item -ItemType Directory -Path $recovery
    Push-Location $recovery
    try { Invoke-RoamingSshKeygen $keygen @('-K') -Device $device | Out-Host } finally { Pop-Location }
    $choices=@(foreach ($pub in Get-ChildItem -LiteralPath $recovery -Filter '*.pub' -File) {
        $fp=Get-RoamingSshFingerprint $keygen $pub.FullName
        if (-not $expected -or $fp -ceq $expected) { [pscustomobject]@{Path=$pub.FullName;Fingerprint=$fp} }
    })
    if (-not $choices.Count) { throw "No matching recovered credential. Files retained at $work; nothing registered." }
    if ($expected -and $choices.Count -ne 1) { throw 'Expected exactly one recovered enrollment fingerprint.' }
    for ($i=0;$i -lt $choices.Count;$i++) { Write-Host ("[{0}] {1}" -f ($i+1),$choices[$i].Fingerprint) }
    $selected=0
    if (-not [int]::TryParse((Read-Host 'Select the credential number to register'),[ref]$selected) -or $selected -lt 1 -or $selected -gt $choices.Count) { throw 'Invalid selection; nothing registered.' }
    $choice=$choices[$selected-1]
    if (@($RegisteredKeys | Where-Object Fingerprint -CEQ $choice.Fingerprint).Count) { throw 'This fingerprint is already registered; use Set up this computer to import it.' }
    Write-Host "Register $name as $file with fingerprint $($choice.Fingerprint)."
    if ((Read-Host 'Confirm fingerprint and key name? Type YES').Trim() -ine 'YES') {
        Write-Host 'Registration cancelled. Recovery files retained; nothing installed.'
        return
    }
    Copy-RoamingSshIdentity $choice.Path $target $name
    Write-Host "Local identity installed: $target. Authorize its .pub on servers separately; no server was changed."
    [pscustomobject]@{Name=$name;FileName=$file;PublicLabel=$name;Fingerprint=$choice.Fingerprint}
}
