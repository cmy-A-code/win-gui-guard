# win-gui-guard

**A fail-closed safety layer for Windows GUI automation.**

If you let an AI agent (or any script) move the mouse, type text, or click through
UIs on a real desktop, you need three things: a way to arm the session explicitly,
a way to stop it *instantly*, and a record of every action. `win-gui-guard` gives you
those three, in ~600 lines of PowerShell + one small C# file.

It does not replace your automation library (pyautogui, Playwright, AutoHotkey,
SendInput wrappers, ...). It sits *around* it and refuses to let an action run when
the protection is not verifiably alive.

```
arm  ->  invoke-guarded (action)  ->  invoke-guarded (action)  ->  ESC  ->  stopped
 |            |                         |                          |
 +-- guard process + heartbeat + spec fingerprint + audit log -----+
```

## Features

- **Explicit arming.** Nothing runs until `Start-Guard` succeeds; the guard refuses to arm while a stop flag exists.
- **Hardware kill switch.** A physical **ESC** key press stops everything: writes a stop flag, then kills every automation PID registered with the guard.
- **Injection-proof.** Synthetic keystrokes carry the `LLKHF_INJECTED` flag and are ignored, so the automation cannot fire (or fake) its own kill switch.
- **Fail-closed action gate.** Every action first verifies: no stop flag, guard process alive, heartbeat < 15 s old, guard spec equals the approved spec. Otherwise it aborts with a distinct exit code.
- **Spec fingerprint.** The guard publishes `guard.spec`; a swapped or downgraded guard produces a mismatch and actions are refused.
- **PID whitelist on stop, process tree included.** Only interpreter/automation hosts started *after* the guard are killed, and each one is killed with `taskkill /T` so its child processes go too — recycled PIDs are never touched.
- **Audit trail.** `audit.log` (session events) and `guard-actions.log` (per-action tag, PID, exit code).
- **No UI, no dependencies.** Hidden PowerShell host + one C# file compiled on the fly by `Add-Type`.

## State codes

| Code | Name    | Meaning                                        | Action            |
|------|---------|------------------------------------------------|-------------------|
| 0    | CLEAR   | guard armed, heartbeat fresh, spec matches     | allowed           |
| 9    | STOPPED | stop flag active                               | abort everything  |
| 8    | NOGUARD | guard process not running                      | abort             |
| 7    | STALE   | heartbeat older than 15 s                      | abort             |
| 6    | BADSPEC | guard spec differs from the approved spec      | abort             |

## Quick start

```powershell
# 1. arm (writes runtime state under .\runtime by default)
.\scripts\arm.ps1 -Minutes 120 -Tag my-session

# 2. every automated action goes through the gate
.\scripts\run-guarded.ps1 -Command "python C:\work\click.py" -Tag click-1

# 3. check state any time (read-only)
.\scripts\status.ps1

# 4. end of session (requires -Confirm)
.\scripts\disarm.ps1 -Confirm
```

Runtime directory can be moved with `$env:WIN_GUI_GUARD_HOME`.

### From Python

```python
import subprocess

def guarded(cmd: str, tag: str) -> int:
    r = subprocess.run(
        ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
         "-File", r".\scripts\run-guarded.ps1", "-Command", cmd, "-Tag", tag],
        capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"guard aborted: {r.stdout}{r.stderr}")
    return r.returncode
```

### From Node.js

```js
const { execFileSync } = require('node:child_process');
execFileSync('powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass',
  '-File', './scripts/run-guarded.ps1', '-Command', 'node ./click.js', '-Tag', 'click-1']);
```

## How it works

```
     arm                  run-guarded                     ESC
      |                        |                            |
      v                        v                            v
 guard-host.ps1          GuardTools.psm1               PanicGuard.cs
 (hidden PS)             (fail-closed gate)            (WH_KEYBOARD_LL hook)
      |                        |                            |
      |  heartbeat / spec      |  verify state              |  write STOP.flag
      |  guard.pid / .spec     |  register automation PID   |  kill automation PIDs
      +------------------------+----------------------------+
                               |
                          runtime/  (all state files)
```

All state lives in plain files so every layer can be inspected, tested and audited
independently: `guard.pid`, `guard.heartbeat`, `guard.spec`, `approved.spec`,
`STOP.flag`, `automation_pids.txt`, `audit.log`, `guard-actions.log`.

## Relationship to existing tools

This is a **governance layer**, not an input library. Use it *around* the tools you
already drive the desktop with:

- **pyautogui / pynput / AutoHotkey** — input primitives. pyautogui's `FAILSAFE`
  (move the mouse to a screen corner) raises an exception *inside the calling
  process*; it disappears when the process is stuck, replaced, or when someone sets
  `pyautogui.FAILSAFE = False`. win-gui-guard runs in its own process, watches the
  real keyboard, and refuses actions from the outside.
- **pywinauto / UIAutomation / Playwright** — UI drivers. They have no notion of
  "the operator wants out right now"; wrap `Invoke-Guarded` around them.
- **Scheduled sentinels / watchdogs** — complementary; they keep processes alive,
  the guard stops them.

## Design notes

- **Fail-closed by construction.** Missing file, unreadable heartbeat, dead PID — every one of them means *abort*, never *allow*.
- **The kill switch is physical.** ESC only, keydown only, real hardware only. No modifier combinations; SYSKEYDOWN (`Alt+ESC`) is ignored so the guard cannot collide with window-manager shortcuts.
- **Stopping is not enough; the guard must stay armed.** After firing, the guard keeps watching (5 s cooldown) so a second ESC press still works, and the session cannot silently continue.
- **Stale flags self-heal.** A stop flag whose guard process is gone and that has no live automation PIDs is archived automatically, so one crash does not block every future session.

## Limitations

- Windows only (WinForms message loop + `WH_KEYBOARD_LL`).
- Requires an interactive desktop session — not a service, not session 0.
- ESC is a *physical* key: a headless VM or remote KVM without a keyboard cannot use the switch (the gate itself still works).
- The guard protects *processes it started through the gate*. If something bypasses `Invoke-Guarded`, it is outside the guard's view by design; use it as one layer of a defence-in-depth setup.

## Layout

```
src/PanicGuard.cs      keyboard hook + stop logic (single C# file, no build step)
src/GuardTools.psm1    arming, gate, state machine, audit
scripts/arm.ps1        Start-Guard wrapper
scripts/run-guarded.ps1 one action through the gate
scripts/status.ps1     read-only state check
scripts/disarm.ps1     end-of-session (requires -Confirm)
docs/design.md         threat model and state machine details
```

## License

MIT — see [LICENSE](LICENSE).
