function Show-TechMenu {
    <#
    .SYNOPSIS
        Interactive technician menu with arrow key navigation
    
    .DESCRIPTION
        Displays a multi-column, keyboard-navigable menu for common IT tasks.
        Use arrow keys to highlight options, Enter to execute, Q to quit.
        
        Automatically organizes menu items into columns based on terminal width.
        Easily extensible - just add new items to the $menuItems array.
    
    .PARAMETER Columns
        Number of columns to display (default: auto-detect based on terminal width)
    
    .EXAMPLE
        Show-TechMenu
        Display interactive menu
    
    .EXAMPLE
        tech
        Using alias to launch menu
    #>
    
    [CmdletBinding()]
    param(
        [int]$Columns = 0  # 0 = auto-detect
    )
    
    # ══════════════════════════════════════════════════════════════════════════
    # Menu Configuration - ADD NEW ITEMS HERE
    # ══════════════════════════════════════════════════════════════════════════
    
    $menuItems = @(
        @{ 
            Name        = "Network Test"
            Description = "LAN/WAN/Internet speed testing"
            Command     = { Test-Network }
            Icon        = "🌐"
        }
        @{ 
            Name        = "Public IP"
            Description = "Show public IP address"
            Command     = { Invoke-Expression 'publicip' }
            Icon        = "🔍"
        }
        @{ 
            Name        = "Renew Network"
            Description = "Release and renew DHCP"
            Command     = { Invoke-Expression 'renew-safe' }
            Icon        = "🔄"
        }
        @{ 
            Name        = "Flush DNS"
            Description = "Clear DNS resolver cache"
            Command     = { ipconfig /flushdns }
            Icon        = "🗑️"
        }
        @{ 
            Name        = "Email Auth Check"
            Description = "Test SPF/DKIM/DMARC records"
            Command     = { 
                $domain = Read-Host "Enter domain to check"
                if ($domain) { Test-EmailAuthentication -Domain $domain }
            }
            Icon        = "📧"
        }
        @{ 
            Name        = "Network Scanner"
            Description = "Scan LAN for active hosts"
            Command     = { Scan-Network }
            Icon        = "📡"
        }
        @{ 
            Name        = "Speed Test"
            Description = "Quick internet speed test"
            Command     = { Invoke-InternetSpeedTest }
            Icon        = "⚡"
        }
        @{ 
            Name        = "System Info"
            Description = "Display system information"
            Command     = { Get-ComputerInfo | Select-Object CsName, OsName, OsVersion, OsArchitecture | Format-List }
            Icon        = "💻"
        }
        # ADD MORE ITEMS HERE - they'll automatically flow into columns!
    )
    
    # ══════════════════════════════════════════════════════════════════════════
    # Helper Functions
    # ══════════════════════════════════════════════════════════════════════════
    
    function Get-OptimalColumns {
        param([int]$ItemCount, [int]$TerminalWidth)
        
        # Each item needs ~35 chars (icon + number + name)
        $itemWidth = 35
        $maxCols = [math]::Floor($TerminalWidth / $itemWidth)
        
        # Limit to reasonable max
        $maxCols = [math]::Min($maxCols, 4)
        $maxCols = [math]::Max($maxCols, 1)
        
        # Calculate optimal columns to minimize empty cells
        $optimalCols = 1
        $minWaste = $ItemCount
        
        for ($cols = 1; $cols -le $maxCols; $cols++) {
            $rows = [math]::Ceiling($ItemCount / $cols)
            $totalCells = $rows * $cols
            $waste = $totalCells - $ItemCount
            
            if ($waste -lt $minWaste) {
                $minWaste = $waste
                $optimalCols = $cols
            }
        }
        
        return $optimalCols
    }
    
    function Show-Menu {
        param(
            [array]$Items,
            [int]$SelectedIndex,
            [int]$ColumnCount
        )
        
        Clear-Host
        
        # Header
        Write-Host "`n╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "║" -NoNewline -ForegroundColor Cyan
        Write-Host "            🛠️  TECHNICIAN TOOLKIT  🛠️            " -NoNewline -ForegroundColor White
        Write-Host "║" -ForegroundColor Cyan
        Write-Host "╚═══════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan
        
        Write-Host "  Use " -NoNewline -ForegroundColor Gray
        Write-Host "↑↓←→" -NoNewline -ForegroundColor Yellow
        Write-Host " arrow keys to navigate, " -NoNewline -ForegroundColor Gray
        Write-Host "Enter" -NoNewline -ForegroundColor Yellow
        Write-Host " to select, " -NoNewline -ForegroundColor Gray
        Write-Host "Q" -NoNewline -ForegroundColor Yellow
        Write-Host " to quit`n" -ForegroundColor Gray
        
        # Calculate layout
        $rows = [math]::Ceiling($Items.Count / $ColumnCount)
        $columnWidth = 35
        
        # Display items in columns
        for ($row = 0; $row -lt $rows; $row++) {
            for ($col = 0; $col -lt $ColumnCount; $col++) {
                $index = $row + ($col * $rows)
                
                if ($index -lt $Items.Count) {
                    $item = $Items[$index]
                    $isSelected = ($index -eq $SelectedIndex)
                    
                    # Format item display
                    $displayNum = $index + 1
                    $displayText = "  $($item.Icon) [$displayNum] $($item.Name)"
                    
                    # Highlight selected item
                    if ($isSelected) {
                        Write-Host " ► " -NoNewline -ForegroundColor Yellow
                        Write-Host $displayText.PadRight($columnWidth - 3) -NoNewline -BackgroundColor DarkGray -ForegroundColor White
                    }
                    else {
                        Write-Host "   " -NoNewline
                        Write-Host $displayText.PadRight($columnWidth - 3) -NoNewline -ForegroundColor Cyan
                    }
                }
                else {
                    Write-Host " ".PadRight($columnWidth) -NoNewline
                }
            }
            Write-Host ""
            
            # Show description for selected item on this row
            for ($col = 0; $col -lt $ColumnCount; $col++) {
                $index = $row + ($col * $rows)
                
                if ($index -eq $SelectedIndex -and $index -lt $Items.Count) {
                    $descPadding = " ".PadLeft(6)
                    Write-Host "$descPadding└─ $($Items[$index].Description)" -ForegroundColor DarkGray
                }
            }
            
            Write-Host ""
        }
        
        Write-Host "`n" + ("─" * 63) -ForegroundColor DarkGray
        Write-Host "  Selected: " -NoNewline -ForegroundColor Gray
        Write-Host "$($Items[$SelectedIndex].Icon) $($Items[$SelectedIndex].Name)" -ForegroundColor Yellow
        Write-Host ("─" * 63) -ForegroundColor DarkGray
    }
    
    function Get-KeyPress {
        # Non-blocking key read
        if ([Console]::KeyAvailable) {
            return [Console]::ReadKey($true)
        }
        return $null
    }
    
    # ══════════════════════════════════════════════════════════════════════════
    # Main Menu Loop
    # ══════════════════════════════════════════════════════════════════════════
    
    # Determine column count
    if ($Columns -eq 0) {
        $terminalWidth = [Console]::WindowWidth
        $Columns = Get-OptimalColumns -ItemCount $menuItems.Count -TerminalWidth $terminalWidth
    }
    
    # Calculate rows for navigation
    $rows = [math]::Ceiling($menuItems.Count / $Columns)
    
    # Menu state
    $selectedIndex = 0
    $running = $true
    
    while ($running) {
        Show-Menu -Items $menuItems -SelectedIndex $selectedIndex -ColumnCount $Columns
        
        # Wait for key press
        $key = [Console]::ReadKey($true)
        
        switch ($key.Key) {
            'UpArrow' {
                # Move up in current column
                $selectedIndex -= 1
                if ($selectedIndex -lt 0) {
                    $selectedIndex = $menuItems.Count - 1
                }
            }
            
            'DownArrow' {
                # Move down in current column
                $selectedIndex += 1
                if ($selectedIndex -ge $menuItems.Count) {
                    $selectedIndex = 0
                }
            }
            
            'LeftArrow' {
                # Move left to previous column
                $currentRow = $selectedIndex % $rows
                $currentCol = [math]::Floor($selectedIndex / $rows)
                
                $newCol = ($currentCol - 1)
                if ($newCol -lt 0) {
                    $newCol = $Columns - 1
                }
                
                $newIndex = $currentRow + ($newCol * $rows)
                
                # Wrap to valid index
                if ($newIndex -ge $menuItems.Count) {
                    $newIndex = $menuItems.Count - 1
                }
                
                $selectedIndex = $newIndex
            }
            
            'RightArrow' {
                # Move right to next column
                $currentRow = $selectedIndex % $rows
                $currentCol = [math]::Floor($selectedIndex / $rows)
                
                $newCol = ($currentCol + 1) % $Columns
                $newIndex = $currentRow + ($newCol * $rows)
                
                # Wrap to valid index
                if ($newIndex -ge $menuItems.Count) {
                    $newIndex = 0
                }
                
                $selectedIndex = $newIndex
            }
            
            'Enter' {
                # Execute selected command
                Clear-Host
                
                $selectedItem = $menuItems[$selectedIndex]
                Write-Host "`n═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
                Write-Host "  Executing: $($selectedItem.Icon) $($selectedItem.Name)" -ForegroundColor Cyan
                Write-Host "═══════════════════════════════════════════════════════════════`n" -ForegroundColor Cyan
                
                try {
                    & $selectedItem.Command
                }
                catch {
                    Write-Host "`n❌ Error executing command: $_" -ForegroundColor Red
                }
                
                Write-Host "`n" + ("─" * 63) -ForegroundColor DarkGray
                Write-Host "Press any key to return to menu..." -ForegroundColor Gray
                $null = [Console]::ReadKey($true)
            }
            
            'Q' {
                # Quit
                $running = $false
                Clear-Host
                Write-Host "`n✓ Exiting Technician Toolkit`n" -ForegroundColor Green
            }
            
            { $_ -match '^\d$' } {
                # Number key pressed - direct selection
                $num = [int]$key.KeyChar.ToString()
                
                if ($num -gt 0 -and $num -le $menuItems.Count) {
                    $selectedIndex = $num - 1
                    
                    # Auto-execute on number press
                    Clear-Host
                    
                    $selectedItem = $menuItems[$selectedIndex]
                    Write-Host "`n═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
                    Write-Host "  Executing: $($selectedItem.Icon) $($selectedItem.Name)" -ForegroundColor Cyan
                    Write-Host "═══════════════════════════════════════════════════════════════`n" -ForegroundColor Cyan
                    
                    try {
                        & $selectedItem.Command
                    }
                    catch {
                        Write-Host "`n❌ Error executing command: $_" -ForegroundColor Red
                    }
                    
                    Write-Host "`n" + ("─" * 63) -ForegroundColor DarkGray
                    Write-Host "Press any key to return to menu..." -ForegroundColor Gray
                    $null = [Console]::ReadKey($true)
                }
            }
            
            default {
                # Ignore other keys
            }
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# Legacy Function (Backward Compatibility)
# ══════════════════════════════════════════════════════════════════════════════

function tech {
    <#
    .SYNOPSIS
        Legacy menu function - calls Show-TechMenu
    #>
    Show-TechMenu
}

# ══════════════════════════════════════════════════════════════════════════════
# Aliases
# ══════════════════════════════════════════════════════════════════════════════

Set-Alias -Name techmenu -Value Show-TechMenu -Scope Global