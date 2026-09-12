# Changelog

All notable changes to NetSource Policy are documented here.

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