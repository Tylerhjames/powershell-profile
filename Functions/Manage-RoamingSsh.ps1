function Manage-RoamingSsh {
    <#
    .SYNOPSIS
    Add/edit SSH hosts, import existing keys, test, and publish verified changes.
    .DESCRIPTION
    Never enrolls/deletes keys or changes server authorizations. Pending work is
    kept in a local journal; live verification must be repeated after reopening.
    #>
    [CmdletBinding()]
    param()
    $ErrorActionPreference = 'Stop'
    $repo = Split-Path $PSScriptRoot -Parent
    $relative = 'SSH/roaming.conf'
    $config = Join-Path $repo $relative
    $keys = @{ Nano='~/.ssh/id_tyler_5cnano'; NFC='~/.ssh/id_tyler_5cnfc' }
    $verified = @{}

    function Invoke-RswGit {
        param([string[]]$Arguments)
        $result = & git -C $repo @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Git failed: $($Arguments -join ' ')`n$($result -join "`n")" }
        ($result -join "`n").TrimEnd()
    }
    function Get-RswHash { (Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash }
    function Save-RswJournal { $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $journal -Encoding utf8 }
    function Get-RswBlocks {
        param([string]$Text)
        # Only support simple explicit host blocks. Refuse complex edits rather
        # than reinterpreting Includes, Match, wildcard hosts or custom directives.
        $lines = $Text -split '\r?\n'
        $starts = @(for ($i=0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*Host\s+') { $i } })
        foreach ($start in $starts) {
            $end = @($starts | Where-Object { $_ -gt $start } | Select-Object -First 1)
            $stop = if ($end.Count) { $end[0] } else { $lines.Count }
            $names = ($lines[$start] -replace '^\s*Host\s+','').Trim() -split '\s+'
            $fields = @{}
            $simple = $true
            for ($j=$start+1; $j -lt $stop; $j++) {
                $line = $lines[$j].Trim()
                if (-not $line -or $line.StartsWith('#')) { continue }
                if ($line -notmatch '^(HostName|User|IdentitiesOnly|IdentityFile)\s+(\S+)$' -or $fields.ContainsKey($Matches[1])) { $simple=$false; continue }
                $fields[$Matches[1]]=$Matches[2]
            }
            [pscustomobject]@{Start=$start; Stop=$stop; Names=$names; Fields=$fields; Simple=$simple}
        }
    }
    function New-RswConfig {
        param([string]$Text,[string]$Alias,[string]$Address,[string]$User,[string]$Key)
        if ($Alias -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}$') { throw 'Alias: letters, numbers, dash or underscore only.' }
        if ($Address -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.:-]*$') { throw 'Enter a plain hostname or IP address, without spaces or SSH options.' }
        if ($User -notmatch '^[a-zA-Z_][a-zA-Z0-9_.-]*[$]?$') { throw 'Enter a plain login username.' }
        if (-not $keys.ContainsKey($Key)) { throw 'Select Nano or NFC.' }
        $blocks = @(Get-RswBlocks $Text)
        $found = @($blocks | Where-Object { $Alias -in $_.Names })
        if ($found.Count -gt 1) { throw 'Alias occurs in multiple blocks. Review the config manually.' }
        $lines = [Collections.Generic.List[string]]::new()
        $lines.AddRange([string[]]($Text -split '\r?\n'))
        $names = $Alias
        if ($found.Count) {
            $block=$found[0]
            if (-not $block.Simple -or @($block.Names | Where-Object { $_ -match '[*?!]' }).Count) { throw 'This block uses advanced settings; edit it manually.' }
            $names=$block.Names -join ' '
            # Preserve comments and whitespace adjacent to existing blocks.
            for ($i=$block.Stop-1; $i -gt $block.Start; $i--) {
                if ($lines[$i] -match '^\s*(HostName|User|IdentitiesOnly|IdentityFile)\s+') { $lines.RemoveAt($i) }
            }
            $lines.RemoveAt($block.Start)
            $at=$block.Start
        } else {
            $final=@($blocks | Where-Object { $_.Names.Count -eq 1 -and $_.Names[0] -eq '*' } | Select-Object -Last 1)
            if (-not $final.Count -or $final[0].Stop -ne $lines.Count) { throw 'Expected a final Host * block. Review config manually.' }
            $at=$final[0].Start
        }
        $new=[string[]]@("Host $names","    HostName $Address","    User $User",'    IdentitiesOnly yes',"    IdentityFile $($keys[$Key])",'')
        $lines.InsertRange($at,$new)
        ($lines -join "`n").TrimEnd()+"`n"
    }
    function Invoke-RswSsh {
        param([string[]]$Arguments)
        $exe = Get-ProfileGitSsh
        if (-not $exe) { throw 'Install Git for Windows for the tested YubiKey SSH workflow.' }
        $savedPath=$env:PATH
        try {
            $env:PATH="$(Split-Path $exe -Parent);$savedPath"
            $output = & $exe @Arguments
            $code=$LASTEXITCODE
            [pscustomobject]@{Code=$code; Output=@($output)}
        } finally { $env:PATH=$savedPath }
    }
    function Test-RswHost {
        param([string]$Alias)
        # A failed or skipped retest must invalidate any earlier success.
        $verified.Remove($Alias)
        if ($Alias -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}$') { throw 'Enter an explicit host alias.' }
        $block=@(Get-RswBlocks ([IO.File]::ReadAllText($config)) | Where-Object { $Alias -in $_.Names })
        if ($block.Count -ne 1 -or -not $block[0].Simple) { throw 'Expected one simple host block.' }
        $expected=$block[0].Fields
        $before=Get-RswHash
        $resolved=Invoke-RswSsh @('-G',$Alias)
        if ($resolved.Code -ne 0) { throw 'SSH configuration validation failed.' }
        $values=@{}
        foreach ($line in $resolved.Output) {
            if ($line -match '^(hostname|user|identityfile|identitiesonly) (.+)$') {
                $values[$Matches[1]]=@($values[$Matches[1]]) + $Matches[2]
            }
        }
        $identities=@($values.identityfile | Where-Object { $_ })
        if ($values.hostname[-1] -ine $expected.HostName -or $values.user[-1] -cne $expected.User -or $identities.Count -ne 1 -or $identities[0] -cne $expected.IdentityFile -or $values.identitiesonly[-1] -ne 'yes') {
            throw 'Effective settings differ from the shared config (possibly a local override). Run ssh -G to inspect; no verification recorded.'
        }
        Write-Host "$Alias -> $($expected.User)@$($expected.HostName) using $($expected.IdentityFile)"
        Write-Host 'Live test uses public-key authentication only. Verify unknown host fingerprints separately first.'
        if ((Read-Host 'Test now? Type YES') -cne 'YES') { throw 'Live test skipped: NOT VERIFIED.' }
        $identity=$expected.IdentityFile -replace '^~/',($HOME.Replace('\','/')+'/')
        if (-not (Test-Path -LiteralPath $identity)) { throw 'Identity file missing. Import the selected key on this computer first.' }
        # Isolate from local Host/Match settings, agent identities and multiplexed
        # sessions; test exactly the displayed endpoint and identity.
        $result=Invoke-RswSsh @('-F','none','-o','StrictHostKeyChecking=yes','-o','IdentitiesOnly=yes','-o','IdentityAgent=none','-o','CertificateFile=none','-o','PreferredAuthentications=publickey','-o','PasswordAuthentication=no','-o','KbdInteractiveAuthentication=no','-o','ControlMaster=no','-o','ControlPath=none','-o','ConnectTimeout=15','-i',$identity,'-l',$expected.User,$expected.HostName,'echo ROAMING_SSH_VERIFIED')
        $result.Output | ForEach-Object { Write-Host $_ }
        if ($result.Code -ne 0 -or 'ROAMING_SSH_VERIFIED' -notin $result.Output) { throw 'Login/remote echo test failed: NOT VERIFIED. No password fallback was used.' }
        if ((Get-RswHash) -ne $before) { throw 'Configuration changed during testing; repeat verification.' }
        $verified[$Alias]=$before
        Write-Host 'VERIFIED: selected-key login succeeded.' -ForegroundColor Green
    }
    function Publish-RswChanges {
        if (-not $state.Count) { throw 'No wizard-owned changes to publish.' }
        if ((Get-RswHash) -ne $state.Hash) { throw 'Config changed outside the wizard. Stop and review it manually.' }
        $branch=Invoke-RswGit @('branch','--show-current')
        if ($branch -ne $state.Branch -or -not $branch) { throw 'Branch changed; stop and review.' }
        $head=Invoke-RswGit @('rev-parse','HEAD')
        if ($state.Commit) {
            if ($head -ne $state.Commit -or (Invoke-RswGit @('status','--porcelain','--untracked-files=no'))) { throw 'Committed state changed; review before pushing.' }
        } else {
            if ($head -ne $state.Base) { throw 'HEAD changed since editing; review before publishing.' }
            $status=Invoke-RswGit @('status','--porcelain','--untracked-files=no')
            if ($status -cne ' M SSH/roaming.conf') { throw 'Only unstaged wizard SSH config changes may be published. Review other tracked/index changes first.' }
        }
        foreach ($alias in $state.Aliases) {
            if ($verified[$alias] -ne $state.Hash) { throw "Test $alias successfully in this wizard session before publishing." }
        }
        Invoke-RswGit @('fetch','origin') | Write-Host
        $remote=Invoke-RswGit @('rev-parse',"refs/remotes/origin/$branch")
        if ($remote -ne $state.Base -and $remote -ne $state.Commit) { throw 'Remote branch moved; reconcile manually. No merge or force-push performed.' }
        if ($state.Commit) { Invoke-RswGit @('show','--stat',$state.Commit) | Write-Host }
        else { Invoke-RswGit @('diff','--',$relative) | Write-Host }
        $pushUrl=Invoke-RswGit @('remote','get-url','--push','origin')
        Write-Host "Destination: $pushUrl / $branch"
        if ((Read-Host 'Commit (if needed) and push these changes? Type YES') -cne 'YES') { Write-Host 'Saved locally; not published.'; return }
        if ((Get-RswHash) -ne $state.Hash -or (Invoke-RswGit @('rev-parse','HEAD')) -ne $head -or (Invoke-RswGit @('branch','--show-current')) -ne $branch) { throw 'Repository changed during confirmation. Review and retest.' }
        $currentStatus=Invoke-RswGit @('status','--porcelain','--untracked-files=no')
        if (($state.Commit -and $currentStatus) -or (-not $state.Commit -and $currentStatus -cne ' M SSH/roaming.conf')) { throw 'Index or tracked files changed during confirmation.' }
        if (-not $state.Commit) {
            Invoke-RswGit @('diff','--check') | Write-Host
            Invoke-RswGit @('add','--',$relative) | Write-Host
            try { Invoke-RswGit @('commit','-m',"Update roaming SSH hosts: $($state.Aliases -join ', ')",'--',$relative) | Write-Host }
            catch { throw "Commit failed; config may be staged. Review git status. $_" }
            $state.Commit=Invoke-RswGit @('rev-parse','HEAD')
            Save-RswJournal
        }
        Write-Host "Committed locally: $($state.Commit). Pushing..."
        Invoke-RswGit @('push','origin',"HEAD:refs/heads/$branch") | Write-Host
        $published=Invoke-RswGit @('ls-remote','--heads',$pushUrl,"refs/heads/$branch")
        if (($published -split '\s+')[0] -ne $state.Commit) { throw 'Push returned but remote commit was not confirmed. Local commit retained.' }
        Write-Host "PUBLISHED and confirmed: $($state.Commit)" -ForegroundColor Green
        Remove-Item -LiteralPath $journal
        $state.Clear()
    }

    $localDir=Join-Path $HOME '.ssh/roaming-wizard'
    $null=New-Item -ItemType Directory -Path $localDir -Force
    $repoId=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($repo))).Substring(0,16)
    $journal=Join-Path $localDir "$repoId.json"
    $state=if (Test-Path -LiteralPath $journal) { Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
    while ($true) {
        Write-Host "`nSSH & YubiKey Setup (existing Nano/NFC keys only)"
        Write-Host '[1] Add/edit server  [2] Set up this computer  [3] Test connection  [4] Review & publish  [Q] Back'
        if ($state.Count) { Write-Host "Pending aliases: $($state.Aliases -join ', '). Commit: $($state.Commit). Tests must pass in this session." }
        try {
            switch ((Read-Host 'Choose').ToUpperInvariant()) {
                '1' {
                    if ($state.Commit) { throw 'Finish publishing the pending commit before editing again.' }
                    if ($state.Count) { if ((Get-RswHash) -ne $state.Hash) { throw 'External edit detected. Review manually before continuing.' } }
                    elseif (Invoke-RswGit @('status','--porcelain','--untracked-files=no')) { throw 'Tracked changes/index must be clean before starting wizard edits.' }
                    $alias=Read-Host 'Alias to add/edit (existing blocks retain all their aliases)'
                    $address=Read-Host 'Hostname or IP'
                    $userName=Read-Host 'Login username'
                    $key=Read-Host 'Key: Nano or NFC'
                    $original=[IO.File]::ReadAllText($config)
                    $proposal=New-RswConfig $original $alias $address $userName $key
                    $changed=@(Get-RswBlocks $proposal | Where-Object { $alias -in $_.Names })[0]
                    Write-Host "Aliases: $($changed.Names -join ', ') -> $userName@$address / $($keys[$key])"
                    Write-Host 'Authorize the public key on the server separately. This wizard does not change the server.'
                    if ((Read-Host 'Save this configuration? Type YES') -cne 'YES') { break }
                    $backup=Join-Path $localDir ("roaming-"+[guid]::NewGuid().ToString('N')+'.conf')
                    Copy-Item -LiteralPath $config -Destination $backup
                    if (-not $state.Count) {
                        $state=@{Base=(Invoke-RswGit @('rev-parse','HEAD')); Branch=(Invoke-RswGit @('branch','--show-current')); Aliases=@(); Commit=$null; Hash=(Get-RswHash)}
                    }
                    if ([IO.File]::ReadAllText($config) -cne $original) { throw 'Config changed during preview; no save performed.' }
                    [IO.File]::WriteAllText($config,$proposal,[Text.UTF8Encoding]::new($false))
                    $state.Hash=Get-RswHash
                    # Every explicitly named alias in an edited multi-alias block
                    # shares the endpoint; one representative live test suffices.
                    $state.Aliases=@(@($state.Aliases)+$alias | Select-Object -Unique)
                    $verified.Clear()
                    Save-RswJournal
                    Write-Host "Saved locally. Backup: $backup. NOT PUBLISHED."
                    Test-RswHost $alias
                }
                '2' {
                    $key=Read-Host 'Enter Nano or NFC to import; Enter only to link configuration'
                    if ($key) {
                        if ($key -notin @('Nano','NFC')) { throw 'Choose Nano or NFC.' }
                        Initialize-RoamingSsh -ImportKey $key
                    } else { Initialize-RoamingSsh }
                    Write-Host 'Local setup only. No repository changes to publish.'
                }
                '3' { Test-RswHost (Read-Host 'Alias to test') }
                '4' { Publish-RswChanges }
                'Q' { if ($state.Count) { Write-Host 'Pending work retained locally. Reopen this wizard, retest, then publish. No automatic push.' }; return }
                default { Write-Host 'Choose 1, 2, 3, 4 or Q.' }
            }
        } catch { Write-Host "STOPPED: $_" -ForegroundColor Yellow }
    }
}
