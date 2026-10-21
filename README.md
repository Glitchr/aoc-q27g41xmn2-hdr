# AOC Q27G41XMN HDR sync

Switch Windows HDR and the **AOC Q27G41XMN** monitor's own HDR setting together, from a double-click or a hotkey.

The Q27G41XMN has an HDR mode in its on-screen menu (Picture > HDR) that Windows does not control. Turning HDR on or off in Windows leaves that setting where it was, so every switch also means a trip through the monitor's menu. This tool does both halves in one step: it flips Windows HDR for this monitor only and sets the OSD option over DDC/CI.

## Requirements

- **AOC Q27G41XMN.** The OSD register this tool writes is undocumented and was mapped on this model. Other AOC models may use a different register or none at all; see [Other monitors](#other-monitors).
- **AMD Radeon GPU** with the AMD driver installed, and the monitor connected to it. The DDC/CI half goes through AMD's ADL library (`atiadlxx.dll`), so NVIDIA and Intel GPUs are not supported.
- **DDC/CI turned on** in the monitor's OSD.
- **Windows 11, 64-bit**, with the built-in Windows PowerShell 5.1. Windows 10 may work but has not been tested. No modules or installs are needed.

## Install

Clone or download this repository to any folder. There is nothing to install; the scripts find each other relative to their own location.

```
git clone https://github.com/Glitchr/aoc-q27g41xmn-hdr.git
```

## Usage

Double-click one of the batch files:

| File | What it does |
|------|--------------|
| `hdr-on.bat` | Turns Windows HDR on for the AOC, then sets OSD Picture > HDR to **DisplayHDR** |
| `hdr-off.bat` | Sets OSD Picture > HDR to **Off**, then turns Windows HDR off for the AOC |
| `hdr-toggle.bat` | Runs `on` or `off`, depending on the AOC's current Windows HDR state |
| `hdr-sync.bat` | Leaves Windows alone and sets the OSD to match the current Windows HDR state |
| `hdr-status.bat` | Prints both states |

Other displays are never touched. If something fails, the window stays open with the error.

From a terminal, the same actions are available on `hdr.ps1`:

```powershell
powershell -ExecutionPolicy Bypass -File .\hdr.ps1 toggle
powershell -ExecutionPolicy Bypass -File .\hdr.ps1 on -OsdHdrValue 4
```

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `-Action` (positional) | `toggle` | `on`, `off`, `toggle`, `sync` or `status` |
| `-OsdHdrValue` | `1` | OSD mode used when HDR is on: `1` DisplayHDR, `2` HDR Picture, `3` HDR Movie, `4` HDR Game |
| `-MonitorMatch` | `Q27G41*` | Wildcard matched against the monitor name reported by Windows and by the AMD driver |

### Hotkey

Windows can bind a key combination to a desktop shortcut. This creates one for `hdr-toggle.bat` on **Ctrl+Alt+Shift+H** (run it from the repository folder):

```powershell
$s = (New-Object -ComObject WScript.Shell).CreateShortcut("$env:USERPROFILE\Desktop\HDR Toggle.lnk")
$s.TargetPath = "$PWD\hdr-toggle.bat"
$s.WorkingDirectory = "$PWD"
$s.Hotkey = 'CTRL+ALT+SHIFT+H'
$s.Save()
```

Shortcut hotkeys only work for shortcuts on the Desktop or in the Start menu. To change the key later, open the shortcut's Properties and edit **Shortcut key**.

### Win+Alt+B

The Windows shortcut **Win+Alt+B** (from Xbox Game Bar) toggles HDR without going through this tool, so the OSD is left behind. Run `hdr-sync.bat` afterwards to fix it, or use the [hotkey](#hotkey) above instead.

## How it works

**Windows side.** `DisplayConfigGetDeviceInfo` reads the advanced color state of the display whose friendly name matches `-MonitorMatch`, and `DisplayConfigSetDeviceInfo` (`DISPLAYCONFIG_DEVICE_INFO_SET_ADVANCED_COLOR_STATE`) switches HDR on that display alone.

**Monitor side.** Picture > HDR is not a standard MCCS VCP code. AOC exposes it as extended feature `F8`, tag `E1`, sub-id `0x52`, which the standard Windows monitor API (`dxva2` `GetVCPFeature`/`SetVCPFeature`) cannot address. The script builds the DDC/CI frames itself and sends them with `ADL2_Display_DDCBlockAccess_Get`.

After a Windows HDR switch the monitor re-syncs and ignores DDC/CI for a few seconds. The script retries the write and reads the value back until it sticks, for up to 12 seconds.

## Protocol notes

Picture > HDR values (sub-id `0x52`), confirmed by changing the OSD by hand and reading the register back:

| Value | OSD setting |
|-------|-------------|
| 0 | Off |
| 1 | DisplayHDR |
| 2 | HDR Picture |
| 3 | HDR Movie |
| 4 | HDR Game |

Frames as passed to ADL. For the frames the script sends, the checksum is the XOR of every preceding byte, including the leading `6E`:

```
get:    6E 51 84 01 F8 E1 52 chk
reply:  6E 88 02 00 F8 52 MH ML SH SL chk     (max = MH:ML, current = SH:SL)
set:    6E 51 86 03 F8 E1 52 00 vv chk
```

### Pitfalls

- The monitor's capabilities string advertises entries like `F8E112(...)F8E151(...)`: opcode `F8`, tag `E1`, then a one-byte sub-id. Tag `E2` reaches the same table.
- `dxva2` `GetVCPFeature` on `F8` or `E2` returns `0/0` and then NAKs.
- A plain `get F8` without a sub-id answers with whichever sub-id was queried last, so it can look like a working read of the wrong register.
- `ADL2_Display_DDCBlockAccess_Get` returns `-1` unless the send buffer starts with the `6E` address byte.
- The script reads ADL's `AdapterInfo` (1572 bytes) and `ADLDisplayInfo` (552 bytes, name at offset 20) by offset, following the layouts in the ADL SDK headers.

### Other sub-ids

These answered on the same unit (read only, never written by this tool): `0x12` (5 states, did not change with Picture > HDR), `0x51` (4 states), `0x57` and `0x58` (0 to 20), `0x11` (0 to 7). Their meanings are unconfirmed.

## Other monitors

This tool has been tested on one Q27G41XMN with a Radeon RX 6700 XT. Other AOC models may share the `F8`/`E1` scheme with a different sub-id. To check, look for `F8E1` entries in the monitor's capabilities string, then read candidate sub-ids while changing the OSD by hand. Writing to an unknown sub-id can change settings you did not intend to change, so map it with reads first.

The script only ever writes sub-id `0x52`, and only the values 0 to 4.

## License

[MIT](LICENSE). This project is not affiliated with or endorsed by AOC or AMD. Product names are trademarks of their respective owners.
