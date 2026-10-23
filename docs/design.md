# Design notes

## Why this exists

GUI automation on a real desktop is dangerous in a specific way: the failure mode is
*the machine keeps doing things you did not ask for* (or stops doing the thing you did
ask for, silently). Libraries such as pyautogui, Playwright or AutoHotkey give you the
input primitives; they do not give you a governance layer. This project adds one:

1. **Arming is explicit.** A session starts with a guard process. No guard, no actions.
2. **The kill switch is physical.** ESC on a real keyboard, recognised through a
   low-level hook that ignores synthetic input.
3. **Actions are gated, not assumed.** Every action re-checks that the protection is
   still verifiably alive.

## State machine

```
                 arm
                  |
                  v
   +--------- CLEAR (0) ---------+
   |          ^      |           |
   |          |      | heartbeat |
   |          |      v           |
   |        STALE (7) <----------+
   |          |
   |          | missing files / dead pid
   |          v
   |      NOGUARD (8)
   |
   |  spec mismatch
   +----> BADSPEC (6)

   any state --(physical ESC)--> STOPPED (9)
                                   |
                   guard gone + no live automation pids
                                   v
                            auto-archived -> NOGUARD (8) -> re-arm
```

`Get-GuardState` is read-only except for one case: a **stale** stop flag (guard process
gone, no live automation PIDs) is copied to `STOP.flag.archived_*` and removed. A live
stop flag is never touched.

## Threat model

The guard is designed for **accidental and unauthorised automation**, not for an
attacker with local admin rights.

| Scenario | Covered |
|---|---|
| Agent keeps clicking after the user wanted it to stop | ESC fires, PIDs killed, gate refuses further actions |
| Agent hangs (heartbeat stops) | heartbeat stale -> gate aborts |
| Someone swaps the guard for a no-op | spec mismatch -> gate aborts |
| A script crashes leaving a stop flag | flagged as stale and archived automatically |
| Malicious code that actively bypasses the gate | **out of scope** — use OS-level controls too |

## Why injected input is ignored

`WH_KEYBOARD_LL` callbacks receive `KBDLLHOOKSTRUCT.flags`; bit `LLKHF_INJECTED` (0x10)
is set for input produced by `SendInput`, `keybd_event`, AutoHotkey and most automation
drivers. Ignoring injected events prevents two things:

- the automation from triggering its own stop flag on a stray synthetic ESC, and
- the automation from *faking* a stop to hide what it is doing (the log records
  `injectedSource=True` separately, so it remains visible).

Test mode (`-TestMode`, `STOP.selftest` only) exists for self-tests and never touches
the real flag.

## Why a spec fingerprint

A guard that silently runs with different trigger settings is worse than no guard:
everything looks protected while nothing is. `guard.spec` is written by the guard at
startup and contains the full trigger description; `approved.spec` is the copy written
when the operator armed the session. Any difference (including the injected-input
filter being turned off) makes the gate return `BADSPEC`.

## Optional: second factor (USB key)

Some deployments want "the guard only exists while an authorised dongle is plugged in".
That is easy to bolt on as an extra check in `Get-GuardState`: verify a removable drive
holds a key file whose hash matches a fingerprint that lives *on the same drive*
(fail-closed if missing). The check is intentionally not part of this repository — it is
environment-specific and easy to get wrong. See `docs/usb-key.md` for an outline.

## Runtime layout

```
runtime/
  guard.pid              guard process id
  guard.heartbeat        ticks, rewritten every 2 s
  guard.spec             trigger fingerprint written by the guard
  approved.spec          fingerprint approved when the session was armed
  STOP.flag              written on ESC (guardPid=<pid> inside)
  automation_pids.txt    PIDs registered by Invoke-Guarded while running
  guard-actions.log      per-action [tag] pid cmd exit
  audit.log              session events
  guard.log              guard host log
```
