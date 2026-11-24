# OpenCode Go Limits

A Windows desktop widget that shows your OpenCode Go usage limits (5-hour, weekly, monthly) without opening a browser.

> Русская версия: [README.md](README.md)

## Features

- Three live progress bars: 5-hour, weekly and monthly limits with reset countdowns
- Frameless always-on-top window; drag to move, the position is remembered
- Resize by dragging the corner grip (about 75–160%); the size is remembered
- Auto-refresh every 5 minutes (F5 refreshes manually)
- Color coding: green below 60%, yellow 60–85%, red 85% and above
- Optional Windows toast notification when the 5-hour limit crosses a threshold (default 85%)
- Optional autostart with Windows (written only on first run or when toggled explicitly)
- Panel mode: docks to the chosen screen edge (top/bottom/left/right), hidden except for a 4px status-colored tab; slides out smoothly on hover; can be placed on any monitor (including a tablet)
- One UI (Samsung) dark theme toggle: rounded window, pill-shaped bars, One UI Blue accent; SamsungOne is auto-detected if installed
- No dependencies: a single exe, runs on Windows 10/11 with built-in PowerShell 5.1

## Requirements

- Windows 10 or 11
- An [OpenCode Go](https://opencode.ai/go) subscription
- `opencode` installed and logged in (`opencode auth login`), so that `%USERPROFILE%\.local\share\opencode\auth.json` contains an `opencode-go` API key

## Download and run

1. Download `OpenCode Limits.exe` from the [latest release](releases/latest)
2. Run it. If SmartScreen warns, choose "More info" → "Run anyway" (the exe is not code-signed)
3. The widget appears in the bottom-right corner of your screen

Close it with ✕, Esc or Alt+F4 — the app exits completely. Run the exe again to open it. If it is already running, launching it again brings the window to the front.

## How it works

`OpenCode Limits.exe` is a small launcher with the PowerShell script embedded. On start it extracts the script into a unique `%LOCALAPPDATA%\OpenCodeLimits\run-<id>` folder, verifies its SHA-256 against the embedded copy, and runs it hidden. The script reads the API key from `auth.json` and requests `https://opencode.ai/zen/go/v1/usage` asynchronously every 5 minutes, so the UI never freezes. The key is sent only to `opencode.ai`; settings are stored in `%APPDATA%\opencode-limits-widget`.

## Settings

Right-click the widget → **Settings...**: refresh interval, notifications, threshold, autostart, always-on-top, panel mode, panel edge, One UI style.

## Security notes

- The API key is read from your local `auth.json` and is never logged or stored by the widget
- The script is extracted into a per-run folder and hash-verified before launch
- Autostart is written only on first run or when you toggle it; removing the Run entry externally is respected

## Build from source

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1
```

Requires Windows PowerShell 5.1 and the .NET Framework compiler (`csc.exe`, ships with Windows). The result is a single `OpenCode Limits.exe`.

| File | Purpose |
| --- | --- |
| `launcher.cs` | C# launcher: extracts the embedded script, verifies its hash and runs it hidden |
| `limits-widget.ps1` | The widget itself (WinForms UI, API calls, settings) |
| `widget.ico` | Application icon |
| `build.ps1` | Builds the single-file exe with `csc.exe` |

## Legal notice

Not affiliated with Samsung Electronics. One UI is a trademark of Samsung Electronics. The theme is an original stylization inspired by publicly available design principles; no Samsung assets, fonts or code are included.

## License

[MIT](LICENSE)
