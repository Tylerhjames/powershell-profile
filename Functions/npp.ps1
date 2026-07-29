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
        Write-Color "$global:CbitCross Notepad++ not found. Install it with:" 'Bad'
        Write-Color "   winget install Notepad++.Notepad++" 'Header'
        return
    }

    if ($file) {
        & $nppPath $file
    } else {
        & $nppPath
    }
}
Set-Alias -Name np -Value npp -Scope Global
