# No hardware, network, user profile, or real repository changes.
param([string]$Source = (Join-Path $PSScriptRoot '../Functions/Manage-RoamingSsh.ps1'))
$ErrorActionPreference='Stop'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors -join "`n") }
foreach ($definition in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -match '^(Invoke|Get|New|Save|Test|Publish)-Rsw'},$true)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$script:passed=0
function Assert($Condition,$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:passed++; Write-Host "PASS: $Message" }
function Reject([scriptblock]$Code,[string]$Pattern) {
    $caught=$false
    try { & $Code } catch { if ("$_" -notmatch $Pattern) { throw }; $caught=$true }
    Assert $caught "Reject: $Pattern"
}
$keys=@{Nano='~/.ssh/id_tyler_5cnano'; NFC='~/.ssh/id_tyler_5cnfc'}
$text="Host arca cbit-arca 10.31.31.5`n    HostName 10.31.31.5`n    User tyler`n    IdentitiesOnly yes`n    IdentityFile ~/.ssh/id_tyler_5cnano`n`n# Preserve this comment`nHost *`n"
$new=New-RswConfig $text proxy2 10.31.31.4 tyler NFC
Assert ($new.Contains('IdentityFile ~/.ssh/id_tyler_5cnfc')) 'NFC selected'
Assert ($new.StartsWith($text.Substring(0,$text.IndexOf('Host *')))) 'Unrelated block/comment unchanged'
Assert ($new.TrimEnd().EndsWith('Host *')) 'Final context reset preserved'
$edit=New-RswConfig $text arca arca.example tyler Nano
Assert ($edit.Contains('Host arca cbit-arca 10.31.31.5')) 'Existing aliases retained'
Assert ($edit.Contains('# Preserve this comment')) 'Comments retained on edit'
Reject { New-RswConfig $text "bad`nHost *" host tyler Nano } 'Alias:'
Reject { New-RswConfig $text good '-oProxyCommand=bad' tyler Nano } 'plain hostname'
Reject { New-RswConfig $text good host 'user name' Nano } 'plain login'
Reject { New-RswConfig $text good host tyler Unknown } 'Select Nano'
Reject { New-RswConfig ($text.Replace('    User tyler',"    Port 2222`n    User tyler")) arca host tyler Nano } 'advanced'
Reject { New-RswConfig ($text+$text) arca host tyler Nano } 'multiple blocks'

$root=Join-Path ([IO.Path]::GetTempPath()) ('ssh-wizard-tests-'+[guid]::NewGuid().ToString('N'))
$repo=Join-Path $root 'repo'
$remote=Join-Path $root 'remote.git'
$null=New-Item -ItemType Directory -Path (Join-Path $repo 'SSH') -Force
$relative='SSH/roaming.conf'; $config=Join-Path $repo $relative
$journal=Join-Path $root 'journal.json'
[IO.File]::WriteAllText($config,$text)
& git init --bare $remote | Out-Null
Invoke-RswGit @('init','-b','main') | Out-Null
Invoke-RswGit @('config','user.name','Wizard Tests') | Out-Null
Invoke-RswGit @('config','user.email','tests@example.invalid') | Out-Null
Invoke-RswGit @('add','--',$relative) | Out-Null
Invoke-RswGit @('commit','-m','fixture') | Out-Null
Invoke-RswGit @('remote','add','origin',$remote) | Out-Null
Invoke-RswGit @('push','-u','origin','main') | Out-Null
$base=Invoke-RswGit @('rev-parse','HEAD')
[IO.File]::WriteAllText($config,$new)
$state=@{Base=$base; Branch='main'; Hash=(Get-RswHash); Aliases=@('proxy2'); Commit=$null}
$verified=@{}
Reject { Publish-RswChanges } 'Test proxy2'
$verified.proxy2=$state.Hash
[IO.File]::AppendAllText($config,'# external change')
Reject { Publish-RswChanges } 'outside the wizard'
[IO.File]::WriteAllText($config,$new)
Invoke-RswGit @('add','--',$relative) | Out-Null
Reject { Publish-RswChanges } 'Only unstaged'
Invoke-RswGit @('restore','--staged','--',$relative) | Out-Null
$script:answer='NO'
function Read-Host { param($Prompt) $script:answer }
Publish-RswChanges
Assert ((Invoke-RswGit @('rev-parse','HEAD')) -eq $base) 'Decline publish leaves HEAD unchanged'
# Push failure retains a retryable commit. Fetch remains valid; push URL fails.
Invoke-RswGit @('remote','set-url','--push','origin',(Join-Path $root 'missing.git')) | Out-Null
$script:answer='YES'
Reject { Publish-RswChanges } 'Git failed: push'
Assert ([bool]$state.Commit -and (Test-Path $journal)) 'Push failure preserves commit and journal'
Invoke-RswGit @('remote','set-url','--push','origin',$remote) | Out-Null
Publish-RswChanges
Assert (-not $state.Count -and -not (Test-Path $journal)) 'Publish retry clears pending state'
Assert ((Invoke-RswGit @('rev-parse','HEAD')) -eq ((Invoke-RswGit @('ls-remote','--heads','origin','refs/heads/main')) -split '\s+')[0]) 'Remote commit confirmed'
Assert (-not (Invoke-RswGit @('status','--porcelain'))) 'Fixture clean after publish'
Reject { Publish-RswChanges } 'No wizard-owned'

# Effective configuration mismatch must stop before any live authentication.
$verified=@{}
function Invoke-RswSsh {
    param([string[]]$Arguments)
    if ($Arguments[0] -ne '-G') { throw 'Unexpected live connection in mocked test' }
    [pscustomobject]@{Code=0; Output=@('hostname wrong.example','user tyler','identitiesonly yes','identityfile ~/.ssh/id_tyler_5cnfc')}
}
Reject { Test-RswHost proxy2 } 'Effective settings differ'
Assert (-not $verified.Count) 'Mismatched config never verified'
$script:sshCode=0
$script:sshMarker='ROAMING_SSH_VERIFIED'
$testIdentity=Join-Path $root 'dummy-identity'
[IO.File]::WriteAllText($testIdentity,'not a real key')
[IO.File]::WriteAllText($config,$new.Replace('~/.ssh/id_tyler_5cnfc',$testIdentity.Replace('\','/')))
function Invoke-RswSsh {
    param([string[]]$Arguments)
    if ($Arguments[0] -eq '-G') {
        return [pscustomobject]@{Code=0; Output=@('hostname 10.31.31.4','user tyler','identitiesonly yes',"identityfile $($testIdentity.Replace('\','/'))")}
    }
    Assert ('PasswordAuthentication=no' -in $Arguments -and 'IdentityAgent=none' -in $Arguments -and 'ControlPath=none' -in $Arguments -and $Arguments[1] -eq 'none') 'Live test forbids password, agent and reused sessions'
    [pscustomobject]@{Code=$script:sshCode; Output=@($script:sshMarker)}
}
$script:answer='NO'
Reject { Test-RswHost proxy2 } 'skipped'
$script:answer='YES'
$script:sshCode=255
Reject { Test-RswHost proxy2 } 'test failed'
$script:sshCode=0; $script:sshMarker='wrong marker'
Reject { Test-RswHost proxy2 } 'test failed'
$script:sshMarker='ROAMING_SSH_VERIFIED'
Test-RswHost proxy2
Assert ($verified.proxy2 -eq (Get-RswHash)) 'Successful test tied to exact config hash'
$script:sshCode=255
Reject { Test-RswHost proxy2 } 'test failed'
Assert (-not $verified.ContainsKey('proxy2')) 'Failed retest invalidates earlier success'
Write-Host "All $script:passed checks passed. Isolated fixtures retained: $root"
