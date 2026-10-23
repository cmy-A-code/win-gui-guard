# guard-host.ps1 - hosts the PanicGuard keyboard hook (started hidden by Start-Guard).
param(
    [Parameter(Mandatory = $true)][string]$StopFlag,
    [Parameter(Mandatory = $true)][string]$PidFile,
    [Parameter(Mandatory = $true)][string]$Log,
    [string]$Tag = 'session',
    [int]$Minutes = 120,
    [int]$Cooldown = 5000,
    [switch]$TestMode
)
$ErrorActionPreference = 'Stop'
$src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\PanicGuard.cs'
if (-not (Test-Path $src)) { throw "PanicGuard.cs not found: $src" }

# Publish our PID first so the gate can verify the guard process is alive
# (the C# hook only writes heartbeat/spec, not the pid file).
Set-Content -Path $PidFile -Value $PID -Encoding ASCII
try {
    Add-Type -Path $src -ReferencedAssemblies System.Windows.Forms, System.Drawing, System.Core
    [PanicGuard]::Run($StopFlag, $PidFile, $Log, $Tag, $Minutes, [bool]$TestMode, $Cooldown)
} finally {
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
}
