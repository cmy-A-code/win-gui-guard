using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

// ============================================================================
// WinGuiGuard - panic guard
//
// A silent, always-on keyboard hook that turns a *physical* ESC key press into
// an immediate stop for every automated GUI action started through the guard.
//
// Design rules:
//   * Only a real, hardware ESC keydown fires the switch. Synthetic input
//     (SendInput / keybd_event / AutoHotkey / Playwright) carries the
//     LLKHF_INJECTED flag and is ignored, so the automation cannot trigger
//     (or mask) its own kill switch.
//   * Firing is fail-safe: the flag file is written first, then every
//     automation PID registered with the guard is terminated, then the guard
//     re-arms itself (default cooldown 5 s) so the session stays protected.
//   * The guard publishes a heartbeat and a spec fingerprint. Any action gate
//     refuses to run when the heartbeat is stale or the spec was changed.
//
// Usage (from PowerShell, see GuardTools.psm1):
//   [PanicGuard]::Run($stopFlagPath, $automationPidFile, $logPath, $tag,
//                      $minutes, $testMode, $cooldownMs);
// ============================================================================
public class PanicGuard
{
    private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true, EntryPoint = "SetWindowsHookEx")]
    private static extern IntPtr SetWindowsHookExKb(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Auto)]
    private static extern IntPtr GetModuleHandle(string lpModuleName);
    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);

    [StructLayout(LayoutKind.Sequential)]
    public struct KBDLLHOOKSTRUCT { public uint vkCode; public uint scanCode; public uint flags; public uint time; public IntPtr dwExtraInfo; }

    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100;
    private const uint VK_ESCAPE = 0x1B;
    private const uint LLKHF_INJECTED = 0x10;

    // Written to guard.spec; action gates compare it with their approved copy
    // so a swapped or downgraded guard cannot silently authorise actions.
    public const string SPEC = "esc-only-v1|trigger=physical-key-esc|keyboard=esc-only|move=none|wheel=none|mode=persistent";

    private static IntPtr kbHook = IntPtr.Zero;
    private static LowLevelKeyboardProc kbProc;
    private static string flagPath, pidPath, logPath, tag, hbPath, specPath;
    private static System.Windows.Forms.Timer idleTimer;
    private static bool testMode = false, fired = false;
    private static int cooldownMs = 5000;
    private static uint lastFireMs = 0;
    private static DateTime guardStart;

    public static void Run(string stopFlagPath, string automationPidFile, string logFilePath, string tagName,
                           int minutes, bool acceptInjectedInputs, int cooldown)
    {
        flagPath = stopFlagPath; pidPath = automationPidFile; logPath = logFilePath; tag = tagName;
        testMode = acceptInjectedInputs; cooldownMs = cooldown;

        string dir = Path.GetDirectoryName(stopFlagPath);
        if (testMode) flagPath = Path.Combine(dir, "STOP.selftest");   // test mode never touches the real stop flag
        hbPath = Path.Combine(dir, "guard.heartbeat");
        specPath = Path.Combine(dir, "guard.spec");

        try { guardStart = Process.GetCurrentProcess().StartTime; } catch { guardStart = DateTime.Now; }

        string spec = SPEC + "|injectedFilter=" + (testMode ? "off" : "on") + "|testMode=" + (testMode ? "1" : "0");
        try { File.WriteAllText(specPath, spec, Encoding.UTF8); } catch { }

        // A Control instance is only used to create a Windows message queue for the
        // hook callback thread.
        Control marshaler = new Control();
        IntPtr forceCreate = marshaler.Handle;

        kbProc = KbHook;
        kbHook = SetWindowsHookExKb(WH_KEYBOARD_LL, kbProc, GetModuleHandle(null), 0);
        if (kbHook == IntPtr.Zero) { Log("ERROR: keyboard hook failed, win32err=" + Marshal.GetLastWin32Error()); return; }

        Log("guard started (tag=" + tag + ", pid=" + Process.GetCurrentProcess().Id + ", spec=" + spec + ")");

        try { File.WriteAllText(hbPath, DateTime.Now.Ticks.ToString()); } catch { }
        System.Windows.Forms.Timer hb = new System.Windows.Forms.Timer();
        hb.Interval = 2000;
        hb.Tick += delegate { try { File.WriteAllText(hbPath, DateTime.Now.Ticks.ToString()); } catch { } };
        hb.Start();

        idleTimer = new System.Windows.Forms.Timer();
        idleTimer.Interval = Math.Max(1, minutes) * 60 * 1000;
        idleTimer.Tick += delegate { Log("guard idle timeout, exiting"); Unhook(); Application.ExitThread(); };
        idleTimer.Start();

        Application.Run();
    }

    private static void Unhook()
    {
        try { if (kbHook != IntPtr.Zero) UnhookWindowsHookEx(kbHook); } catch { }
    }

    private static IntPtr KbHook(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 && !fired)
        {
            int msg = wParam.ToInt32();
            // WM_KEYDOWN only: SYSKEYDOWN (Alt+ESC) is intentionally ignored so the
            // guard cannot collide with window-manager shortcuts.
            if (msg == WM_KEYDOWN)
            {
                KBDLLHOOKSTRUCT k = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
                if (k.vkCode == VK_ESCAPE)
                {
                    bool injected = (k.flags & LLKHF_INJECTED) != 0;
                    if (injected && !testMode)
                    {
                        return CallNextHookEx(kbHook, nCode, wParam, lParam);   // synthetic ESC never fires
                    }
                    uint now = (uint)Environment.TickCount;
                    if (lastFireMs != 0 && (uint)(now - lastFireMs) < (uint)cooldownMs)
                    {
                        return CallNextHookEx(kbHook, nCode, wParam, lParam);   // cooldown, do not re-fire
                    }
                    Trigger("KEY_ESC_DOWN", injected);
                }
            }
        }
        return CallNextHookEx(kbHook, nCode, wParam, lParam);   // never swallow user input
    }

    private static void Trigger(string reason, bool injected)
    {
        lastFireMs = (uint)Environment.TickCount;
        string fg = ForegroundTitle();
        Log("PANIC: " + reason + " at " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") +
            " | foreground=" + fg + " | injectedSource=" + injected + " | testMode=" + testMode);

        try
        {
            File.WriteAllText(flagPath,
                "stopped=" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") +
                "\r\ntrigger=" + reason +
                "\r\nforeground=" + fg +
                "\r\ntag=" + tag +
                "\r\nmode=" + (testMode ? "SELFTEST" : "REAL") +
                "\r\nguardPid=" + Process.GetCurrentProcess().Id + "\r\n", Encoding.UTF8);
        }
        catch (Exception e) { Log("flag write failed: " + e.Message); }

        if (!testMode)
        {
            ThreadPool.QueueUserWorkItem(delegate { KillListed(); });
        }

        Log("guard stays armed (cooldown " + cooldownMs + "ms, still protecting)");
    }

    private static void KillListed()
    {
        try
        {
            if (!File.Exists(pidPath)) { Log("no automation pid file"); return; }
            foreach (string raw in File.ReadAllLines(pidPath))
            {
                string s = raw.Trim();
                if (s.Length == 0) continue;
                int pid;
                if (!int.TryParse(s, out pid)) continue;
                try
                {
                    Process p = Process.GetProcessById(pid);
                    string n = p.ProcessName.ToLowerInvariant();
                    // Only kill interpreters/automation hosts, and only processes that
                    // started after the guard (a recycled PID must never be killed).
                    bool nameOk = (n == "powershell" || n == "pwsh" || n == "cmd" ||
                                   n == "python" || n == "pythonw" || n == "node" || n == "gx");
                    bool timeOk = false;
                    try { timeOk = (p.StartTime >= guardStart.AddSeconds(-5)); } catch { }
                    if (!nameOk || !timeOk)
                    {
                        Log("skip pid " + pid + " (" + n + ", nameOk=" + nameOk + ", timeOk=" + timeOk + ") - stale or unrelated, refusing to kill");
                        continue;
                    }
                    p.Kill();
                    Log("killed pid " + pid + " (" + p.ProcessName + ")");
                }
                catch (Exception e) { Log("kill " + pid + " failed: " + e.Message); }
            }
        }
        catch (Exception e) { Log("KillListed error: " + e.Message); }
    }

    private static string ForegroundTitle()
    {
        try
        {
            IntPtr h = GetForegroundWindow();
            StringBuilder sb = new StringBuilder(256);
            GetWindowText(h, sb, sb.Capacity);
            return sb.ToString();
        }
        catch { return "(unknown)"; }
    }

    private static void Log(string line)
    {
        try
        {
            File.AppendAllText(logPath,
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + " [" + tag + "] " + line + "\r\n", Encoding.UTF8);
        }
        catch { }
    }
}
