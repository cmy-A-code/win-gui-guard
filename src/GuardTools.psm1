# WinGuiGuard - PowerShell module
#
# Fail-closed gate for Windows GUI automation.
#
#   Import-Module .\src\GuardTools.psm1
#   Start-Guard                                    # arm the ESC kill switch
#   Invoke-Guarded -Command "..." -Tag "click-1"   # every action goes through the gate
#   Get-GuardState                                 # 0 / 9 / 8 / 7 / 6
#   Stop-Guard -UserConfirmed                      # disarm (end of session)
#
# State codes
#   0  CLEAR    guard armed, heartbeat fresh, spec matches -> action allowed
#   9  STOPPED  a stop flag exists -> abort everything
#   8  NOGUARD  guard not running -> no protection
#   7  STALE    heartbeat older than 15 s -> guard may be hung
#   6  BADSPEC  guard spec changed after approval -> refuse
#
# Runtime files live in $env:WIN_GUI_GUARD_HOME (default: <repo>\runtime).

$script:GuardHome = if ($env:WIN_GUI_GUARD_HOME) { $env:WIN_GUI_GUARD_HOME } else { Join-Path (Split-Path -Parent $PSScriptRoot) 'runtime' }
$script:HeartbeatMaxAgeSec = 15

function Get-GuardPaths {
    $home2 = $script:GuardHome
    [pscustomobject]@{
        Home     = $home2
        Flag     = Join-Path $home2 'STOP.flag'
        PidFile  = Join-Path $home2 'guard.pid'
        Heartbeat= Join-Path $home2 'guard.heartbeat'
        Spec     = Join-Path $home2 'guard.spec'
        Approved = Join-Path $home2 'approved.spec'
        AutoPids = Join-Path $home2 'automation_pids.txt'
        Log      = Join-Path $home2 'guard-actions.log'
        Audit    = Join-Path $home2 'audit.log'
        HostLog  = Join-Path $home2 'guard.log'
    }
}

function Ensure-GuardHome {
    if (-not (Test-Path $script:GuardHome)) { New-Item -ItemType Directory -Force -Path $script:GuardHome | Out-Null }
}

function Write-Audit([string]$Message) {
    try {
        $p = Get-GuardPaths
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [guard] $Message" | Add-Content -Path $p.Audit -Encoding UTF8
    } catch { }
}

function Test-GuardProcessAlive([string]$PidFile) {
    if (-not (Test-Path $PidFile)) { return $null }
    $raw = (Get-Content $PidFile -Raw -ErrorAction SilentlyContinue)
    if ($raw -match '^\s*(\d+)\s*$') {
        $gpid = [int]$Matches[1]
        $proc = Get-Process -Id $gpid -ErrorAction SilentlyContinue
        if ($proc) { return $gpid }
    }
    return $null
}

function Get-GuardState {
    $p = Get-GuardPaths
    $state = [pscustomobject]@{
        Code = 0; Name = 'CLEAR'; Message = 'guard armed, protected'; GuardPid = $null; HeartbeatAge = $null
    }

    # 9 - stop flag. A flag whose guard process is gone and that has no live
    # automation PIDs is stale; archive it instead of blocking forever.
    if (Test-Path $p.Flag) {
        $content = Get-Content $p.Flag -Raw -ErrorAction SilentlyContinue
        $gpid = 0
        if ($content -match 'guardPid=(\d+)') { $gpid = [int]$Matches[1] }
        $guardAlive = $false
        if ($gpid -gt 0) { $guardAlive = $null -ne (Get-Process -Id $gpid -ErrorAction SilentlyContinue) }
        if (-not $guardAlive) { $guardAlive = $null -ne (Test-GuardProcessAlive $p.PidFile) }

        $anyAuto = $false
        if (Test-Path $p.AutoPids) {
            foreach ($line in (Get-Content $p.AutoPids)) {
                $t = $line.Trim()
                if ($t -match '^\d+$' -and (Get-Process -Id ([int]$t) -ErrorAction SilentlyContinue)) { $anyAuto = $true; break }
            }
        }

        if ((-not $guardAlive) -and (-not $anyAuto)) {
            $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
            Copy-Item $p.Flag (Join-Path $p.Home ("STOP.flag.archived_" + $stamp)) -Force -ErrorAction SilentlyContinue
            Remove-Item $p.Flag -Force -ErrorAction SilentlyContinue
            Write-Audit "stale STOP.flag auto-archived (guardPid=$gpid gone, no automation pids)"
        } else {
            $state.Code = 9; $state.Name = 'STOPPED'; $state.Message = 'stop flag is active - abort all actions'
            return $state
        }
    }

    # 8 - guard process
    $guardPid = Test-GuardProcessAlive $p.PidFile
    if (-not $guardPid) {
        $state.Code = 8; $state.Name = 'NOGUARD'; $state.Message = 'guard is not running - no protection'
        return $state
    }
    $state.GuardPid = $guardPid

    # 7 - heartbeat freshness
    if (Test-Path $p.Heartbeat) {
        try {
            $ticks = [int64]((Get-Content $p.Heartbeat -Raw).Trim())
            $age = [double]([DateTime]::Now.Ticks - $ticks) / 10000000.0
            $state.HeartbeatAge = [math]::Round($age, 1)
            if ($age -gt $script:HeartbeatMaxAgeSec) {
                $state.Code = 7; $state.Name = 'STALE'; $state.Message = ("heartbeat is {0:N1}s old (> {1}s)" -f $age, $script:HeartbeatMaxAgeSec)
                return $state
            }
        } catch {
            $state.Code = 7; $state.Name = 'STALE'; $state.Message = 'heartbeat unreadable - treat as unprotected'
            return $state
        }
    }

    # 6 - spec fingerprint
    if (-not (Test-Path $p.Approved)) {
        $state.Code = 6; $state.Name = 'BADSPEC'; $state.Message = 'approved.spec missing - protection cannot be verified'
        return $state
    }
    $approved = (Get-Content $p.Approved -Raw).Trim()
    $current = if (Test-Path $p.Spec) { (Get-Content $p.Spec -Raw).Trim() } else { '' }
    if ($current -ne $approved) {
        $state.Code = 6; $state.Name = 'BADSPEC'; $state.Message = 'guard spec differs from the approved spec'
        return $state
    }

    return $state
}

function Start-Guard {
    param([int]$Minutes = 120, [string]$Tag = 'session', [int]$CooldownMs = 5000, [int]$TimeoutSec = 15)
    Ensure-GuardHome
    $p = Get-GuardPaths

    if (Test-Path $p.Flag) {
        throw "Cannot arm: a stop flag exists ($($p.Flag)). Clear it after confirming automation is fully stopped."
    }

    Remove-Item $p.PidFile -Force -ErrorAction SilentlyContinue
    Remove-Item $p.Heartbeat -Force -ErrorAction SilentlyContinue
    Remove-Item $p.Spec -Force -ErrorAction SilentlyContinue

    $hostScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\guard-host.ps1'
    if (-not (Test-Path $hostScript)) { throw "guard-host.ps1 not found: $hostScript" }

    $startArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $hostScript,
        '-StopFlag', $p.Flag, '-PidFile', $p.PidFile, '-Log', $p.HostLog, '-Tag', $Tag,
        '-Minutes', "$Minutes", '-Cooldown', "$CooldownMs"
    )
    Start-Process 'powershell.exe' -ArgumentList $startArgs -WindowStyle Hidden | Out-Null

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $ready = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
        if ((Test-GuardProcessAlive $p.PidFile) -and (Test-Path $p.Heartbeat)) { $ready = $true; break }
    }
    if (-not $ready) { throw 'Guard did not become ready in time.' }

    $current = (Get-Content $p.Spec -Raw).Trim()
    Set-Content -Path $p.Approved -Value $current -Encoding UTF8
    Write-Audit "guard armed (tag=$Tag, pid=$(Test-GuardProcessAlive $p.PidFile))"
    return (Get-GuardState)
}

function Invoke-Guarded {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string]$Tag = 'action',
        [switch]$AllowArmedOnly
    )
    $p = Get-GuardPaths
    $state = Get-GuardState
    if ($state.Code -ne 0) {
        throw "ABORTED [$Tag]: $($state.Name) - $($state.Message)"
    }

    $auto = $p.AutoPids
    Add-Content -Path $auto -Value $PID -Encoding ASCII
    $exit = 0
    try {
        $global:LASTEXITCODE = 0
        Invoke-Expression $Command
        $exit = $LASTEXITCODE
    } finally {
        if (Test-Path $auto) {
            $keep = @(Get-Content $auto | Where-Object { $_.Trim() -ne "$PID" })
            if ($keep.Count -gt 0) { Set-Content -Path $auto -Value $keep -Encoding ASCII }
            else { Remove-Item $auto -Force -ErrorAction SilentlyContinue }
        }
    }

    if (Test-Path $p.Flag) {
        throw "POST-CHECK [$Tag]: stop flag appeared while the action was running - cancel all remaining actions."
    }
    return $exit
}

function Stop-Guard {
    param([switch]$UserConfirmed)
    if (-not $UserConfirmed) {
        throw 'Stop-Guard requires -UserConfirmed: only the user (or a confirmed end-of-session flow) may disarm.'
    }
    $p = Get-GuardPaths
    $guardPid = Test-GuardProcessAlive $p.PidFile
    if ($guardPid) {
        Stop-Process -Id $guardPid -Force -ErrorAction SilentlyContinue
        Write-Audit "guard stopped (pid=$guardPid)"
    }
    Remove-Item $p.PidFile -Force -ErrorAction SilentlyContinue
    Remove-Item $p.Heartbeat -Force -ErrorAction SilentlyContinue
    Remove-Item $p.Spec -Force -ErrorAction SilentlyContinue
}

function Complete-Session {
    param([switch]$UserConfirmed)
    Stop-Guard -UserConfirmed:$UserConfirmed
    $p = Get-GuardPaths
    if (Test-Path $p.Flag) {
        $content = Get-Content $p.Flag -Raw -ErrorAction SilentlyContinue
        $gpid = 0
        if ($content -match 'guardPid=(\d+)') { $gpid = [int]$Matches[1] }
        $alive = ($gpid -gt 0 -and ($null -ne (Get-Process -Id $gpid -ErrorAction SilentlyContinue)))
        if (-not $alive) {
            $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
            Copy-Item $p.Flag (Join-Path $p.Home ("STOP.flag.archived_" + $stamp)) -Force -ErrorAction SilentlyContinue
            Remove-Item $p.Flag -Force -ErrorAction SilentlyContinue
            Write-Audit "STOP.flag archived by Complete-Session"
        }
    }
    return (Get-GuardState)
}

Export-ModuleMember -Function Get-GuardState, Start-Guard, Invoke-Guarded, Stop-Guard, Complete-Session
