function Update-ProfileRepo {
    $repoPath = "$HOME\Documents\Git\powershell-profile"

    if (-not (Test-Path $repoPath)) {
        Write-Host "❌ Profile repository not found" -ForegroundColor Red
        return
    }

    Set-Location $repoPath

    $status = git status --porcelain
    $hasLocalChanges = -not [string]::IsNullOrWhiteSpace($status)

    if ($hasLocalChanges) {
        Write-Host "⚠ Local changes detected" -ForegroundColor Yellow
        Write-Host "Run:" -ForegroundColor DarkGray
        Write-Host "  git add ." -ForegroundColor DarkGray
        Write-Host "  git commit -m \"your message\"" -ForegroundColor DarkGray
        Write-Host "Then run Update-ProfileRepo again." -ForegroundColor DarkGray
        Set-Location $HOME
        return
    }

    try {
        git pull --ff-only
        Write-Host "✅ Profile updated from GitHub" -ForegroundColor Green
    }
    catch {
        Write-Host "❌ Unable to update profile repo" -ForegroundColor Red
    }
    finally {
        Set-Location $HOME
    }
}
