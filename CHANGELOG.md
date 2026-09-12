# Changelog

All notable changes to NetSource Policy are documented here.

## [2.1.2] - 2026-09-12

### Fixed
- The engine could stay on Ethernet even while connected to the hotspot (the "still takes
  internet from the cable" issue). The live probe used PowerShell cmdlets (`Test-Connection
  -Source`, `Test-NetConnection -SourceAddress`) that do not exist in Windows PowerShell
  5.1; the probe silently stalled, so every automatic poll hung and no rule was ever applied.
  The probe is now built on a short-timeout `TcpClient` socket against a temporary targeted
  route through the chosen interface (2.5 s, auto-cleanup), which works from both the normal
  user and the SYSTEM account the WMI polls run under.
- The internet-source rule is now matched through `Get-NetConnectionProfile` (verified working
  in every context including SYSTEM), not `netsh wlan`, which requires location consent and
  elevation and returned nothing from the background poll.
- Launcher (`NetSourcePolicy.exe`) now starts the interface with `CreateNoWindow`, so no
  PowerShell/console window pops up on the taskbar; and the window itself now shows the
  application icon instead of the generic PowerShell icon.

## [2.1.1] - 2026-09-12

### Fixed
- Internet could be cut when the phone hotspot reported "Internet" while actually having
  no data. The engine now probes end-to-end **through the hotspot interface** (source-bound
  ping to 8.8.8.8) and keeps a failed gateway on a 3-minute cooldown, so it never re-pins a
  dead connection and never flaps between sources.
- Persistent **LAN route** could survive as a dead route after the cable disconnects
  (`Remove-NetRoute` fails with "InterfaceIndex 0" on gateway pins). Removal now falls back
  to the real `route -p delete` command and sweeps ghost entries; LAN re-pinning now runs on
  every poll instead of only on state changes.
- Interfaces that are present-but-not-ready (cable unplugged, metric `$null`) no longer make
  the sanity guard fail, which removes per-poll "CHANGED" noise when the cable is down.

## [2.1.0] - 2026-09-12

### Added
- **Export settings / Import settings** buttons in the Rules & Priority tab:
  portable JSON backup of all rules and options; accepts current and legacy (v1) files,
  validates them, and rejects malformed files instead of silently resetting.

### Fixed
- Rules grid could be covered by the fill-mode layout, hiding the Add/Remove buttons.
  The rules group now uses a stable Dock-based layout (grid visible, buttons always on screen).

## [2.0.0] - 2026-09-12

### Added
- Multi-rule engine: any number of Internet-source rules, first matching rule wins.
- Rules grid with add / edit / remove rows (On, SSID prefix, interface, prefer/other metrics).
- New config schema (`rules[]`) with automatic migration from v1 configs.
- Executable launcher (C# winexe) with an application icon - zero console windows.
- `build\build.ps1` converts your PNG artwork into a multi-size `.ico` and rebuilds the EXE.

### Fixed
- Persistent default-route ghost from v1 (blank interface) is now detected and replaced
  (`route -p delete` + `route -p add`) instead of failing with "already exists".
- State sanity guard: a live low-metric default route must exist before early-return.