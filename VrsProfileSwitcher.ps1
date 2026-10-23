#Requires -Version 7.0
<#
.SYNOPSIS
    Switch VRS DirectForce wheelbase / pedal profiles with game controller buttons (e.g. PXN-CB1).

.DESCRIPTION
    Talks to the device through VRS's own SDK (SmartyCo.DirectForce.Wrapper.dll +
    direct_force_sdk_csharp.dll), which is extracted from the DirectForce Config Tool
    single-file bundle on first run. Profiles live on the device itself, so a switch made
    here is the same switch the Config Tool / VRS ONE make, and it works while either
    app is running.

    Sequence (same as the Config Tool's own "select profile"):
        LoadSettingsSync(dev) -> SetCurrentProfile(dev, idx) -> UpdateSettingsSync(dev)

.EXAMPLE
    .\VrsProfileSwitcher.ps1                 # run controller button listener using config.json
    .\VrsProfileSwitcher.ps1 -Install        # start with Windows, hidden in the background
    .\VrsProfileSwitcher.ps1 -Uninstall      # remove autostart and stop the background instance
    .\VrsProfileSwitcher.ps1 -ListControllers # show controllers' VID/PID and pressed button numbers
    .\VrsProfileSwitcher.ps1 -List           # list devices and their profiles
    .\VrsProfileSwitcher.ps1 -Select AC      # one-shot switch (wheelbase) by name or index
    .\VrsProfileSwitcher.ps1 -Select GT3 -Device Pedals
    .\VrsProfileSwitcher.ps1 -Next / -Previous
#>
[CmdletBinding(DefaultParameterSetName = 'Listen')]
param(
    [string]$Config = (Join-Path $PSScriptRoot 'config.json'),
    [Parameter(ParameterSetName = 'List')]     [switch]$List,
    [Parameter(ParameterSetName = 'Select')]   [string]$Select,
    [Parameter(ParameterSetName = 'Next')]     [switch]$Next,
    [Parameter(ParameterSetName = 'Previous')] [switch]$Previous,
    [Parameter(ParameterSetName = 'Install')]  [switch]$Install,
    [Parameter(ParameterSetName = 'Uninstall')][switch]$Uninstall,
    [Parameter(ParameterSetName = 'ListControllers')][switch]$ListControllers,
    [string]$Device,
    [switch]$ReExtractSdk
)

$ErrorActionPreference = 'Stop'
$SdkDir = Join-Path $PSScriptRoot 'sdk'
$SdkFiles = 'SmartyCo.DirectForce.Wrapper.dll', 'direct_force_sdk_csharp.dll',
            'msvcp140.dll', 'VCRUNTIME140.dll', 'VCRUNTIME140_1.dll'

# ---------------------------------------------------------------- config

$cfg = if (Test-Path $Config) { Get-Content $Config -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
$ConfigToolExe = $cfg.configToolExe ?? (Join-Path $env:LOCALAPPDATA 'DirectForce\DirectForce Config tool.exe')
$DefaultDevice = $Device ? $Device : ($cfg.defaultDevice ?? 'Wheel Base')
$Speak         = [bool]($cfg.speak ?? $true)
$Wrap          = [bool]($cfg.wrapAround ?? $true)

$LogFile = Join-Path $PSScriptRoot 'VrsProfileSwitcher.log'
function Write-Log([string]$msg, [string]$color = 'Gray') {
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $msg
    Write-Host $line -ForegroundColor $color
    if ($PSCmdlet.ParameterSetName -eq 'Listen') { Add-Content $LogFile $line -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------- autostart

$StartupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'VRS Profile Switcher.lnk'
if ($Install -or $Uninstall) {
    if ($Uninstall) {
        Remove-Item $StartupLink -ErrorAction SilentlyContinue
        Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" |
            Where-Object { $_.CommandLine -like '*VrsProfileSwitcher.ps1*' -and $_.ProcessId -ne $PID } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
        Write-Host 'Autostart removed and background instance stopped.'
        return
    }
    $pwsh = (Get-Process -Id $PID).Path
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($StartupLink)
    $lnk.TargetPath = $pwsh
    $lnk.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.WindowStyle = 7   # minimized, so nothing flashes up at logon
    $lnk.Save()
    Start-Process $pwsh -ArgumentList $lnk.Arguments -WindowStyle Hidden
    Write-Host "Autostart installed ($StartupLink) and started in the background."
    return
}

# ---------------------------------------------------------------- game controllers

# Polls game controllers through WinMM, which (unlike DirectInput) works without window focus.
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class Joystick {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct CAPS {
        public ushort wMid, wPid;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szPname;
        public uint xmin, xmax, ymin, ymax, zmin, zmax, numButtons, periodMin, periodMax,
                    rmin, rmax, umin, umax, vmin, vmax, caps, maxAxes, numAxes, maxButtons;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szRegKey;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szOEMVxD;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct INFO { public uint size, flags, x, y, z, r, u, v, buttons, buttonNumber, pov, res1, res2; }
    [DllImport("winmm.dll", CharSet = CharSet.Unicode)] static extern int joyGetDevCapsW(IntPtr id, ref CAPS c, int size);
    [DllImport("winmm.dll")] static extern int joyGetPosEx(int id, ref INFO i);

    // Joystick slot for a VID/PID, or -1 if not connected.
    public static int Find(ushort vid, ushort pid) {
        for (int i = 0; i < 16; i++) {
            var c = new CAPS();
            if (joyGetDevCapsW((IntPtr)i, ref c, Marshal.SizeOf<CAPS>()) == 0 && c.wMid == vid && c.wPid == pid) return i;
        }
        return -1;
    }
    // "slot|VID|PID|name|buttons" for every connected controller.
    public static string[] List() {
        var r = new System.Collections.Generic.List<string>();
        for (int i = 0; i < 16; i++) {
            var c = new CAPS();
            if (joyGetDevCapsW((IntPtr)i, ref c, Marshal.SizeOf<CAPS>()) == 0)
                r.Add($"{i}|{c.wMid:X4}|{c.wPid:X4}|{c.szPname}|{c.numButtons}");
        }
        return r.ToArray();
    }
    // Bitmask of pressed buttons (bit 0 = button 1), or -1 if the device is gone.
    public static long Buttons(int id) {
        var i = new INFO { size = (uint)Marshal.SizeOf<INFO>(), flags = 0x80 /* JOY_RETURNBUTTONS */ };
        return joyGetPosEx(id, ref i) == 0 ? i.buttons : -1;
    }
}
'@

if ($ListControllers) {
    # Names come from the joystick OEM registry entries; WinMM itself only reports a generic driver name.
    $oem = 'HKCU:\System\CurrentControlSet\Control\MediaProperties\PrivateProperties\Joystick\OEM'
    $pads = foreach ($row in [Joystick]::List()) {
        $slot, $v, $p, $drv, $nb = $row -split '\|'
        $name = (Get-ItemProperty "$oem\VID_$v&PID_$p" -ErrorAction SilentlyContinue).OEMName
        [pscustomobject]@{ Slot = [int]$slot; VID = $v; PID = $p; Buttons = [int]$nb; Name = ($name ?? $drv).Trim() }
    }
    $pads | Format-Table Name, VID, PID, Buttons -AutoSize | Out-Host
    Write-Host 'Press buttons on your controller to see their numbers (Ctrl+C to quit)...' -ForegroundColor Cyan
    $last = @{}
    while ($true) {
        foreach ($pad in $pads) {
            $b = [Joystick]::Buttons($pad.Slot)
            if ($b -gt 0 -and $b -ne $last[$pad.Slot]) {
                $nums = (0..31 | Where-Object { $b -band ([long]1 -shl $_) } | ForEach-Object { $_ + 1 }) -join ', '
                Write-Host ("{0} (vid {1}, pid {2}): button {3}" -f $pad.Name, $pad.VID, $pad.PID, $nums) -ForegroundColor Green
            }
            $last[$pad.Slot] = $b
        }
        Start-Sleep -Milliseconds 30
    }
}

# ---------------------------------------------------------------- SDK extraction

# Pulls the SDK files out of the Config Tool's .NET single-file bundle.
Add-Type -TypeDefinition @'
using System; using System.IO; using System.IO.Compression; using System.Text;
using System.Collections.Generic;
public static class DotnetBundle {
    static readonly byte[] Sig = {0x8b,0x12,0x02,0xb9,0x6a,0x61,0x20,0x38,0x72,0x7b,0x93,0x02,0x14,0xd7,0xa0,0x32,
                                  0x13,0xf5,0xb9,0xe6,0xef,0xae,0x33,0x18,0xee,0x3b,0x2d,0xce,0x24,0xb3,0x6a,0xae};
    static string ReadStr(BinaryReader r) {
        int n = 0, shift = 0; byte b;
        do { b = r.ReadByte(); n |= (b & 0x7f) << shift; shift += 7; } while ((b & 0x80) != 0);
        return Encoding.UTF8.GetString(r.ReadBytes(n));
    }
    static long FindSig(FileStream fs) {
        var buf = new byte[1 << 20]; long pos = 0; int read;
        while ((read = fs.Read(buf, 0, buf.Length)) > 0) {
            for (int i = 0; i + Sig.Length <= read; i++) {
                int j = 0; while (j < Sig.Length && buf[i + j] == Sig[j]) j++;
                if (j == Sig.Length) return pos + i;
            }
            pos += read - Sig.Length; fs.Position = pos;
        }
        throw new InvalidDataException("Not a .NET single-file bundle");
    }
    public static int Extract(string exe, string outDir, string[] wanted) {
        var want = new HashSet<string>(wanted, StringComparer.OrdinalIgnoreCase); int found = 0;
        using var fs = File.OpenRead(exe); using var r = new BinaryReader(fs);
        long sig = FindSig(fs); fs.Position = sig - 8; fs.Position = r.ReadInt64();
        uint major = r.ReadUInt32(); r.ReadUInt32(); int count = r.ReadInt32(); ReadStr(r);
        if (major >= 2) fs.Position += 8 * 4 + 8;
        Directory.CreateDirectory(outDir);
        for (int k = 0; k < count; k++) {
            long off = r.ReadInt64(), size = r.ReadInt64(), csize = major >= 6 ? r.ReadInt64() : 0;
            r.ReadByte(); string path = ReadStr(r);
            if (!want.Contains(path)) continue;
            long back = fs.Position; fs.Position = off;
            byte[] data = r.ReadBytes((int)(csize != 0 ? csize : size));
            if (csize != 0) {
                using var ds = new DeflateStream(new MemoryStream(data), CompressionMode.Decompress);
                using var ms = new MemoryStream(); ds.CopyTo(ms); data = ms.ToArray();
            }
            File.WriteAllBytes(Path.Combine(outDir, path), data); found++;
            fs.Position = back;
        }
        return found;
    }
}
'@

$exeStamp = (Get-Item $ConfigToolExe -ErrorAction SilentlyContinue)?.LastWriteTimeUtc.Ticks
$stampFile = Join-Path $SdkDir '.source-stamp'
$stale = $ReExtractSdk -or ($SdkFiles | Where-Object { -not (Test-Path (Join-Path $SdkDir $_)) }) -or
         ($exeStamp -and (Get-Content $stampFile -ErrorAction SilentlyContinue) -ne "$exeStamp")
if ($stale) {
    if (-not $exeStamp) { throw "DirectForce Config Tool not found at '$ConfigToolExe' (set configToolExe in config.json)." }
    Write-Log "Extracting VRS SDK from $ConfigToolExe ..."
    $n = [DotnetBundle]::Extract($ConfigToolExe, $SdkDir, $SdkFiles)
    if ($n -lt $SdkFiles.Count) { throw "Only found $n of $($SdkFiles.Count) SDK files in the Config Tool bundle." }
    Set-Content $stampFile "$exeStamp"
}

# ---------------------------------------------------------------- SDK session

$env:PATH = "$SdkDir;$env:PATH"
Add-Type -Path (Join-Path $SdkDir 'SmartyCo.DirectForce.Wrapper.dll')
if ($PSCmdlet.ParameterSetName -eq 'Listen') {
    # Only one background listener at a time (autostart + manual start).
    $mutex = [System.Threading.Mutex]::new($false, 'Local\VrsProfileSwitcher')
    if (-not $mutex.WaitOne(0)) { Write-Host 'Already running.'; return }
}
# At logon the USB devices may not be ready yet, so keep retrying when running in the background.
while (-not [DirectForceSdk]::Initialize()) {
    if ($PSCmdlet.ParameterSetName -ne 'Listen') { throw 'VRS SDK failed to initialize.' }
    Write-Log 'VRS SDK failed to initialize, retrying in 10 s...' Yellow
    Start-Sleep 10
}
Start-Sleep -Milliseconds 800   # let device enumeration settle

function Get-VrsDevices {
    $count = [DirectForceSdk]::GetDevicesList().Count
    for ($i = 0; $i -lt $count; $i++) {
        [pscustomobject]@{ Index = [uint32]$i; Name = [DirectForceSdk]::GetDeviceName($i) }
    }
}

function Resolve-VrsDevice([string]$match) {
    $dev = Get-VrsDevices | Where-Object Name -like "*$match*" | Select-Object -First 1
    if (-not $dev) { throw "No connected VRS device matching '$match'." }
    $dev
}

function Get-VrsProfiles([uint32]$dev) {
    $st = [DirectForceSdk]::LoadSettingsSync($dev)
    if ("$($st.code)" -ne 'kSuccess') { throw "LoadSettings failed: $($st.msg)" }
    $n = [DirectForceSdk]::GetProfilesNumber($dev)
    [pscustomobject]@{
        Current  = [DirectForceSdk]::GetCurrentProfile($dev)
        Profiles = @(for ($p = 0; $p -lt $n; $p++) { [DirectForceSdk]::GetProfileName($dev, $p) })
    }
}

function Set-VrsProfile([string]$deviceMatch, $target) {
    # $target: 'next' | 'previous' | profile name | profile index
    $dev = Resolve-VrsDevice $deviceMatch
    $state = Get-VrsProfiles $dev.Index
    $count = $state.Profiles.Count
    if ($count -eq 0) { throw "$($dev.Name) reports no profiles." }

    $idx = switch -Regex ("$target") {
        '^next$'     { $i = $state.Current + 1; if ($i -ge $count) { $Wrap ? 0 : $count - 1 } else { $i } }
        '^previous$' { $i = $state.Current - 1; if ($i -lt 0) { $Wrap ? $count - 1 : 0 } else { $i } }
        '^\d+$'      { [int]$target }
        default {
            $i = [array]::FindIndex([string[]]$state.Profiles, [Predicate[string]] { $args[0] -eq $target })
            if ($i -lt 0) { $i = [array]::FindIndex([string[]]$state.Profiles, [Predicate[string]] { $args[0] -like "*$target*" }) }
            $i
        }
    }
    if ($idx -lt 0 -or $idx -ge $count) { throw "Profile '$target' not found on $($dev.Name). Available: $($state.Profiles -join ', ')" }

    $name = $state.Profiles[$idx]
    if ($idx -ne $state.Current) {
        # The Config Tool retries SetCurrentProfile once after a short delay; do the same.
        $ok = [DirectForceSdk]::SetCurrentProfile($dev.Index, [uint32]$idx)
        if (-not $ok) { Start-Sleep -Milliseconds 200; $ok = [DirectForceSdk]::SetCurrentProfile($dev.Index, [uint32]$idx) }
        if (-not $ok) { throw "SetCurrentProfile($idx) was rejected by $($dev.Name)." }
        $st = [DirectForceSdk]::UpdateSettingsSync($dev.Index)
        if ("$($st.code)" -ne 'kSuccess') { throw "UpdateSettings failed: $($st.msg)" }
    }
    Write-Log ("{0}: [{1}] {2}" -f $dev.Name, $idx, $name) Green
    $name
}

$voice = $null
function Announce([string]$text) {
    if (-not $Speak) { return }
    if (-not $script:voice) { $script:voice = New-Object -ComObject SAPI.SpVoice }
    [void]$script:voice.Speak($text, 1)   # 1 = async
}

# ---------------------------------------------------------------- one-shot modes

switch ($PSCmdlet.ParameterSetName) {
    'List' {
        foreach ($d in Get-VrsDevices) {
            $s = Get-VrsProfiles $d.Index
            Write-Host "$($d.Name)" -ForegroundColor Cyan
            for ($p = 0; $p -lt $s.Profiles.Count; $p++) {
                $mark = if ($p -eq $s.Current) { '*' } else { ' ' }
                Write-Host ("  {0} {1,2}: {2}" -f $mark, $p, $s.Profiles[$p])
            }
        }
        return
    }
    'Select'   { [void](Set-VrsProfile $DefaultDevice $Select); return }
    'Next'     { [void](Set-VrsProfile $DefaultDevice 'next'); return }
    'Previous' { [void](Set-VrsProfile $DefaultDevice 'previous'); return }
}

# ---------------------------------------------------------------- controller button listener

$ctl = $cfg.controller ?? [pscustomobject]@{ name = 'PXN-CB1'; vid = '36E6'; pid = '8001' }
$vid = [Convert]::ToUInt16($ctl.vid, 16); $ctlPid = [Convert]::ToUInt16($ctl.pid, 16)
$bindings = @($cfg.buttons | ForEach-Object {
    [pscustomobject]@{
        Mask   = [long]1 -shl ([int]$_.button - 1)
        Button = [int]$_.button
        Device = $_.device ?? $DefaultDevice
        Target = $_.action -eq 'select' ? "$($_.profile)" : $_.action
    }
})
if (-not $bindings.Count) { throw "No controller buttons configured - check '$Config'." }
foreach ($b in $bindings) { Write-Log ("{0} button {1} -> {2} ({3})" -f $ctl.name, $b.Button, $b.Target, $b.Device) }

$joy = -1; $prev = 0L
Write-Log 'Listening for controller buttons.' Cyan
while ($true) {
    if ($joy -lt 0) {
        $joy = [Joystick]::Find($vid, $ctlPid)
        if ($joy -lt 0) { Start-Sleep 3; continue }
        Write-Log "$($ctl.name) found (joystick $joy)."
        $prev = [Joystick]::Buttons($joy)   # don't fire for buttons already held
    }
    $now = [Joystick]::Buttons($joy)
    if ($now -lt 0) { Write-Log "$($ctl.name) disconnected, waiting for it..." Yellow; $joy = -1; continue }
    $pressed = $now -band -bnot $prev   # rising edges only
    $prev = $now
    foreach ($b in $bindings) {
        if ($pressed -band $b.Mask) {
            try { Announce (Set-VrsProfile $b.Device $b.Target) }
            catch { Write-Log "Button $($b.Button): $($_.Exception.Message)" Red; Announce 'Profile switch failed' }
        }
    }
    Start-Sleep -Milliseconds 20
}
