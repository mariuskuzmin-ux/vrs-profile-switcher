# VRS DirectForce Profile Switcher

Switch profiles on a **VRS DirectForce Pro** wheelbase (or pedals) with a button on any game
controller or button box — mid-session, without alt-tabbing. Runs hidden in the background,
starts with Windows, and announces the new profile name out loud.

Works with both the **DirectForce Config Tool** and **VRS ONE** (profiles are stored on the
wheelbase itself, so it doesn't matter which app you use).

## Requirements
- Windows 10/11
- VRS DirectForce Pro wheelbase (pedals optional)
- [DirectForce Config Tool](https://virtualracingschool.com/hardware/) installed (the script uses the VRS
  driver library inside it — it does not need to be running)
- PowerShell 7: `winget install Microsoft.PowerShell`

## Setup
1. Download this repo (green **Code** button → **Download ZIP**) and extract it somewhere permanent,
   e.g. `Documents\VrsProfileSwitcher`.
2. Run `Find-Controller-Buttons.cmd`, press the button you want to use, and note the controller's
   **VID**, **PID** and the **button number**.
3. Edit `config.json`:
   ```json
   {
     "defaultDevice": "Wheel Base",
     "speak": true,
     "wrapAround": true,
     "controller": { "name": "PXN-CB1", "vid": "36E6", "pid": "8001" },
     "buttons": [
       { "button": 1, "action": "next" }
     ]
   }
   ```
4. Run `Install-Autostart.cmd`. Done — press the button and you'll hear the new profile name.

To remove it, run `Uninstall-Autostart.cmd`.

## More options
Each entry in `buttons` can be:

| Entry | Effect |
|---|---|
| `{ "button": 1, "action": "next" }` | next profile (loops around if `wrapAround` is true) |
| `{ "button": 2, "action": "previous" }` | previous profile |
| `{ "button": 3, "action": "select", "profile": "iRacing" }` | jump to a profile by name (partial match OK) or index |
| add `"device": "Pedals"` | target the pedals instead of the wheelbase |

Other settings: `"speak": false` disables the voice. `"configToolExe"` overrides the Config Tool path
(default `%LOCALAPPDATA%\DirectForce\DirectForce Config tool.exe`).
After editing `config.json`, run `Uninstall-Autostart.cmd` then `Install-Autostart.cmd` to restart it.

Command line (PowerShell 7):
```
.\VrsProfileSwitcher.ps1 -List                       # devices and profiles (* = active)
.\VrsProfileSwitcher.ps1 -Select AC                  # switch wheelbase profile
.\VrsProfileSwitcher.ps1 -Select GT3 -Device Pedals
.\VrsProfileSwitcher.ps1 -Next / -Previous
.\VrsProfileSwitcher.ps1 -ListControllers            # controller VID/PID + live button numbers
```
`Start-VrsProfileSwitcher.cmd` runs the listener in a visible window, which is handy for troubleshooting.
The background instance logs to `VrsProfileSwitcher.log`.

## How it works
On first run the script extracts VRS's own SDK (`SmartyCo.DirectForce.Wrapper.dll` +
`direct_force_sdk_csharp.dll`) from your installed Config Tool into `sdk\` and re-extracts it whenever
the Config Tool updates. No VRS files are included in this repo. It then makes the same calls the
Config Tool makes when you pick a profile: `LoadSettingsSync` → `SetCurrentProfile` → `UpdateSettingsSync`.
Controller buttons are read via the WinMM joystick API, so it works while the game has focus.

These calls were found by reverse engineering the Config Tool with
[REA](https://github.com/morluto/rea) (.NET metadata and call-graph analysis).

## Notes
- VRS ONE / the Config Tool won't refresh their window to show the new profile until you reselect it
  or restart them. Avoid editing a profile in those apps right after switching with the button.
- If a game runs as administrator, the background instance may need to as well to read the controller.

## Disclaimer
Unofficial community tool, not affiliated with or endorsed by VRS (Virtual Racing School).
Use at your own risk.
