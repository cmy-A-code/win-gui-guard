# run-guarded.ps1 - run one action through the fail-closed gate.
#   .\scripts\run-guarded.ps1 -Command "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Cursor]::Position"
param(
    [Parameter(Mandatory = $true)][string]$Command,
    [string]$Tag = 'action'
)
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\GuardTools.psm1') -Force
try {
    $code = Invoke-Guarded -Command $Command -Tag $Tag
    exit $code
} catch {
    Write-Output ('ABORTED: ' + $_.Exception.Message)
    exit 9
}
