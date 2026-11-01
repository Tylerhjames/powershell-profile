param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('ssh-menu-tests-'+[guid]::NewGuid().ToString('N'))
$repo=Join-Path $root 'repo';$remote=Join-Path $root 'remote.git'
New-Item -ItemType Directory -Path (Join-Path $repo 'Functions'),(Join-Path $repo 'SSH'),(Join-Path $root 'journal') -Force | Out-Null
Copy-Item (Join-Path $SourceRoot 'SSH/keys.json') (Join-Path $repo 'SSH/keys.json')
Set-Content (Join-Path $repo 'SSH/roaming.conf') 'Host *'
$source=Get-Content (Join-Path $SourceRoot 'Functions/Manage-RoamingSsh.ps1') -Raw
$source=$source.Replace("Join-Path `$HOME '.ssh/roaming-wizard'",("'"+(Join-Path $root 'journal').Replace("'","''")+"'"))
Set-Content (Join-Path $repo 'Functions/Manage-RoamingSsh.ps1') $source -Encoding utf8
function Git-Test([string[]]$Arguments){& git -C $repo @Arguments 2>&1 | Out-Null;if($LASTEXITCODE){throw ('Fixture git failed: '+($Arguments -join ' '))}}
& git init --bare $remote 2>&1 | Out-Null
Git-Test @('init','-b','main');Git-Test @('config','user.name','Wizard Tests');Git-Test @('config','user.email','tests@example.invalid')
Git-Test @('add','.');Git-Test @('commit','-m','fixture');Git-Test @('remote','add','origin',$remote);Git-Test @('push','-u','origin','main')
. (Join-Path $SourceRoot 'Functions/RoamingSshKeys.ps1')
. (Join-Path $repo 'Functions/Manage-RoamingSsh.ps1')
function Add-RoamingSshKey {param($RegisteredKeys) [pscustomobject]@{Name='Backup';FileName='id_roaming_backup';PublicLabel='Backup';Fingerprint=('SHA256:'+('A'*43))}}
$answers=New-Object 'System.Collections.Generic.Queue[string]'
foreach($answer in @('5','4','YES','6','Q')){$answers.Enqueue($answer)}
function Read-Host {param($Prompt) if(-not $answers.Count){throw ('Unexpected prompt: '+$Prompt)};$answers.Dequeue()}
$log=@(Manage-RoamingSsh 6>&1 | ForEach-Object ToString)
if(-not ($log -contains '[1] Add/edit server') -or -not ($log -contains '[5] Add a key (enroll or recover)')){throw 'Vertical menu missing'}
if(@($log | Where-Object {$_ -match '\[1\].*\[2\]'}).Count){throw 'Horizontal menu remains'}
if(@($log | Where-Object {$_ -like 'STOPPED:*'}).Count){throw ($log -join "`n")}
$keys=@(Get-RoamingSshKeys (Join-Path $repo 'SSH/keys.json'))
if($keys.Count -ne 3 -or $keys[2].Name -ne 'Backup'){throw 'Key registration not saved'}
$changed=@(& git -C $repo diff HEAD~1 HEAD --name-only)
if($changed.Count -ne 1 -or $changed[0] -ne 'SSH/keys.json'){throw 'Publish included wrong files'}
$local=& git -C $repo rev-parse HEAD
$published=(& git -C $repo ls-remote origin refs/heads/main) -split '\s+'
if($local -ne $published[0]){throw 'Publish did not reach fixture remote'}
if(@(Get-ChildItem (Join-Path $root 'journal') -Filter '*.json' | Where-Object Name -notlike 'keys-*').Count){throw 'Completed journal not cleared'}
'PASS: vertical menu, add-key integration, registry-only publish, exact-file scope, remote verification and journal cleanup'
'Fixture: '+$root
