function Manage-RoamingSsh {
    <#
    .SYNOPSIS
    Add/edit SSH hosts, import existing keys, test, and publish verified changes.
    .DESCRIPTION
    Enrollment is explicit; never deletes keys or changes server authorizations. Pending work is
    kept in a local journal; live verification must be repeated after reopening.
    #>
    [CmdletBinding()]
    param()
    $ErrorActionPreference = 'Stop'
    $repo = Split-Path $PSScriptRoot -Parent
    $relative = 'SSH/roaming.conf'
    $config = Join-Path $repo $relative
    $registry = Join-Path $repo 'SSH/keys.json'
    $managed = @('SSH/roaming.conf','SSH/keys.json')
    $keys = @{}
    foreach ($entry in Get-RoamingSshKeys -Path $registry) { $keys[$entry.Name]='~/.ssh/'+$entry.FileName }
    $verified = @{}

    function Invoke-RswGit {
        param([string[]]$Arguments)
        $result = & git -C $repo @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Git failed: $($Arguments -join ' ')`n$($result -join "`n")" }
        ($result -join "`n").TrimEnd()
    }
    function Get-RswHash {
        $hashes=@((Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash,(Get-FileHash -LiteralPath $registry -Algorithm SHA256).Hash)
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($hashes -join ':')))
    }
    function Test-RswPublishStatus {
        param([string]$Status)
        $lines=@($Status -split '\r?\n' | Where-Object { $_ })
        $lines.Count -gt 0 -and @($lines | Where-Object { $_ -cnotin @(' M SSH/roaming.conf',' M SSH/keys.json') }).Count -eq 0
    }

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
            $group = ''
            $simple = $true
            for ($j=$start+1; $j -lt $stop; $j++) {
                $line = $lines[$j].Trim()
                if ($line -match '^#\s*RoamingGroup:\s*(.*)$') { $group=$Matches[1].Trim(); continue }
                if (-not $line -or $line.StartsWith('#')) { continue }
                if ($line -notmatch '^(HostName|User|IdentitiesOnly|IdentityFile)\s+(\S+)$' -or $fields.ContainsKey($Matches[1])) { $simple=$false; continue }
                $fields[$Matches[1]]=$Matches[2]
            }
            [pscustomobject]@{Start=$start; Stop=$stop; Names=$names; Fields=$fields; Simple=$simple; Group=$group}
        }
    }
    function New-RswConfig {
        param([string]$Text,[string]$Alias,[string]$Address,[string]$User,[string]$Key,[string]$Group)
        $groupSupplied=$PSBoundParameters.ContainsKey('Group')
        $Group=$Group.Trim()
        if ($Group.Length -gt 60 -or $Group -match '[\x00-\x1f\x7f-\x9f]') { throw 'Group: use up to 60 characters on one line.' }
        if ($Alias -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}$') { throw 'Alias: letters, numbers, dash or underscore only.' }
        if ($Address -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.:-]*$') { throw 'Enter a plain hostname or IP address, without spaces or SSH options.' }
        if ($User -notmatch '^[a-zA-Z_][a-zA-Z0-9_.-]*[$]?$') { throw 'Enter a plain login username.' }
        if (-not $keys.ContainsKey($Key)) { throw 'Select a registered key.' }
        $blocks = @(Get-RswBlocks $Text)
        $found = @($blocks | Where-Object { $Alias -in $_.Names })
        if ($found.Count -gt 1) { throw 'Alias occurs in multiple blocks. Review the config manually.' }
        $lines = [Collections.Generic.List[string]]::new()
        $lines.AddRange([string[]]($Text -split '\r?\n'))
        $names = $Alias
        if ($found.Count) {
            $block=$found[0]
            if (-not $groupSupplied) { $Group=$block.Group }
            if (-not $block.Simple -or @($block.Names | Where-Object { $_ -match '[*?!]' }).Count) { throw 'This block uses advanced settings; edit it manually.' }
            $names=$block.Names -join ' '
            # Preserve comments and whitespace adjacent to existing blocks.
            for ($i=$block.Stop-1; $i -gt $block.Start; $i--) {
                if ($lines[$i] -match '^\s*(HostName|User|IdentitiesOnly|IdentityFile)\s+' -or $lines[$i] -match '^\s*#\s*RoamingGroup:') { $lines.RemoveAt($i) }
            }
            $lines.RemoveAt($block.Start)
            $at=$block.Start
        } else {
            $final=@($blocks | Where-Object { $_.Names.Count -eq 1 -and $_.Names[0] -eq '*' } | Select-Object -Last 1)
            if (-not $final.Count -or $final[0].Stop -ne $lines.Count) { throw 'Expected a final Host * block. Review config manually.' }
            $at=$final[0].Start
        }
        $new=[string[]]@("Host $names","    HostName $Address","    User $User",'    IdentitiesOnly yes',"    IdentityFile $($keys[$Key])",'')
        if ($Group) { $new=[string[]](@($new[0],"    # RoamingGroup: $Group") + $new[1..($new.Count-1)]) }
        $lines.InsertRange($at,$new)
        ($lines -join "`n").TrimEnd()+"`n"
    }
    function Get-RswAliasRows {
        param([string]$Text,[string]$Search='')
        $rows=@(foreach ($block in Get-RswBlocks $Text) {
            foreach ($name in $block.Names) {
                if ($name -match '[*?!]') { continue }
                $keyName=@($keys.Keys | Where-Object { $keys[$_] -ceq $block.Fields.IdentityFile } | Sort-Object)
                $row=[pscustomobject]@{
                    Group=$(if ($block.Group) { $block.Group } else { 'Ungrouped' })
                    Alias=$name
                    Server=$(if ($block.Fields.HostName) { $block.Fields.HostName } else { $name })
                    Username=$(if ($block.Fields.User) { $block.Fields.User } else { '(inherited/default)' })
                    Key=$(if ($keyName.Count) { $keyName -join ', ' } elseif ($block.Fields.IdentityFile) { $block.Fields.IdentityFile } else { '(inherited/default)' })
                }
                # Literal case-insensitive search, not a regex or wildcard expression.
                if (-not $Search -or @($row.Group,$row.Alias,$row.Server,$row.Username,$row.Key | Where-Object { $_.IndexOf($Search,[StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count) { $row }
            }
        })
        $rows | Sort-Object Group,Server,Alias
    }
    function Show-RswAliases {
        $search=''
        while ($true) {
            $rows=@(Get-RswAliasRows ([IO.File]::ReadAllText($config)) -Search $search)
            Write-Host "`nConfigured SSH aliases$(if ($search) { " — search: $search" })"
            if (-not $rows.Count) { Write-Host 'No matching aliases.' }
            foreach ($section in ($rows | Group-Object Group)) {
                $heading="`n  ┌─ $($section.Name) $('─' * [Math]::Max(0,48-$section.Name.Length))"
                if (Get-Command Write-Color -ErrorAction SilentlyContinue) { Write-Color $heading 'Header' }
                else { Write-Host $heading -ForegroundColor Cyan }
                foreach ($server in ($section.Group | Group-Object Server)) {
                    Write-Host "  Server: $($server.Name)"
                    $server.Group | Format-Table Alias,Server,Username,Key -AutoSize -Wrap | Out-Host
                }
            }
            Write-Host "$($rows.Count) aliases shown. Shared configuration; local overrides may differ."
            Write-Host ('─' * 63)
            Write-Host '[S] Search  [A] Show all  [Q] Return to setup'
            switch ((Read-Host 'Choose [Enter: back]').Trim().ToUpperInvariant()) {
                'S' { $search=(Read-Host 'Find group, alias, address, username or key (Enter: all)').Trim() }
                'A' { $search='' }
                { $_ -in @('','Q') } { return }
                default { Write-Host 'Choose S, A or Q.' }
            }
        }
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
        # A failed retest must invalidate any earlier success.
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
            if (-not (Test-RswPublishStatus $status)) { throw 'Only unstaged wizard SSH config/registry changes may be published. Review other tracked/index changes first.' }
        }
        $pending=@($state.Aliases | Where-Object { $verified[$_] -ne $state.Hash })
        if ($pending.Count) {
            if ((Read-Host "Not yet verified: $($pending -join ', '). Run tests now? [Y/N]").Trim() -notin @('Y','YES')) { throw 'Not published: all pending aliases must pass testing.' }
            if (-not (Invoke-RswTests ($pending -join ','))) { return }
        }
        Invoke-RswGit @('fetch','origin') | Write-Host
        $remote=Invoke-RswGit @('rev-parse',"refs/remotes/origin/$branch")
        if ($remote -ne $state.Base -and $remote -ne $state.Commit) { throw 'Remote branch moved; reconcile manually. No merge or force-push performed.' }
        if ($state.Commit) { Invoke-RswGit @('show','--stat',$state.Commit) | Write-Host }
        else { Invoke-RswGit (@('diff','--')+$managed) | Write-Host }
        $pushUrl=Invoke-RswGit @('remote','get-url','--push','origin')
        Write-Host "Destination: $pushUrl / $branch"
        if ((Read-Host 'Commit (if needed) and push these changes? Type YES').Trim() -ine 'YES') { Write-Host 'Saved locally; not published. Choose 4 when ready.'; return }
        if ((Get-RswHash) -ne $state.Hash -or (Invoke-RswGit @('rev-parse','HEAD')) -ne $head -or (Invoke-RswGit @('branch','--show-current')) -ne $branch) { throw 'Repository changed during confirmation. Review and retest.' }
        $currentStatus=Invoke-RswGit @('status','--porcelain','--untracked-files=no')
        if (($state.Commit -and $currentStatus) -or (-not $state.Commit -and -not (Test-RswPublishStatus $currentStatus))) { throw 'Index or tracked files changed during confirmation.' }
        if (-not $state.Commit) {
            Invoke-RswGit @('diff','--check') | Write-Host
            Invoke-RswGit (@('add','--')+$managed) | Write-Host
            try { Invoke-RswGit (@('commit','-m','Update roaming SSH hosts and key registry','--')+$managed) | Write-Host }
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

    function Invoke-RswRollback {
        if (-not $state.Count -or $state.Commit) { throw 'Rollback is available only for uncommitted wizard changes.' }
        if ((Get-RswHash) -ne $state.Hash -or (Invoke-RswGit @('rev-parse','HEAD')) -ne $state.Base -or (Invoke-RswGit @('branch','--show-current')) -ne $state.Branch) { throw 'Repository changed; rollback stopped for manual review.' }
        if (Invoke-RswGit (@('diff','--cached','--name-only','--')+$managed)) { throw 'SSH files are staged; review before rollback.' }
        if ((Read-Host "Roll back ALL pending aliases/registry edits ($($state.Aliases -join ', '))? Type YES").Trim() -ine 'YES') { Write-Host 'Changes retained locally.'; return }
        if ((Get-RswHash) -ne $state.Hash -or (Invoke-RswGit @('rev-parse','HEAD')) -ne $state.Base -or (Invoke-RswGit @('branch','--show-current')) -ne $state.Branch) { throw 'Repository changed during confirmation; rollback stopped.' }
        $backupDir=Join-Path $localDir ('rollback-'+[guid]::NewGuid().ToString('N'))
        $null=New-Item -ItemType Directory -Path $backupDir
        Copy-Item -LiteralPath $config -Destination (Join-Path $backupDir 'roaming.conf')
        Copy-Item -LiteralPath $registry -Destination (Join-Path $backupDir 'keys.json')
        Invoke-RswGit (@('restore',('--source='+$state.Base),'--worktree','--')+$managed) | Out-Null
        if (Test-Path -LiteralPath $journal) { Remove-Item -LiteralPath $journal }
        $state.Clear(); $verified.Clear()
        $keys.Clear()
        foreach ($entry in Get-RoamingSshKeys -Path $registry) { $keys[$entry.Name]='~/.ssh/'+$entry.FileName }
        Write-Host "Pending SSH batch rolled back. Backup: $backupDir. Server authorizations and local keys retained."
    }
    function Invoke-RswTests {
        param([string]$Aliases)
        $requested=@($Aliases -split '[,\s]+' | Where-Object { $_ } | Select-Object -Unique)
        if (-not $requested.Count) { throw 'Enter at least one alias.' }
        foreach ($alias in $requested) {
            try { Test-RswHost $alias }
            catch {
                Write-Host "NOT VERIFIED: $alias — $_" -ForegroundColor Yellow
                if ($state.Count -and -not $state.Commit) {
                    if ((Read-Host '[R] Roll back pending SSH batch  [Enter] Keep changes and retry later').Trim() -ieq 'R') { Invoke-RswRollback }
                }
                return $false
            }
        }
        return $true
    }
    function Get-RswPublicKey {
        param([string]$Path,[string]$ExpectedFingerprint)
        if (-not (Test-Path -LiteralPath $Path)) { throw 'Public key missing. Choose 2 to import it, then 7 to resume.' }
        $exe=Get-ProfileGitSsh
        if (-not $exe) { throw 'Git OpenSSH is required to verify the public key.' }
        $keygen=Join-Path (Split-Path $exe -Parent) 'ssh-keygen.exe'
        $fingerprint=& $keygen -lf $Path
        if ($LASTEXITCODE -ne 0 -or (("$fingerprint" -split '\s+')[1] -cne $ExpectedFingerprint)) { throw 'Public key does not match the registered fingerprint; nothing copied.' }
        $text=[IO.File]::ReadAllText($Path).Trim()
        if ($text -notmatch '\A(sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) ([A-Za-z0-9+/]+={0,2})(?: [^\r\n]*)?\z') { throw 'Expected one supported security-key public key line.' }
        # Omit the optional comment so untrusted text never becomes shell syntax.
        "$($Matches[1]) $($Matches[2])"
    }
    function New-RswAuthorizeCommand {
        param([string]$User,[string]$PublicKey)
        if ($User -notmatch '^[a-zA-Z_][a-zA-Z0-9_.-]*[$]?$' -or $PublicKey -notmatch '\A(sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) [A-Za-z0-9+/]+={0,2}\z') { throw 'Invalid authorization command input.' }
        'sudo -u ''{0}'' -H sh -c ''set -eu; umask 077; mkdir -p "$HOME/.ssh"; touch "$HOME/.ssh/authorized_keys"; chmod 700 "$HOME/.ssh"; chmod 600 "$HOME/.ssh/authorized_keys"; if ! grep -qxF -- "$1" "$HOME/.ssh/authorized_keys"; then printf "\n%s\n" "$1" >> "$HOME/.ssh/authorized_keys"; fi; echo "Key authorized"'' sh ''{1}''' -f $User,$PublicKey
    }
    function Invoke-RswWalkthrough {
        param([string]$Alias,[switch]$DeferPublish)
        $blocks=@(Get-RswBlocks ([IO.File]::ReadAllText($config)) | Where-Object { $Alias -in $_.Names })
        if ($blocks.Count -ne 1 -or -not $blocks[0].Simple) { throw 'Choose one existing simple alias.' }
        $fields=$blocks[0].Fields
        $entry=@(Get-RoamingSshKeys -Path $registry | Where-Object { ('~/.ssh/'+$_.FileName) -ceq $fields.IdentityFile })
        if ($entry.Count -ne 1) { throw 'Alias must use one registered key.' }
        $userName=$fields.User
        if ($userName -notmatch '^[a-zA-Z_][a-zA-Z0-9_.-]*[$]?$') { throw 'Unsupported username for the Linux walkthrough.' }
        $pub=Join-Path (Join-Path $HOME '.ssh') ($entry[0].FileName+'.pub')
        Write-Host "`nSTEP 1 OF 3 — AUTHORIZE THE KEY"
        Write-Host "Alias: $Alias -> $userName@$($fields.HostName) | Key: $($entry[0].Name)"
        $publicKey=Get-RswPublicKey $pub $entry[0].Fingerprint
        $command=New-RswAuthorizeCommand $userName $publicKey
        Write-Host "ON SERVER $($fields.HostName) — existing Linux SSH session with sudo access:"
        if (Get-Command Write-Color -ErrorAction SilentlyContinue) { Write-Color $command 'Warn' }
        else { Write-Host $command -ForegroundColor Yellow }
        Write-Host '1. Choose S to copy the complete command (public key included).'
        Write-Host '2. Paste into your server session and press Enter. Wait for: Key authorized.'
        Write-Host '3. Return here and choose T to test.'
        Write-Host "Existing keys are preserved. Account '$userName' must already exist. Already authorized? Choose T."
        while ($true) {
            Write-Host ('─' * 63)
            Write-Host '[S] Copy server command  [C] Copy public key  [T] Key authorized — test connection  [Q] Later'
            switch ((Read-Host 'Choose').Trim().ToUpperInvariant()) {
                'S' {
                    Set-Clipboard -Value $command
                    Write-Host "Server command copied. Paste/run it in your existing session on $($fields.HostName)."
                    Write-Host 'Press Enter. After Key authorized appears, return here and choose T.'
                }
                'C' {
                    if (-not (Test-Path -LiteralPath $pub)) { Write-Host 'Public key missing. Choose 2 to import this key, then 7 to resume.'; continue }
                    $exe=Get-ProfileGitSsh
                    if (-not $exe) { throw 'Git OpenSSH is required to verify the public key.' }
                    $keygen=Join-Path (Split-Path $exe -Parent) 'ssh-keygen.exe'
                    $fingerprint=& $keygen -lf $pub
                    if ($LASTEXITCODE -ne 0 -or (("$fingerprint" -split '\s+')[1] -cne $entry[0].Fingerprint)) { throw 'Public key does not match the registered fingerprint; nothing copied.' }
                    Set-Clipboard -Value $publicKey
                    Write-Host 'Public key only copied for manual use. S copies the complete Linux command.'
                }
                'T' {
                    Write-Host "`nSTEP 2 OF 3 — TEST CONNECTION"
                    Write-Host 'Unknown host? Independently verify its host fingerprint, then accept it using a normal SSH connection before this test.'
                    if (-not (Invoke-RswTests $Alias)) { if (-not $state.Count) { return }; continue }
                    if ($DeferPublish) { return }
                    Write-Host "`nSTEP 3 OF 3 — REVIEW & PUBLISH"
                    if (-not $state.Count) { Write-Host 'No pending wizard changes to publish.'; return }
                    Write-Host 'The next step shows the changes and Git destination before asking you to confirm.'
                    if ((Read-Host 'Review and publish now? Type YES; Enter to do it later').Trim() -ieq 'YES') { Publish-RswChanges }
                    else { Write-Host 'Verified in this session; saved locally, NOT PUBLISHED. Choose 4 to publish.' }
                    return
                }
                'Q' { Write-Host 'Saved locally, NOT PUBLISHED. Choose 7 to resume pending setup.'; return }
                default { Write-Host 'Choose S, C, T or Q.' }
            }
        }
    }

    function Invoke-RswResume {
        if (-not $state.Count) { Write-Host 'No pending setup. Choose 1 to add/edit a server, or 3 to test an existing alias.'; return }
        $pending=@($state.Aliases | Where-Object { $verified[$_] -ne $state.Hash } | Select-Object -Unique)
        if ($pending.Count) { Write-Host "Resuming: $($pending -join ', ')" }
        foreach ($alias in $pending) {
            Invoke-RswWalkthrough $alias -DeferPublish
            # Q or rollback must return to the menu, not advance to another host.
            if (-not $state.Count -or $verified[$alias] -ne $state.Hash) { return }
        }
        if ((Read-Host 'Pending setup ready. Review and publish now? Type YES; Enter for later').Trim() -ieq 'YES') { Publish-RswChanges }
        else { Write-Host 'Saved locally, NOT PUBLISHED. Choose 4 or 7 when ready.' }
    }

    $localDir=Join-Path $HOME '.ssh/roaming-wizard'
    $null=New-Item -ItemType Directory -Path $localDir -Force
    $repoId=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($repo))).Substring(0,16)
    $journal=Join-Path $localDir "$repoId.json"
    $state=if (Test-Path -LiteralPath $journal) { Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
    if ($state.Count -and $state.Version -ne 2) { throw 'Older pending SSH journal found. Finish it with the previous wizard or review it manually before upgrading; nothing changed.' }
    while ($true) {
        Write-Host "`nSSH & YubiKey Setup"
        Write-Host '[1] Add/edit server'
        Write-Host '[2] Set up this computer / import a registered key'
        Write-Host '[3] Test connection'
        Write-Host '[4] Review & publish'
        Write-Host '[5] Add a key (enroll or recover)'
        Write-Host '[6] View registered keys and local status'
        Write-Host '[7] Resume authorization / test / publish walkthrough'
        Write-Host '[8] Browse/search configured aliases'
        if ($state.Count) { Write-Host "Pending aliases: $($state.Aliases -join ', '). Commit: $($state.Commit). Tests must pass in this session." }
        Write-Host ('─' * 63)
        Write-Host '[Q] Return to menu...'
        try {
            switch ((Read-Host 'Choose').ToUpperInvariant()) {
                '1' {
                    if ($state.Commit) { throw 'Finish publishing the pending commit before editing again.' }
                    if ($state.Count) { if ((Get-RswHash) -ne $state.Hash) { throw 'External edit detected. Review manually before continuing.' } }
                    elseif (Invoke-RswGit @('status','--porcelain','--untracked-files=no')) { throw 'Tracked changes/index must be clean before starting wizard edits.' }
                    $alias=Read-Host 'Alias to add/edit (existing blocks retain all their aliases)'
                    $address=Read-Host 'Hostname or IP'
                    $userName=Read-Host 'Login username'
                    $key=Read-Host ('Key: '+(($keys.Keys | Sort-Object) -join ', '))
                    $original=[IO.File]::ReadAllText($config)
                    $blocks=@(Get-RswBlocks $original)
                    $existing=@($blocks | Where-Object { $alias -in $_.Names })
                    $defaultGroup=if ($existing.Count -eq 1) { $existing[0].Group } else {
                        $relatedGroups=@($blocks | Where-Object { $_.Fields.HostName -eq $address -and $_.Group } | ForEach-Object Group | Sort-Object -Unique)
                        if ($relatedGroups.Count -eq 1) { $relatedGroups[0] } else { '' }
                    }
                    $group=(Read-Host "Group [$(if ($defaultGroup) {$defaultGroup} else {'Ungrouped'})] (Enter: keep; -: clear)").Trim()
                    if (-not $group) { $group=$defaultGroup } elseif ($group -eq '-') { $group='' }
                    $proposal=New-RswConfig $original $alias $address $userName $key -Group $group
                    $changed=@(Get-RswBlocks $proposal | Where-Object { $alias -in $_.Names })[0]
                    Write-Host "Aliases: $($changed.Names -join ', ') -> $userName@$address / $($keys[$key])"
                    Write-Host "Group: $(if ($changed.Group) {$changed.Group} else {'Ungrouped'})"
                    Write-Host 'After saving: authorize the public key, test the connection, then review and publish.'
                    if ((Read-Host 'Save this configuration? Type YES').Trim() -ine 'YES') { Write-Host 'Cancelled: this alias change was NOT saved.'; break }
                    $backup=Join-Path $localDir ("roaming-"+[guid]::NewGuid().ToString('N')+'.conf')
                    Copy-Item -LiteralPath $config -Destination $backup
                    if (-not $state.Count) {
                        $state=@{Version=2; Base=(Invoke-RswGit @('rev-parse','HEAD')); Branch=(Invoke-RswGit @('branch','--show-current')); Aliases=@(); Commit=$null; Hash=(Get-RswHash)}
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
                    Invoke-RswWalkthrough $alias
                }
                '2' {
                    $key=Read-Host ('Key to import: '+(($keys.Keys | Sort-Object) -join ', ')+'; Enter only to link configuration')
                    if ($key) {
                        if (-not $keys.ContainsKey($key)) { throw 'Choose a registered key.' }
                        Initialize-RoamingSsh -ImportKey $key
                    } else { Initialize-RoamingSsh }
                    Write-Host 'Local setup only. No repository changes to publish.'
                }
                '3' { $null=Invoke-RswTests (Read-Host 'Aliases to test (comma separated)') }
                '4' { Publish-RswChanges }
                '5' {
                    if ($state.Commit) { throw 'Finish publishing the pending commit before adding a key.' }
                    if ($state.Count) { if ((Get-RswHash) -ne $state.Hash) { throw 'External edit detected. Review manually.' } }
                    elseif (Invoke-RswGit @('status','--porcelain','--untracked-files=no')) { throw 'Tracked changes/index must be clean before registering keys.' }
                    $before=Get-RswHash
                    $base=Invoke-RswGit @('rev-parse','HEAD')
                    $branch=Invoke-RswGit @('branch','--show-current')
                    $registered=@(Get-RoamingSshKeys -Path $registry)
                    $entry=Add-RoamingSshKey -RegisteredKeys $registered
                    if (-not $entry) { break }
                    if ((Get-RswHash) -ne $before -or (Invoke-RswGit @('rev-parse','HEAD')) -ne $base -or (Invoke-RswGit @('branch','--show-current')) -ne $branch) {
                        throw 'Repository changed during key setup. Local identity preserved; registry not updated. Review before continuing.'
                    }
                    Copy-Item -LiteralPath $registry -Destination (Join-Path $localDir ('keys-'+[guid]::NewGuid().ToString('N')+'.json'))
                    if (-not $state.Count) { $state=@{Version=2;Base=$base;Branch=$branch;Aliases=@();Commit=$null;Hash=$before} }
                    $json=ConvertTo-Json -InputObject @($registered+$entry) -Depth 4
                    [IO.File]::WriteAllText($registry,$json+"`n",[Text.UTF8Encoding]::new($false))
                    $state.Hash=Get-RswHash
                    $verified.Clear()
                    Save-RswJournal
                    $keys[$entry.Name]='~/.ssh/'+$entry.FileName
                    Write-Host 'Key registered locally; choose Review & publish to sync its public metadata. No server access has been granted.'
                }
                '6' {
                    foreach ($entry in Get-RoamingSshKeys -Path $registry) {
                        $identity=Join-Path (Join-Path $HOME '.ssh') $entry.FileName
                        $status=if ((Test-Path -LiteralPath $identity) -and (Test-Path -LiteralPath ($identity+'.pub'))) {'Local files present (not a live hardware test)'} else {'Import needed / incomplete local pair'}
                        Write-Host ("{0}: {1}`n  {2}`n  {3}" -f $entry.Name,$status,$entry.Fingerprint,$identity)
                    }
                }
                '7' {
                    Invoke-RswResume
                }
                '8' {
                    Show-RswAliases
                }
                'Q' { if ($state.Count) { Write-Host 'Pending work retained locally. Reopen this wizard, retest, then publish. No automatic push.' }; if (Get-Command Complete-TechMenuReturn -ErrorAction SilentlyContinue) { Complete-TechMenuReturn }; return }
                default { Write-Host 'Choose 1-8 or Q.' }
            }
        } catch { Write-Host "STOPPED: $_" -ForegroundColor Yellow }
    }
}
