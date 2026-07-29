function Get-ClipLength {
    try {
        $text = Get-Clipboard -Raw
        if (-not $text) {
            Write-Color "📋 Clipboard is empty" 'Warn'
            return
        }

        $length = $text.Length
        Write-Color "📋 Clipboard contains $length characters"
    }
    catch {
        Write-Color "$global:CbitWarnGlyph Unable to read clipboard content" 'Warn'
    }
}
