# Execute the real background-sync block with mocked Git; no network/profile load.
$ErrorActionPreference='Stop'
$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../Profile.ps1'),[ref]$null,[ref]$errors)
if($errors.Count){throw $errors}
$node=$ast.Find({param($n) $n -is [Management.Automation.Language.ScriptBlockExpressionAst] -and $n.ScriptBlock.ParamBlock.Extent.Text -match 'RepoPath, \$FlagFile'},$true)
if(-not $node){throw 'Sync block not found'}
$sync=$node.ScriptBlock.GetScriptBlock()
function git {
    $global:LASTEXITCODE=0
    switch($args[0]) {
        'rev-parse' {
            if($args[1] -eq '--abbrev-ref'){return 'origin/main'}
            if($args[1] -eq 'HEAD'){if($script:pulled -and $script:scenario -eq 'behind'){return 'remote'};return 'local'}
            if($script:scenario -eq 'equal'){return 'local'};return 'remote'
        }
        'fetch' {if($script:scenario -eq 'offline'){$global:LASTEXITCODE=1}}
        'diff' {if($script:scenario -eq 'dirty'){$global:LASTEXITCODE=1}}
        'pull' {$script:pulled=$true;if($script:scenario -eq 'diverged'){$global:LASTEXITCODE=1}}
        default {throw 'Unexpected Git call'}
    }
}
$flag=[IO.Path]::GetTempFileName()
try {
    foreach($case in @(
        @{Name='ahead';Expected=''},@{Name='equal';Expected=''},
        @{Name='behind';Expected='updated'},@{Name='offline';Expected=''},
        @{Name='dirty';Expected='local-changes'},@{Name='diverged';Expected='pull-failed'}
    )) {
        $script:scenario=$case.Name;$script:pulled=$false
        Set-Content -LiteralPath $flag 'updated'
        & $sync $PWD.Path $flag
        $actual=if(Test-Path -LiteralPath $flag){(Get-Content -LiteralPath $flag -Raw).Trim()}else{''}
        if($actual -ne $case.Expected){throw "FAIL: $($case.Name): $actual"}
        Write-Output "PASS: $($case.Name)"
    }
} finally {if(Test-Path -LiteralPath $flag){Remove-Item -LiteralPath $flag}}
