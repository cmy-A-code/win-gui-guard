# status.ps1 - read-only guard state check (safe to run between actions).
# Exit codes: 0 clear / 9 stopped / 8 no guard / 7 stale / 6 spec mismatch
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\GuardTools.psm1') -Force
$state = Get-GuardState
Write-Output ("$($state.Name)-$($state.Code): $($state.Message)")
exit $state.Code
