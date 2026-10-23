# Security review

Last run: 2026-10-23 · Windows 11 · PowerShell 5.1 · isolated runtime
(`$env:WIN_GUI_GUARD_HOME` pointed at a temp directory so the real session was untouched).

## Scope

- fail-closed gate across every state transition
- kill switch: injection filter, cooldown, process-tree termination
- file-based state: tampering, staleness, self-heal
- duplicate arming
- action logging

## Method

Adversarial scripted checks (17 scenarios) against an isolated runtime, plus manual
code review of `PanicGuard.cs` and `GuardTools.psm1`.

## Results

| # | Check | Expected | Result |
|---|-------|----------|--------|
| 1 | no guard running | 8 | pass |
| 2 | arm | 0 | pass |
| 3 | tampered `guard.spec` | 6 | pass |
| 4 | disarm + re-arm | 0 | pass |
| 5 | missing `approved.spec` | 6 | pass |
| 6 | disarm + re-arm again | 0 | pass |
| 7 | stale heartbeat (40 s old) | 7 | pass |
| 8 | heartbeat restored | 0 | pass |
| 9 | stop flag pointing at a live PID | 9 | pass |
| 10 | stop flag pointing at a dead PID | archived, then 8 | pass |
| 11 | archived copy written | yes | pass |
| 12 | arm after clear | 0 | pass |
| 13 | gated action with stop flag | 9 | pass |
| 14 | blocked command did not execute | yes | pass |
| 15 | duplicate arm refused | 1 | pass |
| 16 | guard PID unchanged after refusal | yes | pass |
| 17 | `guard-actions.log` gets RUN + DONE | yes | pass |

## Issues found and fixed in this pass

1. **Action log was never written.** `Invoke-Guarded` did not append to
   `guard-actions.log` even though the README promised it. Fixed: RUN/DONE lines with
   tag, PID, command and exit code.
2. **Kill switch killed only the registered PID.** The real automation usually runs as
   a child of the registered interpreter, so it could survive a stop. Fixed: each
   registered PID is now terminated with `taskkill /PID <pid> /T /F` (whole tree),
   with a `Process.Kill()` fallback.
3. **A second `Start-Guard` silently replaced the PID file** and left the first guard
   running (two keyboard hooks, one of them unreferenced). Fixed: arming is refused
   while a live guard exists; disarm first.

## Residual risks

See `docs/design.md` → "Known gaps": same-user runtime writes, the 15-second heartbeat
window, `-UserConfirmed` being a signal rather than an authentication boundary, and
best-effort process-tree killing.
