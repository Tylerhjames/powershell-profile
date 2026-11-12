# Hardware, Git, servers, and the actual user SSH directory are never touched.
param([string]$SourceRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('roaming-key-tests-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory $fixtureRoot
$script:passed=0
function Assert($Condition,$Message){if(-not $Condition){throw "FAIL: $Message"};$script:passed++;Write-Host "PASS: $Message"}
function Reject([scriptblock]$Run,[string]$Pattern){$caught=$false;try{& $Run}catch{if("$_" -notmatch $Pattern){throw};$caught=$true};Assert $caught "Reject: $Pattern"}
$helper=Get-Content (Join-Path $SourceRoot 'Functions/RoamingSshKeys.ps1') -Raw
# Redirect only the local storage boundary to an isolated fixture; leave logic unchanged.
$helper=$helper.Replace("Join-Path `$HOME '.ssh'", "Join-Path `$fixtureRoot 'ssh'")
. ([scriptblock]::Create($helper))
$registry=Join-Path $SourceRoot 'SSH/keys.json'
$registered=@(Get-RoamingSshKeys $registry)
Assert ($registered.Count -eq 2 -and $registered[0].Name -eq 'Nano' -and $registered[1].Name -eq 'NFC') 'Legacy names preserved'
Assert ($registered[0].FileName -eq 'id_tyler_5cnano' -and $registered[0].Fingerprint -ceq 'SHA256:Y7WxfPgXN37X8FhrXzBUNaa8vLmaYnKm19BxHkUMOf0') 'Nano identity unchanged'
Assert ($registered[1].FileName -eq 'id_tyler_5cnfc' -and $registered[1].Fingerprint -ceq 'SHA256:QsJMtJGoabxp1a9/PABQ3S9dsxSPhyRIdFYT2ncIfmw') 'NFC identity unchanged'
$bad=Join-Path $fixtureRoot 'invalid.json'
'[{"Name":"Bad","FileName":"../../escape","Fingerprint":"bad"}]' | Set-Content $bad
Reject {Get-RoamingSshKeys $bad} 'Invalid SSH|property.*cannot be found'
ConvertTo-Json -InputObject @($registered[0],$registered[0]) | Set-Content $bad
Reject {Get-RoamingSshKeys $bad} 'Duplicate'
$script:answers=New-Object 'System.Collections.Generic.Queue[string]'
$script:recoverLabel='existing';$script:mismatch=$false;$script:failRecover=$false;$script:calls=New-Object 'System.Collections.Generic.List[object]'
function Read-Host {param($Prompt) if(-not $script:answers.Count){throw "Unexpected prompt: $Prompt"};$script:answers.Dequeue()}
function Queue-Answers([string[]]$Values){$script:answers.Clear();foreach($v in $Values){$script:answers.Enqueue($v)}}
function Get-RoamingSshKeygen {Join-Path $fixtureRoot 'ssh-keygen.exe'}
function Get-RoamingSshFidoDevice { '\\?\hid#fixture' }
function Invoke-RoamingSshKeygen {
    param([string]$Executable,[string[]]$Arguments,[string]$Device)
    $script:calls.Add(@($Arguments))
    if($Arguments[0] -eq '-t'){
        Assert ($Device -eq '\\?\hid#fixture') 'Enrollment explicitly selects the USB device'
        Assert ($Arguments[1] -eq 'ed25519-sk' -and 'resident' -in $Arguments) 'Enrollment uses resident FIDO key'
        Assert (@($Arguments | Where-Object {$_ -like 'application=ssh:roaming-*'}).Count -eq 1) 'Enrollment uses a unique SSH application'
        $path=$Arguments[[array]::IndexOf($Arguments,'-f')+1]
        $script:recoverLabel=$Arguments[[array]::IndexOf($Arguments,'-C')+1]
        [IO.File]::WriteAllText($path,'dummy handle')
        [IO.File]::WriteAllText($path+'.pub','sk-ssh-ed25519@openssh.com ZHVtbXk= '+$script:recoverLabel)
    }elseif($Arguments[0] -eq '-K'){
        if($script:failRecover){throw 'Mock recovery failure'}
        $label=if($script:mismatch){'wrong'}else{$script:recoverLabel}
        [IO.File]::WriteAllText((Join-Path $PWD 'recovered'),'dummy recovered handle')
        [IO.File]::WriteAllText((Join-Path $PWD 'recovered.pub'),'sk-ssh-ed25519@openssh.com ZHVtbXk= '+$label)
    }elseif($Arguments[0] -eq '-l'){
        $path=$Arguments[[array]::IndexOf($Arguments,'-f')+1]
        $label=([IO.File]::ReadAllText($path).Trim() -split '\s+')[2]
        $legacy=@($registered | Where-Object Name -eq $label)
        $fp=if($legacy.Count){$legacy[0].Fingerprint}else{'SHA256:'+([Convert]::ToBase64String([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($label)))).TrimEnd('=')}
        "256 $fp $label (ED25519-SK)"
    }else{throw 'Unexpected native invocation'}
}
Queue-Answers @('Nano');Reject {Add-RoamingSshKey $registered} 'already registered'
Queue-Answers @('../escape');Reject {Add-RoamingSshKey $registered} 'Invalid key name'
Queue-Answers @('Cancelled','Q');Assert ($null -eq (Add-RoamingSshKey $registered)) 'Cancel before hardware operation'
Assert ($script:calls.Count -eq 0) 'Validation/cancel did not call hardware'
Queue-Answers @('Backup','1','y','YES','1','YES')
$new=Add-RoamingSshKey $registered
Assert ($new.Name -eq 'Backup' -and $new.FileName -eq 'id_roaming_backup') 'New key registered by returned metadata'
Assert (Test-Path (Join-Path $fixtureRoot 'ssh/id_roaming_backup')) 'Recovered handle installed locally'
Assert (@($script:calls | Where-Object {$_[0] -eq '-t' -and 'verify-required' -in $_}).Count -eq 1) 'Requested per-login verification retained'
Queue-Answers @('Backup');Reject {Add-RoamingSshKey $registered} 'Identity already exists'
Queue-Answers @('Mismatch','1','','YES');$script:mismatch=$true
Reject {Add-RoamingSshKey $registered} 'No matching recovered'
Assert (-not(Test-Path (Join-Path $fixtureRoot 'ssh/id_roaming_mismatch'))) 'Wrong recovery never installed'
$script:mismatch=$false;$script:failRecover=$true
Queue-Answers @('Failed','2','YES');Reject {Add-RoamingSshKey $registered} 'Mock recovery failure'
$script:failRecover=$false;$script:recoverLabel='existing'
Queue-Answers @('Existing','2','YES','1','YES')
$existing=Add-RoamingSshKey $registered
Assert ($existing.Name -eq 'Existing') 'Existing resident key registration works'
$script:recoverLabel='Nano';Queue-Answers @('Duplicate','2','YES','1')
Reject {Add-RoamingSshKey $registered} 'fingerprint is already registered'
$script:recoverLabel='declined';Queue-Answers @('Declined','2','YES','1','NO')
Assert ($null -eq (Add-RoamingSshKey $registered)) 'Decline fingerprint confirmation'
Assert (-not(Test-Path (Join-Path $fixtureRoot 'ssh/id_roaming_declined'))) 'Decline did not install identity'
# Exercise the actual importer with only its filesystem root redirected.
$importer=Get-Content (Join-Path $SourceRoot 'Functions/Initialize-RoamingSsh.ps1') -Raw
$importer=$importer -replace '(?m)^\. \(Join-Path \$PSScriptRoot ''RoamingSshKeys.ps1''\)\r?\n',''
$importer=$importer.Replace("Join-Path `$HOME '.ssh'", "Join-Path `$fixtureRoot 'ssh'")
$importer=$importer.Replace("Join-Path (Split-Path `$PSScriptRoot -Parent) 'SSH\roaming.conf'", "Join-Path `$fixtureRoot 'roaming.conf'")
[IO.File]::WriteAllText((Join-Path $fixtureRoot 'roaming.conf'),'Host *')
. ([scriptblock]::Create($importer))
function Get-RoamingSshKeys {param($Path) @($registered+$new)}
foreach($name in 'Nano','NFC'){
    $script:recoverLabel=$name
    Initialize-RoamingSsh -ImportKey $name
    $record=@($registered | Where-Object Name -eq $name)[0]
    Assert (Test-Path (Join-Path $fixtureRoot ('ssh/'+$record.FileName))) "$name imports with original filename/fingerprint"
    Reject {Initialize-RoamingSsh -ImportKey $name} 'Identity already exists'
}
Reject {Initialize-RoamingSsh -ImportKey Unknown} 'Unknown key name'
# Reuse the registry name after removing only this fixture's new identity pair.
Remove-Item -LiteralPath (Join-Path $fixtureRoot 'ssh/id_roaming_backup'),(Join-Path $fixtureRoot 'ssh/id_roaming_backup.pub')
$script:recoverLabel='wrong'
Reject {Initialize-RoamingSsh -ImportKey Backup} 'exactly one matching'
$script:recoverLabel='Backup';Initialize-RoamingSsh -ImportKey Backup
Assert (Test-Path (Join-Path $fixtureRoot 'ssh/id_roaming_backup')) 'New registered key imports on another computer'
Write-Host "All $script:passed key checks passed. Synthetic fixtures retained: $fixtureRoot"
