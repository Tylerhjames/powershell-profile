git -C "$HOME\Documents\Git\powershell-profile" pull --quiet 2>$null
Write-Host "✅ Roaming PowerShell profile loaded from Git" -ForegroundColor Green
