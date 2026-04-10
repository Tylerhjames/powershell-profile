function npp {
    param([string]$file)

    # Search common install locations
    $searchPaths = @(
        "$env:ProgramFiles\Notepad++\notepad++.exe",
        "${env:ProgramFiles(x86)}\Notepad++\notepad++.exe",
        "$env:LocalAppData\Notepad++\notepad++.exe"
    )

    $nppPath = $searchPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $nppPath) {
        Write-Host "❌ Notepad++ not found. Install it with:" -ForegroundColor Red
        Write-Host "   winget install Notepad++.Notepad++" -ForegroundColor Cyan
        return
    }

    if ($file) {
        & $nppPath $file
    } else {
        & $nppPath
    }
}
Set-Alias -Name np -Value npp -Scope Global
