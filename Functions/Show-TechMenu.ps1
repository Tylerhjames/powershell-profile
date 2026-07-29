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
            Command     = { 
                if (Get-Command Test-Network -ErrorAction SilentlyContinue) {
                    Test-Network
                } elseif (Get-Command Invoke-NetTest -ErrorAction SilentlyContinue) {
                    Invoke-NetTest
                } else {
                    Write-Color "$global:CbitCross Test-Network function not found. Try: rpl" 'Bad'
                }
            }
            Icon        = "🌐"
        }
        @{
            Name        = "Renew Network"
            Description = "Flush DNS + release/renew DHCP"
            Command     = {
                if (Get-Command FlushMe -ErrorAction SilentlyContinue) {
                    FlushMe
                } else {
                    ipconfig /flushdns
                    ipconfig /release
                    Start-Sleep 2
                    ipconfig /renew
                }
            }
            Icon        = "🔄"
        }
        @{ 
            Name        = "Email Auth Check"
            Description = "Test SPF/DKIM/DMARC records"
            Command     = { 
                $domain = Read-Host "`nEnter domain to check"
                if ($domain) {
                    if (Get-Command Test-EmailAuthentication -ErrorAction SilentlyContinue) {
                        Test-EmailAuthentication -Domain $domain
                    } elseif (Get-Command Test-EmailDNS -ErrorAction SilentlyContinue) {
                        Test-EmailDNS -Domain $domain
                    } else {
                        Write-Color "$global:CbitCross Email auth function not found. Try: rpl" 'Bad'
                    }
                }
            }
            Icon        = "📧"
        }
        @{ 
            Name        = "Network Scanner"
            Description = "Scan LAN for active hosts"
            Command     = { 
                if (Get-Command Scan-Network -ErrorAction SilentlyContinue) {
                    Scan-Network
                } else {
                    Write-Color "$global:CbitCross Scan-Network function not found. Try: rpl" 'Bad'
                }
            }
            Icon        = "📡"
        }
        @{ 
            Name        = "Speed Test"
            Description = "Quick internet speed test"
            Command     = { 
                if (Get-Command Invoke-InternetSpeedTest -ErrorAction SilentlyContinue) {
                    Invoke-InternetSpeedTest
                } else {
                    Write-Color "$global:CbitCross Speedtest function not found. Try: rpl" 'Bad'
                }
            }
            Icon        = "⚡"
        }
        @{ 
            Name        = "System Info"
            Description = "Comprehensive system details"
            Command     = { 
                if (Get-Command Get-SystemDetails -ErrorAction SilentlyContinue) {
                    Get-SystemDetails
                } else {
                    Get-ComputerInfo | Select-Object CsName, OsName, OsVersion, OsArchitecture, CsProcessors | Format-List
                }
            }
            Icon        = "💻"
        }
        @{ 
            Name        = "BitLocker Manager"
            Description = "Manage drive encryption"
            Command     = { 
                if (Get-Command Get-BitLockerInformation -ErrorAction SilentlyContinue) {
                    Get-BitLockerInformation
                } else {
                    Write-Color "$global:CbitCross Get-BitLockerInformation function not found. Try: rpl" 'Bad'
                }
            }
            Icon        = "🔒"
        }
        @{
            Name        = "Pulse Monitor"
            Description = "TCP/ICMP connectivity & latency tracker"
            Command     = {
                if (Get-Command Start-Pulse -ErrorAction SilentlyContinue) {
                    Start-Pulse
                } else {
                    Write-Color "$global:CbitCross Start-Pulse function not found. Try: rpl" 'Bad'
                }
            }
            Icon        = "💓"
        }
        @{
            Name        = "Server Inventory"
            Description = "Full system audit report (HTML + TXT)"
            Command     = {
                if (Get-Command Invoke-ServerInventory -ErrorAction SilentlyContinue) {
                    Invoke-ServerInventory
                } else {
                    Write-Color "$global:CbitCross Invoke-ServerInventory function not found. Try: rpl" 'Bad'
                }
            }
            Icon        = "📋"
        }
    )
    
    # ══════════════════════════════════════════════════════════════════════════
    # Helper Functions
    # ══════════════════════════════════════════════════════════════════════════
    
    function Get-OptimalColumns {
        param([int]$ItemCount, [int]$TerminalWidth)
        
        $itemWidth = 35
        $maxCols = [math]::Floor($TerminalWidth / $itemWidth)
        $maxCols = [math]::Min($maxCols, 4)
        $maxCols = [math]::Max($maxCols, 1)
        
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
    
    # Letter keys mapped to menu indices (A=0, B=1, ... K=10, etc.)
    $script:LetterKeys = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'

    function Show-Menu {
        param(
            [array]$Items,
            [int]$SelectedIndex,
            [int]$ColumnCount,
            [switch]$FirstDraw
        )

        # First draw clears the screen; subsequent redraws reposition the cursor
        if ($FirstDraw) {
            Clear-Host
        } else {
            [Console]::SetCursorPosition(0, 0)
        }

        $boxWidth = 63
        $titleText = "  TECHNICIAN TOOLKIT  "
        $padding = [math]::Floor(($boxWidth - $titleText.Length) / 2)
        $paddedTitle = (" " * $padding) + $titleText

        Write-Host ""
        Write-Color ("=" * $boxWidth) 'Header'
        Write-Color $paddedTitle 'Header'
        Write-Color ("=" * $boxWidth) 'Header'
        Write-Host ""

        Write-Color "  Use " 'Detail' -NoNewline
        Write-Color "arrows" 'Warn' -NoNewline
        Write-Color " or " 'Detail' -NoNewline
        Write-Color "letter keys" 'Warn' -NoNewline
        Write-Color " to navigate, " 'Detail' -NoNewline
        Write-Color "Enter" 'Warn' -NoNewline
        Write-Color " to select, " 'Detail' -NoNewline
        Write-Color "Q" 'Warn' -NoNewline
        Write-Color " to quit" 'Detail'
        Write-Host ""

        $rows = [math]::Ceiling($Items.Count / $ColumnCount)
        $columnWidth = 35

        for ($row = 0; $row -lt $rows; $row++) {
            for ($col = 0; $col -lt $ColumnCount; $col++) {
                $index = $row + ($col * $rows)

                if ($index -lt $Items.Count) {
                    $item = $Items[$index]
                    $isSelected = ($index -eq $SelectedIndex)

                    $letter = $script:LetterKeys[$index]
                    $displayText = "  $($item.Icon) [$letter] $($item.Name)"

                    if ($isSelected) {
                        Write-Color " > " 'Warn' -NoNewline
                        Write-Host $displayText.PadRight($columnWidth - 3) -NoNewline -BackgroundColor DarkGray -ForegroundColor Gray
                    }
                    else {
                        Write-Host "   " -NoNewline
                        Write-Color "  $($item.Icon) " -NoNewline
                        Write-Color "[$letter]" 'Warn' -NoNewline
                        Write-Color " $($item.Name)".PadRight(($columnWidth - 3) - "  $($item.Icon) [$letter]".Length) -NoNewline
                    }
                }
                else {
                    Write-Host (" " * $columnWidth) -NoNewline
                }
            }
            Write-Host ""

            # Description line for selected item (pad non-selected rows to maintain layout)
            $descWritten = $false
            for ($col = 0; $col -lt $ColumnCount; $col++) {
                $index = $row + ($col * $rows)

                if ($index -eq $SelectedIndex -and $index -lt $Items.Count) {
                    $descText = "      -- $($Items[$index].Description)"
                    Write-Color $descText.PadRight($boxWidth) 'Detail'
                    $descWritten = $true
                }
            }
            if (-not $descWritten) {
                Write-Host (" " * $boxWidth)
            }

            Write-Host ""
        }

        Write-Host ""
        Write-Color ("─" * $boxWidth) 'Detail'
        $letter = $script:LetterKeys[$SelectedIndex]
        Write-Color "  Selected: $($Items[$SelectedIndex].Icon) [$letter] $($Items[$SelectedIndex].Name)".PadRight($boxWidth) 'Warn'
        Write-Color ("─" * $boxWidth) 'Detail'
    }
    
    # ══════════════════════════════════════════════════════════════════════════
    # Main Menu Loop
    # ══════════════════════════════════════════════════════════════════════════
    
    if ($Columns -eq 0) {
        $terminalWidth = [Console]::WindowWidth
        $Columns = Get-OptimalColumns -ItemCount $menuItems.Count -TerminalWidth $terminalWidth
    }
    
    $rows = [math]::Ceiling($menuItems.Count / $Columns)
    $selectedIndex = 0
    $running = $true
    $firstDraw = $true

    # Helper to execute the selected menu item
    function Invoke-MenuItem {
        param([hashtable]$Item)

        Clear-Host
        Write-Host ""
        Write-Color ("=" * 63) 'Header'
        Write-Color "  Executing: $($Item.Icon) $($Item.Name)" 'Header'
        Write-Color ("=" * 63) 'Header'
        Write-Host ""

        try {
            & $Item.Command
        } catch {
            Write-Color "`nError: $_" 'Bad'
        }

        Write-Host ""
        Write-Color ("─" * 63) 'Detail'
        Write-Color "Press Enter to return to menu..." 'Detail'
        Read-Host
    }

    while ($running) {
        if ($firstDraw) {
            Show-Menu -Items $menuItems -SelectedIndex $selectedIndex -ColumnCount $Columns -FirstDraw
            $firstDraw = $false
        } else {
            Show-Menu -Items $menuItems -SelectedIndex $selectedIndex -ColumnCount $Columns
        }

        $key = [Console]::ReadKey($true)

        switch ($key.Key) {
            'UpArrow' {
                $selectedIndex -= 1
                if ($selectedIndex -lt 0) { $selectedIndex = $menuItems.Count - 1 }
            }

            'DownArrow' {
                $selectedIndex += 1
                if ($selectedIndex -ge $menuItems.Count) { $selectedIndex = 0 }
            }

            'LeftArrow' {
                $currentRow = $selectedIndex % $rows
                $currentCol = [math]::Floor($selectedIndex / $rows)
                $newCol = if ($currentCol -eq 0) { $Columns - 1 } else { $currentCol - 1 }
                $newIndex = $currentRow + ($newCol * $rows)
                if ($newIndex -ge $menuItems.Count) { $newIndex = $menuItems.Count - 1 }
                $selectedIndex = $newIndex
            }

            'RightArrow' {
                $currentRow = $selectedIndex % $rows
                $currentCol = [math]::Floor($selectedIndex / $rows)
                $newCol = ($currentCol + 1) % $Columns
                $newIndex = $currentRow + ($newCol * $rows)
                if ($newIndex -ge $menuItems.Count) { $newIndex = 0 }
                $selectedIndex = $newIndex
            }

            'Enter' {
                Invoke-MenuItem -Item $menuItems[$selectedIndex]
                $firstDraw = $true
            }

            'Escape' {
                $running = $false
                Clear-Host
                Write-Color "`nExiting Technician Toolkit`n" 'Good'
            }

            'Q' {
                $running = $false
                Clear-Host
                Write-Color "`nExiting Technician Toolkit`n" 'Good'
            }

            default {
                # Letter key direct selection — A executes item 0, B executes item 1, etc.
                $letterChar = [char]::ToUpper($key.KeyChar)
                $letterIndex = $script:LetterKeys.IndexOf($letterChar)

                if ($letterIndex -ge 0 -and $letterIndex -lt $menuItems.Count) {
                    $selectedIndex = $letterIndex
                    Invoke-MenuItem -Item $menuItems[$selectedIndex]
                    $firstDraw = $true
                }
            }
        }
    }
}

# Create aliases
New-Alias -Name tech -Value Show-TechMenu -Force -Scope Global
New-Alias -Name techmenu -Value Show-TechMenu -Force -Scope Global