#========================================================
# "Audio Enhancement Service" — lappymood.ps1
#========================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── C# engine: hooks, audio, playback ──────────────────
$cs = @'
using System;
using System.IO;
using System.Text;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Forms;

// ─── PropVariant (minimal, for VT_UI4) ───
[StructLayout(LayoutKind.Sequential)]
public struct PropVariant {
    public ushort vt;
    ushort r1, r2, r3;
    public int intVal;
    int pad;
}

[StructLayout(LayoutKind.Sequential)]
public struct PropertyKey {
    public Guid fmtid;
    public int pid;
}

// ─── Core Audio COM Interfaces ───
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
public class MMDeviceEnumeratorClass {}

[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDeviceEnumerator {
    int EnumAudioEndpoints(uint dataFlow, uint stateMask, out IntPtr ppDevices);
    int GetDefaultAudioEndpoint(uint dataFlow, uint role, out IMMDevice ppEndpoint);
}

[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDevice {
    int Activate(ref Guid iid, uint dwClsCtx, IntPtr pActivationParams,
        [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
    int OpenPropertyStore(int stgmAccess, out IPropertyStore ppProperties);
    int GetId([MarshalAs(UnmanagedType.LPWStr)] out string ppstrId);
    int GetState(out uint pdwState);
}

[Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPropertyStore {
    int GetCount(out uint cProps);
    int GetAt(uint iProp, out PropertyKey pkey);
    int GetValue(ref PropertyKey key, out PropVariant pv);
    int SetValue(ref PropertyKey key, ref PropVariant propvar);
    int Commit();
}

[Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAudioEndpointVolume {
    int RegisterControlChangeNotify(IntPtr pNotify);
    int UnregisterControlChangeNotify(IntPtr pNotify);
    int GetChannelCount(out int pnChannelCount);
    int SetMasterVolumeLevel(float fLevelDB, ref Guid pguidEventContext);
    int SetMasterVolumeLevelScalar(float fLevel, ref Guid pguidEventContext);
    int GetMasterVolumeLevel(out float pfLevelDB);
    int GetMasterVolumeLevelScalar(out float pfLevel);
    int SetChannelVolumeLevel(uint nChannel, float fLevelDB, ref Guid pguidEventContext);
    int SetChannelVolumeLevelScalar(uint nChannel, float fLevel, ref Guid pguidEventContext);
    int GetChannelVolumeLevel(uint nChannel, out float pfLevelDB);
    int GetChannelVolumeLevelScalar(uint nChannel, out float pfLevel);
    int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, ref Guid pguidEventContext);
    int GetMute([MarshalAs(UnmanagedType.Bool)] out bool pbMute);
}

// ─── Audio Helper ───
public static class AudioHelper {
    private static IAudioEndpointVolume GetVolumeInterface() {
        var e = (IMMDeviceEnumerator)new MMDeviceEnumeratorClass();
        IMMDevice d; e.GetDefaultAudioEndpoint(0, 1, out d);
        Guid g = typeof(IAudioEndpointVolume).GUID;
        object o; d.Activate(ref g, 23, IntPtr.Zero, out o);
        return (IAudioEndpointVolume)o;
    }

    public static float GetVolume() {
        try { float v; GetVolumeInterface().GetMasterVolumeLevelScalar(out v); return v; }
        catch { return 0.5f; }
    }

    public static void SetVolume(float level) {
        try {
            Guid empty = Guid.Empty;
            GetVolumeInterface().SetMasterVolumeLevelScalar(
                Math.Max(0f, Math.Min(1f, level)), ref empty);
        } catch {}
    }

    public static bool GetMute() {
        try { bool m; GetVolumeInterface().GetMute(out m); return m; }
        catch { return false; }
    }

    public static void SetMute(bool mute) {
        try {
            Guid empty = Guid.Empty;
            GetVolumeInterface().SetMute(mute, ref empty);
        } catch {}
    }

    public static bool IsHeadphones() {
        try {
            var e = (IMMDeviceEnumerator)new MMDeviceEnumeratorClass();
            IMMDevice d; e.GetDefaultAudioEndpoint(0, 1, out d);
            IPropertyStore p; d.OpenPropertyStore(0, out p);
            PropertyKey key = new PropertyKey();
            key.fmtid = new Guid("1da5d803-d492-4edd-8c23-e0c0ffee7f0e");
            key.pid = 0;
            PropVariant pv; p.GetValue(ref key, out pv);
            return pv.intVal == 3 || pv.intVal == 5;
        } catch { return false; }
    }
}

// ─── MCI Playback ───
public static class MciPlayer {
    [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
    private static extern int mciSendStringW(string cmd, StringBuilder buf, int bufSz, IntPtr hwnd);

    private static int _counter = 0;

    public static string Play(string filePath) {
        string alias = "lm" + (_counter++);
        var sb = new StringBuilder(260);
        mciSendStringW("open \"" + filePath + "\" type mpegvideo alias " + alias, sb, 260, IntPtr.Zero);
        mciSendStringW("play " + alias, sb, 260, IntPtr.Zero);
        return alias;
    }

    public static int GetLengthMs(string alias) {
        var sb = new StringBuilder(64);
        mciSendStringW("status " + alias + " length", sb, 64, IntPtr.Zero);
        int ms; int.TryParse(sb.ToString(), out ms);
        return ms > 0 ? ms : 5000;
    }

    public static void Close(string alias) {
        mciSendStringW("close " + alias, null, 0, IntPtr.Zero);
    }
}

// ─── Input Hooks ───
public static class InputHook {
    public delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")] public static extern IntPtr SetWindowsHookEx(int id, HookProc proc, IntPtr hMod, uint threadId);
    [DllImport("user32.dll")] public static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")] public static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")] public static extern IntPtr GetModuleHandle(string name);

    private static IntPtr _kbHook, _msHook;
    private static HookProc _kbProc, _msProc;
    private static Random _rng = new Random();

    public static int KeyCount = 0;
    public static int ClickCount = 0;
    public static int KeyThreshold;
    public static int ClickThreshold;
    public static bool PlayKeySound = false;
    public static bool PlayClickSound = false;

    public static void Init() {
        KeyThreshold = _rng.Next(400, 601);
        ClickThreshold = _rng.Next(80, 121);
    }

    public static void Install() {
        _kbProc = KbCallback;
        _msProc = MsCallback;
        using (var p = Process.GetCurrentProcess())
        using (var m = p.MainModule) {
            IntPtr h = GetModuleHandle(m.ModuleName);
            _kbHook = SetWindowsHookEx(13, _kbProc, h, 0);
            _msHook = SetWindowsHookEx(14, _msProc, h, 0);
        }
    }

    public static void Uninstall() {
        if (_kbHook != IntPtr.Zero) UnhookWindowsHookEx(_kbHook);
        if (_msHook != IntPtr.Zero) UnhookWindowsHookEx(_msHook);
    }

    private static IntPtr KbCallback(int nCode, IntPtr wParam, IntPtr lParam) {
        if (nCode >= 0 && wParam == (IntPtr)0x0100) {
            KeyCount++;
            if (KeyCount >= KeyThreshold) {
                PlayKeySound = true;
                KeyCount = 0;
                KeyThreshold = _rng.Next(400, 601);
            }
        }
        return CallNextHookEx(_kbHook, nCode, wParam, lParam);
    }

    private static IntPtr MsCallback(int nCode, IntPtr wParam, IntPtr lParam) {
        if (nCode >= 0 && wParam == (IntPtr)0x0201) {
            ClickCount++;
            if (ClickCount >= ClickThreshold) {
                PlayClickSound = true;
                ClickCount = 0;
                ClickThreshold = _rng.Next(80, 121);
            }
        }
        return CallNextHookEx(_msHook, nCode, wParam, lParam);
    }
}
'@

Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Windows.Forms

# ── Resolve sounds folder ──────────────────────────────
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$soundsDir = Join-Path $scriptDir "sounds"
$soundFiles = @()
if (Test-Path $soundsDir) {
    $soundFiles = @(Get-ChildItem -Path $soundsDir -Filter "*.mp3" -File | Select-Object -ExpandProperty FullName)
}
if ($soundFiles.Count -eq 0) { exit }

$rng = New-Object System.Random
$isPlaying = $false
$savedVolume = 0.5
$savedMute = $false
$wasMaxed = $false
$currentAlias = ""

# ── Play sound function ────────────────────────────────
function Play-RandomSound {
    if ($script:isPlaying) { return }
    if ($script:soundFiles.Count -eq 0) { return }

    $script:isPlaying = $true

    # Pick random sound
    $file = $script:soundFiles[$script:rng.Next($script:soundFiles.Count)]

    # Volume logic
    $headphones = [AudioHelper]::IsHeadphones()
    if (-not $headphones) {
        $script:savedVolume = [AudioHelper]::GetVolume()
        $script:savedMute = [AudioHelper]::GetMute()
        [AudioHelper]::SetMute($false)
        [AudioHelper]::SetVolume(1.0)
        $script:wasMaxed = $true
    } else {
        $script:wasMaxed = $false
    }

    # Play via MCI
    $script:currentAlias = [MciPlayer]::Play($file)
    $lengthMs = [MciPlayer]::GetLengthMs($script:currentAlias)

    # Schedule volume restore + cleanup
    $script:restoreTimer.Interval = $lengthMs + 800
    $script:restoreTimer.Start()
}

# ── Hidden form + tray icon ────────────────────────────
$form = New-Object System.Windows.Forms.Form
$form.ShowInTaskbar = $false
$form.WindowState = 'Minimized'
$form.FormBorderStyle = 'FixedToolWindow'
$form.Opacity = 0
$form.Size = New-Object System.Drawing.Size(1, 1)

# Tray icon
$trayIcon = New-Object System.Windows.Forms.NotifyIcon
try {
    $sndVolPath = Join-Path $env:SystemRoot "System32\SndVol.exe"
    if (Test-Path $sndVolPath) {
        $trayIcon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($sndVolPath)
    } else {
        $trayIcon.Icon = [System.Drawing.SystemIcons]::Application
    }
} catch {
    $trayIcon.Icon = [System.Drawing.SystemIcons]::Application
}
$trayIcon.Text = "Windows Audio Enhancement Service"
$trayIcon.Visible = $false

# Context menu — label only, no exit
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$label1 = $menu.Items.Add("Audio Enhancement Service v2.4")
$label1.Enabled = $false
$label2 = $menu.Items.Add("Status: Running")
$label2.Enabled = $false
$trayIcon.ContextMenuStrip = $menu

# ── Initialize hooks ───────────────────────────────────
[InputHook]::Init()
[InputHook]::Install()

# ── Check timer (polls flags every 250ms) ──────────────
$checkTimer = New-Object System.Windows.Forms.Timer
$checkTimer.Interval = 250
$checkTimer.Add_Tick({
    if ([InputHook]::PlayKeySound) {
        [InputHook]::PlayKeySound = $false
        Play-RandomSound
    }
    if ([InputHook]::PlayClickSound) {
        [InputHook]::PlayClickSound = $false
        Play-RandomSound
    }
})
$checkTimer.Start()

# ── Restore timer (one-shot, restores volume after sound ends) ──
$restoreTimer = New-Object System.Windows.Forms.Timer
$restoreTimer.Interval = 5000
$restoreTimer.Add_Tick({
    $script:restoreTimer.Stop()
    if ($script:wasMaxed) {
        [AudioHelper]::SetVolume($script:savedVolume)
        [AudioHelper]::SetMute($script:savedMute)
        $script:wasMaxed = $false
    }
    if ($script:currentAlias -ne "") {
        [MciPlayer]::Close($script:currentAlias)
        $script:currentAlias = ""
    }
    $script:isPlaying = $false
})

# ── Cleanup on form close ─────────────────────────────
$form.Add_FormClosed({
    $checkTimer.Stop()
    $restoreTimer.Stop()
    [InputHook]::Uninstall()
    $trayIcon.Visible = $false
    $trayIcon.Dispose()
})

# ── Run ────────────────────────────────────────────────
[System.Windows.Forms.Application]::Run($form)
