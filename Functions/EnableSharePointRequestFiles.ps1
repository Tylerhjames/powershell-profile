<#
.SYNOPSIS
    Enable SharePoint Request Files Feature via PowerShell

.DESCRIPTION
    Simple script to connect to SharePoint Online and enable the Request Files feature.
    Request Files allows external users to upload files to a folder without site access.

.NOTES
    Requirements:
    - SharePoint Administrator permissions
    - SharePoint Online Management Shell module
    - "Anyone" sharing must be enabled (script will help you set this)

.EXAMPLE
    # Edit the $TenantName variable below, then run the script
    .\Enable-SharePoint-RequestFiles.ps1
#>

# =============================================================================
# CONFIGURATION - Change this to match your tenant
# =============================================================================

$TenantName = "yakamapowercbit"  # Change this! (e.g., if your SharePoint is contoso.sharepoint.com, use "contoso")

# Optional: Specify a site URL if you want to enable for a specific site
$SpecificSiteURL = # Example: ""

# =============================================================================

$AdminCenterURL = "https://yakamapowercbit-admin.sharepoint.com/_layouts/15/online/AdminHome.aspx#/home"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "SharePoint Request Files Setup" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Step 1: Install module if needed
Write-Host "Checking for SharePoint Online Management Shell..." -ForegroundColor Yellow
$module = Get-Module -Name Microsoft.Online.SharePoint.PowerShell -ListAvailable

if (-not $module) {
    Write-Host "Module not found. Installing..." -ForegroundColor Yellow
    try {
        Install-Module -Name Microsoft.Online.SharePoint.PowerShell -Force -AllowClobber
        Write-Host "✓ Module installed successfully`n" -ForegroundColor Green
    } catch {
        Write-Host "✗ Failed to install module. Run PowerShell as Administrator and try:" -ForegroundColor Red
        Write-Host "  Install-Module -Name Microsoft.Online.SharePoint.PowerShell" -ForegroundColor Cyan
        exit
    }
} else {
    Write-Host "✓ Module already installed`n" -ForegroundColor Green
}

# Step 2: Connect to SharePoint
Write-Host "Connecting to SharePoint Admin Center..." -ForegroundColor Yellow
Write-Host "URL: $AdminCenterURL" -ForegroundColor Gray

try {
    Connect-SPOService -Url $AdminCenterURL
    Write-Host "✓ Connected successfully`n" -ForegroundColor Green
} catch {
    Write-Host "✗ Connection failed: $_" -ForegroundColor Red
    Write-Host "`nMake sure:" -ForegroundColor Yellow
    Write-Host "  1. You updated the `$TenantName variable" -ForegroundColor White
    Write-Host "  2. You have SharePoint Admin permissions" -ForegroundColor White
    exit
}

# Step 3: Check current settings
Write-Host "Checking current settings..." -ForegroundColor Yellow
$tenant = Get-SPOTenant

Write-Host "`nCurrent Status:" -ForegroundColor Cyan
Write-Host "  SharePoint Sharing:        $($tenant.SharingCapability)" -ForegroundColor White
Write-Host "  Request Files Enabled:     $($tenant.CoreRequestFilesLinkEnabled)" -ForegroundColor White
Write-Host "  Link Expiration (days):    $($tenant.CoreRequestFilesLinkExpirationInDays)" -ForegroundColor White

# Step 4: Enable "Anyone" sharing if needed (REQUIRED for Request Files)
if ($tenant.SharingCapability -ne "ExternalUserAndGuestSharing") {
    Write-Host "`n⚠ IMPORTANT: Request Files requires 'Anyone' sharing to be enabled" -ForegroundColor Yellow
    Write-Host "  Current: $($tenant.SharingCapability)" -ForegroundColor Gray
    Write-Host "  Needed:  ExternalUserAndGuestSharing (Anyone links)`n" -ForegroundColor Gray
    
    $response = Read-Host "Enable 'Anyone' sharing? (Y/N)"
    if ($response -eq "Y") {
        Write-Host "`nEnabling Anyone sharing..." -ForegroundColor Yellow
        Set-SPOTenant -SharingCapability ExternalUserAndGuestSharing
        Write-Host "✓ Anyone sharing enabled`n" -ForegroundColor Green
    } else {
        Write-Host "`n✗ Cannot enable Request Files without Anyone sharing" -ForegroundColor Red
        Write-Host "To enable later, run:" -ForegroundColor Yellow
        Write-Host "  Set-SPOTenant -SharingCapability ExternalUserAndGuestSharing`n" -ForegroundColor Cyan
        exit
    }
}

# Step 5: Enable Request Files
Write-Host "`nEnabling Request Files feature..." -ForegroundColor Yellow

try {
    # Enable for SharePoint sites
    Set-SPOTenant -CoreRequestFilesLinkEnabled $True
    Write-Host "✓ Request Files enabled for SharePoint sites" -ForegroundColor Green
    
    # Set expiration (optional but recommended)
    Set-SPOTenant -CoreRequestFilesLinkExpirationInDays 30
    Write-Host "✓ Link expiration set to 30 days" -ForegroundColor Green
    
    # Also enable for OneDrive
    Set-SPOTenant -OneDriveRequestFilesLinkEnabled $True
    Set-SPOTenant -OneDriveRequestFilesLinkExpirationInDays 7
    Write-Host "✓ Request Files enabled for OneDrive (7 day expiration)" -ForegroundColor Green
    
} catch {
    Write-Host "✗ Error enabling Request Files: $_" -ForegroundColor Red
    exit
}

# Step 6: Enable for specific site (optional)
if ($SpecificSiteURL) {
    Write-Host "`nEnabling Request Files for specific site..." -ForegroundColor Yellow
    Write-Host "Site: $SpecificSiteURL" -ForegroundColor Gray
    
    try {
        Set-SPOSite -Identity $SpecificSiteURL -RequestFilesLinkEnabled $True
        Write-Host "✓ Request Files enabled for site" -ForegroundColor Green
    } catch {
        Write-Host "⚠ Warning: Could not enable for site: $_" -ForegroundColor Yellow
    }
}

# Step 7: Verify settings
Write-Host "`nVerifying final settings..." -ForegroundColor Yellow
$tenant = Get-SPOTenant

Write-Host "`nFinal Configuration:" -ForegroundColor Cyan
Write-Host "  ✓ SharePoint Sharing:          $($tenant.SharingCapability)" -ForegroundColor Green
Write-Host "  ✓ Request Files Enabled:       $($tenant.CoreRequestFilesLinkEnabled)" -ForegroundColor Green
Write-Host "  ✓ SharePoint Link Expiration:  $($tenant.CoreRequestFilesLinkExpirationInDays) days" -ForegroundColor Green
Write-Host "  ✓ OneDrive Request Files:      $($tenant.OneDriveRequestFilesLinkEnabled)" -ForegroundColor Green
Write-Host "  ✓ OneDrive Link Expiration:    $($tenant.OneDriveRequestFilesLinkExpirationInDays) days" -ForegroundColor Green

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "✓ REQUEST FILES IS NOW ENABLED!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan

Write-Host "`nNext Steps:" -ForegroundColor Yellow
Write-Host "  1. Go to your document library in SharePoint" -ForegroundColor White
Write-Host "  2. Navigate to the folder where you want vendors to upload" -ForegroundColor White
Write-Host "  3. Right-click the folder and select 'Request files'" -ForegroundColor White
Write-Host "  4. Share the generated link with your vendors" -ForegroundColor White

Write-Host "`nImportant Notes:" -ForegroundColor Yellow
Write-Host "  • Folder permissions must be set to 'View, edit, and upload'" -ForegroundColor White
Write-Host "  • Links expire automatically based on settings above" -ForegroundColor White
Write-Host "  • Anyone with the link can upload files (no sign-in required)" -ForegroundColor White

Write-Host "`nManual Commands Reference:" -ForegroundColor Cyan
Write-Host "  # Check status:" -ForegroundColor Gray
Write-Host "  Get-SPOTenant | Select CoreRequestFilesLinkEnabled,CoreRequestFilesLinkExpirationInDays`n" -ForegroundColor White
Write-Host "  # Disable Request Files:" -ForegroundColor Gray
Write-Host "  Set-SPOTenant -CoreRequestFilesLinkEnabled `$False`n" -ForegroundColor White
Write-Host "  # Enable for specific site:" -ForegroundColor Gray
Write-Host "  Set-SPOSite -Identity <SiteURL> -RequestFilesLinkEnabled `$True`n" -ForegroundColor White

Write-Host "Done!`n" -ForegroundColor Green