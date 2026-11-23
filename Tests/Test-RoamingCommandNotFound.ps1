$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../Functions/Initialize-RoamingCommandNotFound.ps1')
function Import-Module {
 param($Name,$MinimumVersion,[switch]$Global,$ErrorAction)
 if(-not $script:available.Contains($Name)){throw 'Missing'}
}
function Install-Module {
 param($Name,$MinimumVersion,$Scope,$Repository,[switch]$Force,$ErrorAction)
 if($Scope -ne 'CurrentUser' -or $Repository -ne 'PSGallery' -or -not $Force){throw 'Wrong installation options'}
 $script:installs++
 if($script:offline){throw 'Offline'}
 $null=$script:available.Add($Name)
}
function Write-Warning {param($Message) $script:warnings++}
foreach($scenario in 'missing','healthy','offline') {
 $script:available=[Collections.Generic.HashSet[string]]::new()
 $script:installs=0;$script:warnings=0;$script:offline=$scenario -eq 'offline'
 if($scenario -eq 'healthy') {
  $null=$available.Add('Microsoft.WinGet.Client')
  $null=$available.Add('Microsoft.WinGet.CommandNotFound')
 }
 Initialize-RoamingCommandNotFound -LoaderPath ''
 if($scenario -eq 'missing' -and ($installs -ne 2 -or $warnings)){throw 'Repair failed'}
 if($scenario -eq 'healthy' -and ($installs -or $warnings)){throw 'Unnecessary installation'}
 if($scenario -eq 'offline' -and ($installs -ne 1 -or $warnings -ne 1)){throw 'Offline handling failed'}
 "PASS: $scenario"
}
$loader=[IO.Path]::GetTempFileName()
$original="# Custom loader`n#f45873b3-b655-43a6-b217-97c00aa0db58 PowerToys CommandNotFound module`n`nImport-Module -Name Microsoft.WinGet.CommandNotFound`n#f45873b3-b655-43a6-b217-97c00aa0db58`n# Custom footer"
[IO.File]::WriteAllText($loader,$original)
Initialize-RoamingCommandNotFound -LoaderPath $loader
$result=[IO.File]::ReadAllText($loader)
if($result -match '(?m)^Import-Module' -or $result -notmatch '# Custom footer'){throw 'Migration failed'}
Initialize-RoamingCommandNotFound -LoaderPath $loader
$backups=@(Get-ChildItem -LiteralPath (Split-Path $loader) -Filter ((Split-Path $loader -Leaf)+'.commandnotfound-*.bak'))
if($backups.Count -ne 1 -or [IO.File]::ReadAllText($backups[0].FullName) -cne $original){throw 'Backup/idempotence failed'}
[IO.File]::Delete($loader)
[IO.File]::Delete($backups[0].FullName)
'PASS: migration, backup, idempotence'
