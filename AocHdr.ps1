<#
.SYNOPSIS
  Toggle Windows HDR on the AOC Q27G41XMN and keep its OSD "Picture > HDR" in step.

  on     : Windows HDR ON for the AOC target only, then OSD Picture>HDR = DisplayHDR
  off    : OSD Picture>HDR = Off first, then Windows HDR OFF for the AOC target only
  toggle : on/off depending on the AOC's current Windows HDR state
  sync   : read Windows HDR state and set the OSD to match (no Windows change)
  status : print both states

  Monitor side uses AOC's extended DDC/CI feature 0xF8 / sub-id 0x52 (found empirically on this unit:
  0=Off 1=DisplayHDR 2=HDR Picture 3=HDR Movie 4=HDR Game), sent as raw DDC frames through AMD ADL
  (atiadlxx.dll) because dxva2 cannot build 6-byte extended frames. Requires 64-bit PowerShell.
#>
param(
  [Parameter(Position=0)][ValidateSet('on','off','toggle','sync','status')][string]$Action = 'toggle',
  [string]$MonitorMatch = 'Q27G41*',
  [ValidateRange(1,4)][int]$OsdHdrValue = 1   # value written when HDR is on: 1 = DisplayHDR
)
$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitProcess) { throw 'Run from 64-bit PowerShell (atiadlxx.dll is 64-bit).' }

$VCP_EXT = 0xF8; $VCP_EXT_TAG = 0xE1; $SUB_PICTURE_HDR = 0x52

# ---------------------------------------------------------------- Windows HDR (DisplayConfig)
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class DispCfg {
  [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint Low; public int High; }
  [StructLayout(LayoutKind.Sequential)] public struct PATH_SOURCE_INFO { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags; }
  [StructLayout(LayoutKind.Sequential)] public struct PATH_TARGET_INFO { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint outputTechnology; public uint rotation; public uint scaling; public uint rrNum; public uint rrDen; public uint scanLineOrdering; public int targetAvailable; public uint statusFlags; }
  [StructLayout(LayoutKind.Sequential)] public struct PATH_INFO { public PATH_SOURCE_INFO sourceInfo; public PATH_TARGET_INFO targetInfo; public uint flags; }
  [StructLayout(LayoutKind.Sequential)] public struct MODE_INFO { public uint infoType; public uint id; public LUID adapterId; public ulong a; public ulong b; public ulong c; public ulong d; public ulong e; public ulong f; }
  [StructLayout(LayoutKind.Sequential)] public struct SET_ADV_COLOR { public uint type; public uint size; public LUID adapterId; public uint id; public uint value; }
  [StructLayout(LayoutKind.Sequential)] public struct GET_ADV_COLOR { public uint type; public uint size; public LUID adapterId; public uint id; public uint value; public uint colorEncoding; public uint bitsPerColorChannel; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct TARGET_NAME {
    public uint type; public uint size; public LUID adapterId; public uint id; public uint flags; public uint outputTechnology; public ushort edidManufactureId; public ushort edidProductCodeId; public uint connectorInstance;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=64)] public string monitorFriendlyDeviceName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string monitorDevicePath; }
  [DllImport("user32.dll")] public static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPaths, out uint numModes);
  [DllImport("user32.dll")] public static extern int QueryDisplayConfig(uint flags, ref uint numPaths, [Out] PATH_INFO[] paths, ref uint numModes, [Out] MODE_INFO[] modes, IntPtr cur);
  [DllImport("user32.dll")] public static extern int DisplayConfigGetDeviceInfo(ref TARGET_NAME p);
  [DllImport("user32.dll")] public static extern int DisplayConfigGetDeviceInfo(ref GET_ADV_COLOR p);
  [DllImport("user32.dll")] public static extern int DisplayConfigSetDeviceInfo(ref SET_ADV_COLOR p);
}
"@
function Get-HdrTarget {
  $np=0;$nm=0
  if ([DispCfg]::GetDisplayConfigBufferSizes(2,[ref]$np,[ref]$nm) -ne 0) { throw 'GetDisplayConfigBufferSizes failed' }
  $paths = New-Object 'DispCfg+PATH_INFO[]' $np; $modes = New-Object 'DispCfg+MODE_INFO[]' $nm
  if ([DispCfg]::QueryDisplayConfig(2,[ref]$np,$paths,[ref]$nm,$modes,[IntPtr]::Zero) -ne 0) { throw 'QueryDisplayConfig failed' }
  for ($i=0; $i -lt $np; $i++) {
    $t = $paths[$i].targetInfo
    $n = New-Object 'DispCfg+TARGET_NAME'
    $n.type = 2; $n.size = [Runtime.InteropServices.Marshal]::SizeOf([type][DispCfg+TARGET_NAME]); $n.adapterId = $t.adapterId; $n.id = $t.id
    if ([DispCfg]::DisplayConfigGetDeviceInfo([ref]$n) -ne 0) { continue }
    if ($n.monitorFriendlyDeviceName -notlike $MonitorMatch) { continue }
    $c = New-Object 'DispCfg+GET_ADV_COLOR'
    $c.type = 9; $c.size = [Runtime.InteropServices.Marshal]::SizeOf([type][DispCfg+GET_ADV_COLOR]); $c.adapterId = $t.adapterId; $c.id = $t.id
    if ([DispCfg]::DisplayConfigGetDeviceInfo([ref]$c) -ne 0) { throw 'advanced color query failed' }
    return [pscustomobject]@{ Name=$n.monitorFriendlyDeviceName; AdapterId=$t.adapterId; TargetId=$t.id; Supported=[bool]($c.value -band 1); Enabled=[bool]($c.value -band 2) }
  }
  throw "No active display matching '$MonitorMatch' in DisplayConfig"
}
function Set-WindowsHdr($target, [bool]$on) {
  if (-not $target.Supported) { throw "$($target.Name) does not report HDR support" }
  $p = New-Object 'DispCfg+SET_ADV_COLOR'
  $p.type = 10; $p.size = [Runtime.InteropServices.Marshal]::SizeOf([type][DispCfg+SET_ADV_COLOR]); $p.adapterId = $target.AdapterId; $p.id = $target.TargetId
  $p.value = [uint32]([int]$on)
  $rc = [DispCfg]::DisplayConfigSetDeviceInfo([ref]$p)
  if ($rc -ne 0) { throw "DisplayConfigSetDeviceInfo failed: $rc" }
}

# ---------------------------------------------------------------- Monitor OSD (raw DDC/CI via AMD ADL)
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Adl {
  public delegate IntPtr MallocCb(int size);
  [DllImport("atiadlxx.dll")] public static extern int ADL2_Main_Control_Create(MallocCb cb, int enumConnected, out IntPtr ctx);
  [DllImport("atiadlxx.dll")] public static extern int ADL2_Main_Control_Destroy(IntPtr ctx);
  [DllImport("atiadlxx.dll")] public static extern int ADL2_Adapter_NumberOfAdapters_Get(IntPtr ctx, out int n);
  [DllImport("atiadlxx.dll")] public static extern int ADL2_Adapter_AdapterInfo_Get(IntPtr ctx, IntPtr buf, int size);
  [DllImport("atiadlxx.dll")] public static extern int ADL2_Display_DisplayInfo_Get(IntPtr ctx, int adapter, out int n, out IntPtr infos, int force);
  [DllImport("atiadlxx.dll")] public static extern int ADL2_Display_DDCBlockAccess_Get(IntPtr ctx, int adapter, int display, int option, int cmdIndex, int sendLen, byte[] send, ref int recvLen, byte[] recv);
  public static IntPtr Alloc(int size) { return Marshal.AllocHGlobal(size); }
}
"@
$script:AdlCb = [Adl+MallocCb]{ param($s) [Adl]::Alloc($s) }
function Open-Adl { $ctx=[IntPtr]::Zero; $rc=[Adl]::ADL2_Main_Control_Create($script:AdlCb,1,[ref]$ctx); if ($rc -ne 0) { throw "ADL init failed rc=$rc (AMD driver present?)" }; $ctx }
function Get-AdlDisplay($ctx) {
  $n=0; [void][Adl]::ADL2_Adapter_NumberOfAdapters_Get($ctx,[ref]$n)
  $sz=1572; $buf=[Runtime.InteropServices.Marshal]::AllocHGlobal($sz*$n)
  try {
    [void][Adl]::ADL2_Adapter_AdapterInfo_Get($ctx,$buf,$sz*$n)
    for ($i=0; $i -lt $n; $i++) {
      $base=[int64]$buf+$i*$sz
      $idx=[Runtime.InteropServices.Marshal]::ReadInt32([IntPtr]$base,4)
      if (-not [Runtime.InteropServices.Marshal]::ReadInt32([IntPtr]$base,4+4+256+16+256+256)) { continue }
      $dn=0;$dp=[IntPtr]::Zero
      if ([Adl]::ADL2_Display_DisplayInfo_Get($ctx,$idx,[ref]$dn,[ref]$dp,0) -ne 0) { continue }
      for ($d=0; $d -lt $dn; $d++) {
        $b=[int64]$dp+$d*552
        $logical=[Runtime.InteropServices.Marshal]::ReadInt32([IntPtr]$b,0)
        $logAd=[Runtime.InteropServices.Marshal]::ReadInt32([IntPtr]$b,8)
        $dname=[Runtime.InteropServices.Marshal]::PtrToStringAnsi([IntPtr]($b+20))
        $val=[Runtime.InteropServices.Marshal]::ReadInt32([IntPtr]$b,20+512+16)
        if ($logAd -eq $idx -and ($val -band 1) -and $dname -like $MonitorMatch) { return [pscustomobject]@{Adapter=$idx;Display=$logical;Name=$dname} }
      }
    }
  } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($buf) }
  throw "No connected ADL display matching '$MonitorMatch'"
}
function Send-Ddc($ctx,$disp,[byte[]]$payload,[int]$recvLen) {
  $x=0x6E; foreach ($b in $payload) { $x=$x -bxor $b }
  $msg=[byte[]](@(0x6E)+$payload+@([byte]$x))
  $recv=New-Object byte[] 32; $rl=$recvLen
  $rc=[Adl]::ADL2_Display_DDCBlockAccess_Get($ctx,$disp.Adapter,$disp.Display,0,0,$msg.Length,$msg,[ref]$rl,$recv)
  if ($rc -ne 0) { throw "DDC send failed rc=$rc" }
  $recv
}
function Get-OsdExt($ctx,$disp,[int]$sub) {
  $r = Send-Ddc $ctx $disp ([byte[]](0x51,0x84,0x01,$VCP_EXT,$VCP_EXT_TAG,$sub)) 11
  if ($r[1] -ne 0x88 -or $r[2] -ne 0x02 -or $r[3] -ne 0x00 -or $r[4] -ne $VCP_EXT -or $r[5] -ne $sub) {
    throw ('Unexpected DDC reply: ' + (($r[0..10] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '))
  }
  [pscustomobject]@{ Max=(($r[6] -shl 8)+$r[7]); Cur=(($r[8] -shl 8)+$r[9]) }
}
function Set-OsdExt($ctx,$disp,[int]$sub,[int]$value) {
  [void](Send-Ddc $ctx $disp ([byte[]](0x51,0x86,0x03,$VCP_EXT,$VCP_EXT_TAG,$sub,(($value -shr 8) -band 0xFF),($value -band 0xFF))) 0)
}
function Set-OsdPictureHdr($ctx,$disp,[int]$value) {
  # The panel re-syncs after a Windows HDR flip and DDC can be deaf for a few seconds: retry until readback matches.
  $deadline=(Get-Date).AddSeconds(12); $last=$null
  do {
    try {
      Set-OsdExt $ctx $disp $SUB_PICTURE_HDR $value
      Start-Sleep -Milliseconds 600
      $last=(Get-OsdExt $ctx $disp $SUB_PICTURE_HDR).Cur
      if ($last -eq $value) { return }
    } catch { $last="err: $($_.Exception.Message)" }
    Start-Sleep -Milliseconds 700
  } while ((Get-Date) -lt $deadline)
  throw "OSD Picture>HDR did not take value $value (last readback: $last)"
}
function Wait-Ddc($ctx,$disp) {
  $deadline=(Get-Date).AddSeconds(12)
  do { try { [void](Get-OsdExt $ctx $disp $SUB_PICTURE_HDR); return } catch { Start-Sleep -Milliseconds 500 } } while ((Get-Date) -lt $deadline)
  throw 'Monitor DDC/CI not responding'
}

# ---------------------------------------------------------------- Actions
$osdNames = @('Off','DisplayHDR','HDR Picture','HDR Movie','HDR Game')
$target = Get-HdrTarget
$ctx = Open-Adl
try {
  $disp = Get-AdlDisplay $ctx
  $winState = if ($target.Enabled) { 'ON' } else { 'OFF' }
  switch ($Action) {
    'status' {
      $cur = (Get-OsdExt $ctx $disp $SUB_PICTURE_HDR).Cur
      "Windows HDR ($($target.Name)): $winState"
      "OSD Picture>HDR ($($disp.Name)): $cur ($($osdNames[$cur]))"
    }
    'on' {
      if (-not $target.Enabled) { Set-WindowsHdr $target $true; Start-Sleep -Seconds 2; Wait-Ddc $ctx $disp }
      Set-OsdPictureHdr $ctx $disp $OsdHdrValue
      "HDR ON: Windows HDR on, OSD Picture>HDR = $($osdNames[$OsdHdrValue])"
    }
    'off' {
      Set-OsdPictureHdr $ctx $disp 0
      if ($target.Enabled) { Set-WindowsHdr $target $false }
      'HDR OFF: OSD Picture>HDR = Off, Windows HDR off'
    }
    'sync' {
      $want = if ($target.Enabled) { $OsdHdrValue } else { 0 }
      Wait-Ddc $ctx $disp
      Set-OsdPictureHdr $ctx $disp $want
      "SYNC: Windows HDR $winState -> OSD Picture>HDR = $($osdNames[$want])"
    }
    'toggle' {
      $next = if ($target.Enabled) { 'off' } else { 'on' }
      & $PSCommandPath $next -MonitorMatch $MonitorMatch -OsdHdrValue $OsdHdrValue
    }
  }
} finally { [void][Adl]::ADL2_Main_Control_Destroy($ctx) }
