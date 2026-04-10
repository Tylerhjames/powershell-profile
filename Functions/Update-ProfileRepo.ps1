function Update-ProfileRepo {
    # Use the same config var as Profile.ps1 if available, otherwise derive from script location
    $repoPath = if ($script:ProfileRepo) { $script:ProfileRepo }
                elseif ($PSScriptRoot) { Split-Path $PSScriptRoot -Parent }
                else { "$HOME\Documents\Git\powershell-profile" }

    if (-not (Test-Path $repoPath)) {
        Write-Host "❌ Profile repository not found at $repoPath" -ForegroundColor Red
        return
    }

    Push-Location $repoPath

    try {
        $status = git status --porcelain 2>$null
        if (-not [string]::IsNullOrWhiteSpace($status)) {
            Write-Host "⚠ Local changes detected — commit or stash first" -ForegroundColor Yellow
            git status --short
            return
        }

        git pull --ff-only --quiet 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✅ Profile updated from GitHub" -ForegroundColor Green
        } else {
            Write-Host "❌ Pull failed (merge conflict or network issue)" -ForegroundColor Red
        }
    }
    catch {
        Write-Host "❌ Unable to update profile repo: $_" -ForegroundColor Red
    }
    finally {
        Pop-Location
    }
}
