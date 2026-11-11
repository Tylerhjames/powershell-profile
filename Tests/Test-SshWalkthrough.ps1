$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '../Functions/Manage-RoamingSsh.ps1'
$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$null,[ref]$errors)
if ($errors.Count) { throw $errors }
foreach ($name in @('Get-RswBlocks','Invoke-RswWalkthrough')) {
    $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($node.Extent.Text))
}
$config=[IO.Path]::GetTempFileName()
try {
    [IO.File]::WriteAllText($config,"Host fixture`n HostName 192.0.2.1`n User tyler`n IdentityFile ~/.ssh/fixture`n IdentitiesOnly yes`nHost *`n")
    function Get-RoamingSshKeys { [pscustomobject]@{Name='Fixture';FileName='fixture';Fingerprint='fixture'} }
    function Write-Host { param($Object,$ForegroundColor); $script:messages.Add([string]$Object) }
    function Read-Host { if (-not $script:answers.Count) {throw 'Unexpected prompt'}; $script:answers.Dequeue() }
    function Test-RswHost { $script:testCalls++; if($script:failTest){throw 'Simulated login failure'}; $verified.fixture='hash' }
    function Publish-RswChanges { $script:publishCalls++ }
    function Set-Clipboard { param($Value); $script:copied=$Value }
    $registry='unused'
    foreach ($scenario in @(
        @{Answers=@('q');Tests=0;Publish=0;Fail=$false},
        @{Answers=@('s','q');Tests=0;Publish=0;Fail=$false},
        @{Answers=@('t','yes');Tests=1;Publish=1;Fail=$false},
        @{Answers=@('t',' YeS ');Tests=1;Publish=1;Fail=$false},
        @{Answers=@('t','');Tests=1;Publish=0;Fail=$false},
        @{Answers=@('t','q');Tests=1;Publish=0;Fail=$true}
    )) {
        $script:answers=[Collections.Generic.Queue[string]]::new([string[]]$scenario.Answers)
        $script:messages=[Collections.Generic.List[string]]::new()
        $script:testCalls=0;$script:publishCalls=0;$script:failTest=$scenario.Fail
        $state=@{Aliases=@('fixture');Hash='hash'};$verified=@{}
        Invoke-RswWalkthrough fixture
        if($script:testCalls -ne $scenario.Tests -or $script:publishCalls -ne $scenario.Publish -or $script:answers.Count) {throw 'Walkthrough progression failed'}
        if(($script:messages -join "`n") -notmatch "sudo -u 'tyler'") {throw 'Target-account instructions missing'}
        if($scenario.Answers[0] -eq 's' -and $script:copied -notmatch 'cat >>') {throw 'Append command not copied'}
    }
    # Evaluate the actual save-confirmation condition with different responses.
    $condition=$ast.Find({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text -match 'Save this configuration'},$true).Clauses[0].Item1.Extent.Text
    foreach($answer in @('yes','YES',' Yes ')) {
        $script:answers=[Collections.Generic.Queue[string]]::new([string[]]@($answer))
        if(& ([scriptblock]::Create($condition))) {throw 'Valid yes rejected'}
    }
    $script:answers=[Collections.Generic.Queue[string]]::new([string[]]@(''))
    if(-not (& ([scriptblock]::Create($condition)))) {throw 'Blank should cancel'}
    Write-Output 'PASS: walkthrough defer, success, mixed-case yes, failed-test publishing block, target-account instructions and save confirmation.'
} finally { Remove-Item -LiteralPath $config }
