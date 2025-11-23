function Get-ClipLength {
    try {
        $text = Get-Clipboard -Raw
        if (-not $text) {
            Write-Host "📋 Clipboard is empty" -ForegroundColor DarkYellow
            return
        }

        $length = $text.Length
        Write-Host "📋 Clipboard contains $length characters" -ForegroundColor Cyan
    }
    catch {
        Write-Host "⚠ Unable to read clipboard content" -ForegroundColor Yellow
    }
}
