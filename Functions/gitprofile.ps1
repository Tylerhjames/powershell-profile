# Open the Git-synced PowerShell profile in Notepad++
function gitprofile { npp "$HOME\Documents\Git\powershell-profile\Profile.ps1" }
Set-Alias gprof gitprofile
