function npp {
    param([Parameter(Mandatory=$true)] [string]$file)
    $nppPath = "C:\Program Files\Notepad++\notepad++.exe"
    if (Test-Path $nppPath) {
        & $nppPath $file
    } else {
        Write-Error "Notepad++ not found at $nppPath"
    }
}
# Optional shortcut
Set-Alias -Name np -Value npp