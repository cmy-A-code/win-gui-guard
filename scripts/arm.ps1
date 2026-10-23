# arm.ps1 - arm the guard for a session.
#   .\scripts\arm.ps1 -Minutes 120 -Tag my-session
param(
    [int]$Minutes = 120,
    [string]$Tag = 'session',
    [int]$CooldownMs = 5000
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\GuardTools.psm1') -Force
$state = Start-Guard -Minutes $Minutes -Tag $Tag -CooldownMs $CooldownMs
$state | Format-List Name, Code, Message, GuardPid, HeartbeatAge
if ($state.Code -ne 0) { exit $state.Code }
