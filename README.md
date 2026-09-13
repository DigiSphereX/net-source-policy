# NetSource Policy

![License: MIT](https://img.shields.io/badge/license-MIT-green)
![OS: Windows 10/11](https://img.shields.io/badge/Windows-10%2F11-blue)
![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1+-informational)
![Portable](https://img.shields.io/badge/portable-yes-lightgrey)
[![Donate](https://img.shields.io/badge/Donate-PayPal-0070BA)](https://www.paypal.com/donate/?hosted_button_id=CFANQH892RPH2)

A portable, open-source Windows tool that lets you decide **which connection supplies the
Internet** and set the **priority rules** that keep your home LAN on the right adapter.
Interactive GUI, instant reaction, no installer, no scheduled tasks, no services.

## What it does

- **Internet source rules** - add one or more rules. When the connected network name
  (SSID) starts with a rule's prefix, the Internet is routed through that interface first
  (first matching rule wins). A default rule is created with the placeholder prefix
  `My Hotspot*` on `Wi-Fi` - edit it to your own hotspot/network.
- **Home LAN rule** - traffic for your local subnet (default `192.168.0.0/24`, servers,
  router, NAS) is always sent through the Ethernet cable, regardless of the Internet source.
- **Reliability** - if a hotspot is connected but has no Internet (mobile data off), the
  tool automatically moves the Internet to the cable and switches back when the hotspot
  returns.
- **Interactive GUI** - live dashboard (adapters, effective source, persistent routes),
  add/remove/edit rules, priority metrics for every rule, one-click install/uninstall and
  a full log.
- **Instant & silent** - rules are applied in seconds through permanent WMI event
  consumers. Nothing appears in Task Scheduler, no background services.

## How it works

The engine computes a routing decision and applies it with a mix of interface metrics and
persistent routes:

- Route priority arithmetic: *interface metric + route metric*, lower wins.
- The phone gateway usually advertises a high route metric (~50), so while the hotspot rule
  is active the engine adds a persistent default route with metric 1 (total ~2), beating the
  Ethernet default (~8). When the rule is not active, that route is removed and Wi-Fi keeps
  a high metric (50).
- Two WMI consumers drive it (`#PRAGMA AUTORECOVER`, so they survive reboots):
  - `NPS_EventFilter` - reacts immediately to adapter state changes (SSID switch, cable...).
  - `NPS_PollFilter` - silently re-checks Internet availability so turning phone data
    off/on is caught (the adapter itself does not change in that case).

## Internet safety guarantee

The engine is built so that it can **never leave you without Internet**:

- **Proven pinning** - the Internet is routed through the hotspot only when its profile
  says *Internet* AND its gateway actually answers a connection test. A half-dead tether
  (signal up, mobile data silent) is never used.
- **Never touches the working default** - the Ethernet/cable default route is left intact;
  adding or removing the hotspot route only changes *which* route wins, so the fallback is
  always there.
- **Self-healing** - every check verifies real Internet reachability. If a pinned route
  ever goes dead, it is removed immediately and Windows automatic routing takes over.
- **Post-change verification** - after any routing change the engine probes the Internet;
  on failure it rolls everything back within about a second and logs `POST-CHECK`.
- **Logbook** - every decision, block and recovery is written to `data\logs\netpolicy.log`.

## Layout

```
NetSourcePolicy\
  NetSourcePolicy.exe  <-- double-click this (zero console, app icon)
  run.vbs            hidden launcher for the .ps1 (fallback)
  LICENSE            MIT
  README.md
  src\
    NetSourcePolicy.ps1   GUI
    engine.ps1            engine (Apply / Install / Uninstall / Status)
  config\
    config.sample.json    example rules (copy to config.json, or let the first run create it)
    config.json           your real rules (auto-created on first run; never published)
  templates\
    NetSourcePolicy.mof.template   WMI subscription template
  data\
    state.txt             last applied decision (auto)
    logs\netpolicy.log    change history
  build\                  sources to rebuild the EXE (NetSourcePolicy.cs, build.ps1),
                          NetSourcePolicy-preview.png = your icon artwork,
                          NetSourcePolicy.ico = generated multi-size icon
  .generated\             generated MOF (auto)
```

## Requirements

- Windows 10 / 11 (x64).
- Windows PowerShell 5.1 (built-in).
- Administrator is asked (UAC) only when applying/removing rules.

## Usage

1. Copy the whole `NetSourcePolicy` folder anywhere - USB stick included (portable).
2. Double-click **`NetSourcePolicy.exe`** (zero console windows, your app icon). Closing the
   window stops the interface; the routing rules stay installed.
3. **Rules & Priority** tab: add / edit / remove Internet-source rules (each with its own
   interface and priority metrics), set the LAN subnet, fallback and polling.
4. Click **Apply & Install** (one UAC prompt).
5. Dashboard shows the live state. **Uninstall** restores Windows defaults.

**Backup / move settings to another PC:** use **Export settings...** (saves `netpolicy-settings.json`)
and **Import settings...** - the import accepts both current and legacy (v1) files, validates them,
and you press *Apply & Install* to put the imported rules in force.

> Moving the folder later? Run **Apply & Install** again - it rewrites the WMI paths.

## Rebuilding the EXE

The launcher is a small C# Windows app (`build\NetSourcePolicy.cs`) compiled against the
installed .NET Framework. The application icon comes from your artwork
`build\NetSourcePolicy-preview.png`, converted to a multi-size `.ico`:

```
powershell -NoProfile -ExecutionPolicy Bypass -File build\build.ps1
```

Put any PNG in `build\NetSourcePolicy-preview.png`, run the script, and the EXE is rebuilt
with that icon - no console window, ready to copy anywhere.

## Engine commands (advanced)

```
powershell -NoProfile -ExecutionPolicy Bypass -File src\engine.ps1 -Action Apply
powershell -NoProfile -ExecutionPolicy Bypass -File src\engine.ps1 -Action Status
```

## Support this project ☕

Free and open source (MIT). If this tool saved you time or saved your network, a small
thank-you means a lot and keeps it maintained:

- **GitHub Sponsors** -> <https://github.com/sponsors/DigiSphereX>
- **PayPal** -> <https://www.paypal.com/donate/?hosted_button_id=CFANQH892RPH2>

## Disclaimer / Backup advice

NetSource Policy changes routing tables, interface metrics, persistent routes and WMI
event subscriptions, and **requires administrator rights**. Use it at your own risk:

- **Back up before applying.** Keep a copy of this folder (especially
  `config\config.json`, `templates\`, `data\logs\`) and note your current `route print -4`
  output and interface metrics, so you can restore them manually if needed.
- While routes are being changed, Internet traffic can be interrupted - even on unmodified
  machines a momentary drop can occur, and on rare, machine-specific setups behaviour may
  not be fully predictable.
- The tool ships with **Uninstall / Restore defaults** (GUI button and menu) which removes
  the WMI consumers, persistent routes and priority metrics and restores Windows defaults.

The author is not responsible for any unintentional damage or data loss caused by using
this tool.

## License

MIT - see `LICENSE`. (c) 2026 M. Basheer (DigiSphereX).