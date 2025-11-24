function Clip-Clean {
    try {
        $content = Get-Clipboard -Raw
        if (-not $content) {
            Write-Host "📋 Clipboard is empty — nothing to clean" -ForegroundColor DarkYellow
            return
        }

        # Normalize line endings, strip formatting, convert to plain text
        $clean = $content |
            Out-String |
            ForEach-Object { $_ -replace '\r', '' -replace '\t', ' ' } |
            ForEach-Object { $_.Trim() }

        Set-Clipboard -Value $clean

        Write-Host "✅ Clipboard cleaned and converted to plain text" -ForegroundColor Green
    }
    catch {
        Write-Host "⚠ Unable to clean clipboard content" -ForegroundColor Yellow
    }
}
