<#
.SYNOPSIS
    Native Win32 API Bindings for Windows 11
.DESCRIPTION
    Provides P/Invoke bindings for per-process I/O byte counters (kernel32.dll)
    and Windows 11 DWM dark title bar and rounded corner attributes (dwmapi.dll).
#>

$csharpNative = @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class Win11Native {
    [StructLayout(LayoutKind.Sequential)]
    public struct IO_COUNTERS {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetProcessIoCounters(IntPtr hProcess, out IO_COUNTERS counters);

    public static ulong GetProcessBytes(int pid) {
        try {
            using (Process p = Process.GetProcessById(pid)) {
                IO_COUNTERS c;
                if (GetProcessIoCounters(p.Handle, out c)) {
                    return c.ReadTransferCount + c.WriteTransferCount;
                }
            }
        } catch {}
        return 0;
    }

    [DllImport("dwmapi.dll", PreserveSig = true)]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

    public const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    public const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    public const int DWMWCP_ROUND = 2;

    public static void ApplyWin11Aesthetics(IntPtr hwnd) {
        try {
            int dark = 1;
            DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref dark, sizeof(int));
            int round = DWMWCP_ROUND;
            DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref round, sizeof(int));
        } catch {}
    }
}
'@

Add-Type -TypeDefinition $csharpNative -ErrorAction SilentlyContinue
