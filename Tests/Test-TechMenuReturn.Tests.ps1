param([string]$FunctionsPath=(Join-Path $PSScriptRoot '../Functions'))
$ErrorActionPreference='Stop'
foreach ($file in Get-ChildItem $FunctionsPath -Filter '*.ps1') {
    $errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$null,[ref]$errors)
    if ($errors.Count) { throw ($errors -join "`n") }
}
$ast=[Management.Automation.Language.Parser]::ParseFile("$FunctionsPath/Show-TechMenu.ps1",[ref]$null,[ref]$null)
$node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-MenuItem'},$true)
. ([scriptblock]::Create($node.Extent.Text))
function Clear-Host {}
function Write-Color {}
function Write-Host {}
$script:answers=[Collections.Generic.Queue[string]]::new()
$script:reads=0
function Read-Host { $script:reads++; if (-not $script:answers.Count) {throw 'Unexpected extra prompt'}; $script:answers.Dequeue() }
function Check([string]$Name,[scriptblock]$Command,[string[]]$Answers,[int]$Expected) {
    $script:answers.Clear(); foreach($answer in $Answers){$script:answers.Enqueue($answer)}
    $script:reads=0
    Invoke-MenuItem @{Name=$Name;Command=$Command}
    if($script:reads -ne $Expected -or $script:answers.Count){throw "FAIL: $Name ($script:reads prompts)"}
    Write-Output "PASS: $Name"
}
. "$FunctionsPath/Test-Network.ps1"
. "$FunctionsPath/Test-ConnectionDoctor.ps1"
. "$FunctionsPath/Test-WebsiteCertificate.ps1"
Check 'Network Q returns directly' {Test-Network} @('q') 1
Check 'Network target cancellation returns directly' {Test-Network} @('1','q') 2
Check 'Connection Doctor blank target returns directly' {Test-ConnectionDoctor} @('') 1
Check 'Connection Doctor service Q returns directly' {Test-ConnectionDoctor -Target example.com} @('q') 1
Check 'Website blank target returns directly' {Test-WebsiteCertificate} @('') 1
Check 'Report tool waits once for Q' {} @('q') 1
Check 'Enter does not dismiss Q footer' {} @('','q') 2
Check 'Errors remain visible' {throw 'Expected fixture error'} @('q') 1
Check 'Return signal does not hide a later error' {Complete-TechMenuReturn;throw 'Expected fixture error'} @('q') 1
Check 'Explicit return skips outer prompt' {Complete-TechMenuReturn} @() 0
Check 'Return flag resets for next tool' {} @('q') 1
# Verify the actual BitLocker exit branch without invoking status/encryption code.
$bit=[Management.Automation.Language.Parser]::ParseFile("$FunctionsPath/Get-BitLockerInformation.ps1",[ref]$null,[ref]$null)
$switch=$bit.FindAll({param($n) $n -is [Management.Automation.Language.SwitchStatementAst]},$true) | Select-Object -Last 1
$exitBranch=$switch.Clauses | Where-Object {$_.Item1.Extent.Text -match "'5','Q'"}
$exitCode=[scriptblock]::Create($exitBranch.Item2.Extent.Text.TrimStart('{').TrimEnd('}'))
Check 'BitLocker Q skips outer prompt' $exitCode @() 0
# Exercise the real scanner actions, with a fake selection (no network or GUI).
$scan=[Management.Automation.Language.Parser]::ParseFile("$FunctionsPath/Scan-Network.ps1",[ref]$null,[ref]$null)
$actions=$scan.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Show-ScanSelectionActions'},$true)
. ([scriptblock]::Create($actions.Extent.Text))
function Out-GridView { [pscustomobject]@{IPAddress='192.0.2.1';Hostname='fixture';MAC=''} }
Check 'Scanner Q returns directly' {Show-ScanSelectionActions -Results @() -Network 'fixture'} @('q') 1
function Out-GridView {}
Check 'Scanner window close returns directly' {Show-ScanSelectionActions -Results @() -Network 'fixture'} @() 0
# SSH Q branch only; no journal writes, git or SSH operations.
$ssh=[Management.Automation.Language.Parser]::ParseFile("$FunctionsPath/Manage-RoamingSsh.ps1",[ref]$null,[ref]$null)
$switch=$ssh.Find({param($n) $n -is [Management.Automation.Language.SwitchStatementAst] -and $n.Extent.Text -match 'Pending work retained'},$true)
$clause=$switch.Clauses | Where-Object {$_.Item1.Extent.Text -eq "'Q'"}
$state=@{}
Check 'SSH Q returns directly' ([scriptblock]::Create($clause.Item2.Extent.Text.TrimStart('{').TrimEnd('}'))) @() 0
Write-Output 'Navigation checks passed; no live scans, repairs, encryption or SSH operations executed.'
