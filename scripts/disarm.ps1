# disarm.ps1 - end the session: stop the guard and archive a stale stop flag.
#   .\scripts\disarm.ps1 -Confirm
param([switch]$Confirm)
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\GuardTools.psm1') -Force
if (-not $Confirm) {
    Write-Output 'refused: pass -Confirm to disarm (only the user / a confirmed end-of-session flow may stop the guard)'
    exit 1
}
$state = Complete-Session -UserConfirmed
$state | Format-List Name, Code, Message
exit 0
