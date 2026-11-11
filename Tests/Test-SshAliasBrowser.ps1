# Isolated configuration and UI fixtures; no SSH, clipboard or real config writes.
$ErrorActionPreference='Stop'
$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../Functions/Manage-RoamingSsh.ps1'),[ref]$null,[ref]$errors)
if($errors.Count){throw $errors}
foreach($name in @('Get-RswBlocks','New-RswConfig','Get-RswAliasRows','Show-RswAliases')) {
    $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($node.Extent.Text))
}
$passed=0
function Assert($Condition,$Message){if(-not $Condition){throw "FAIL: $Message"};$script:passed++;Write-Output "PASS: $Message"}
$keys=@{Nano='~/.ssh/nano';NFC='~/.ssh/nfc';Backup='~/.ssh/backup'}
$text="Host *`n"
$text=New-RswConfig $text ceph02 192.0.2.2 tyler Nano -Group 'RDC'
$text=New-RswConfig $text ceph02-nfc 192.0.2.2 tyler NFC -Group 'RDC'
$text=New-RswConfig $text ceph02-backup 192.0.2.2 tyler Backup -Group 'RDC'
$text=New-RswConfig $text proxy 192.0.2.3 admin Nano -Group 'Arca'
$text=New-RswConfig $text other 192.0.2.4 user Nano
$rows=@(Get-RswAliasRows $text)
Assert ($rows.Count -eq 5 -and '*' -notin $rows.Alias) 'Explicit aliases retained; wildcard excluded'
Assert (($rows | Where-Object Server -eq '192.0.2.2').Count -eq 3) 'Three key variants share one server section'
Assert ($rows[0].Group -eq 'Arca' -and $rows[-1].Group -eq 'Ungrouped') 'Group/server sort and ungrouped fallback'
foreach($query in @('rdc','CEPH02','192.0.2.2','tyler')) {Assert (@(Get-RswAliasRows $text $query).Count -eq 3) "Search: $query"}
Assert (@(Get-RswAliasRows $text 'nfc').Count -eq 1) 'Key name search'
Assert (@(Get-RswAliasRows $text '*').Count -eq 0) 'Search is literal, not wildcard'
Assert (@(Get-RswAliasRows $text 'absent').Count -eq 0) 'No matches'
$multi=$text.Replace('Host ceph02'+"`n",'Host ceph02 secondary'+"`n")
$edited=New-RswConfig $multi ceph02 192.0.2.2 tyler Nano
Assert ($edited.Contains('Host ceph02 secondary') -and ($edited -split '# RoamingGroup: RDC').Count -eq 4) 'Editing preserves alternate aliases and group when omitted'
$cleared=New-RswConfig $multi ceph02 192.0.2.2 tyler Nano -Group ''
Assert ((@(Get-RswBlocks $cleared | Where-Object {'ceph02' -in $_.Names})[0]).Group -eq '') 'Explicit empty group clears only selected block'
Assert ($cleared.Contains("Host ceph02-nfc`n    # RoamingGroup: RDC")) 'Other blocks unchanged'
$changed=New-RswConfig $text ceph02 192.0.2.2 tyler Nano -Group 'Lab'
Assert ((@(Get-RswBlocks $changed | Where-Object {'ceph02' -in $_.Names})[0]).Group -eq 'Lab') 'Group can be changed'
$failed=$false;try{New-RswConfig $text ceph02 192.0.2.2 tyler Nano -Group "bad`nHost injected" | Out-Null}catch{$failed=$true}
Assert $failed 'Group cannot inject SSH directives'
$config=[IO.Path]::GetTempFileName()
try {
    [IO.File]::WriteAllText($config,$text)
    $before=(Get-FileHash $config).Hash
    $script:inputs=[Collections.Generic.Queue[string]]::new([string[]]@('s','not-found','a','q'))
    $script:output=[Collections.Generic.List[string]]::new()
    function Read-Host {if(-not $script:inputs.Count){throw 'Unexpected prompt'};$script:inputs.Dequeue()}
    function Write-Host {param($Object,$ForegroundColor);$script:output.Add([string]$Object)}
    function Out-Host {param([Parameter(ValueFromPipeline)]$InputObject) process {}}
    Show-RswAliases
    Assert ($script:inputs.Count -eq 0 -and 'No matching aliases.' -in $script:output) 'Browser search/reset/quit flow'
    Assert ((Get-FileHash $config).Hash -eq $before) 'Browsing never changes configuration'
} finally {Remove-Item -LiteralPath $config}
Write-Output "All $passed alias browser checks passed."
