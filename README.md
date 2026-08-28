# OpenCodex Usage Tray

A small, native Windows companion for OpenCodex that keeps account usage and Codex task status within reach without turning into another dashboard window.

![OpenCodex Usage Tray hero](docs/hero.png)

> [!IMPORTANT]
> This is an unofficial community tool. It is not made, endorsed, or supported by OpenAI or the OpenCodex project.

## Highlights

- Shows all three configured OpenCodex accounts at once.
- Displays 5-hour and weekly quota usage, seven-day tokens, and seven-day requests.
- Surfaces running, stalled, and recent Codex tasks with their account and token count.
- Switches the active OpenCodex account with one click.
- Follows Codex's light, dark, or system appearance.
- Stays above Codex while Codex is focused, hides when you use another app, and returns without taking keyboard focus.
- Anchors beside Codex content and reserves the right side for Codex Browser.
- Opens the full OpenCodex dashboard from a compact header button.
- Runs as a notification-area app across every Codex task; it is not attached to one chat.

The tray reads local OpenCodex management endpoints and Codex's local task databases. It does not host a web page or run its own server.

## Screenshots

| Light theme | Dark theme |
| --- | --- |
| ![Light theme usage tray](docs/tray-light.png) | ![Dark theme usage tray](docs/tray-dark.png) |

Screenshots use demonstration account names and usage values; the installed tray reads your local OpenCodex data.

## Requirements

- Windows 10 or Windows 11.
- The OpenAI Codex desktop app.
- A working local OpenCodex installation with up to three authenticated Codex accounts.
- Node.js 22 or newer with the built-in `node:sqlite` module.
- Windows PowerShell 5.1 or PowerShell 7.

OpenCodex should be running before the tray starts. The tray reads the dashboard port from OpenCodex's local configuration and falls back to `http://127.0.0.1:10100/`.

## Install

1. On this GitHub page, select **Code > Download ZIP**, then extract the ZIP. Alternatively, clone the repository with Git.
2. Start OpenCodex and confirm its local dashboard loads.
3. Open PowerShell in the extracted `opencodex-usage-tray` folder.
4. Run:

   ```powershell
   powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File .\install.ps1
   ```

Administrator access is not required. The installer:

- validates Node.js and `node:sqlite`;
- installs the app in `%LOCALAPPDATA%\OpenCodexUsageTray`;
- creates an **OpenCodex Usage** Start menu shortcut;
- creates a per-user Windows Startup shortcut; and
- launches the tray and checks that it reached a ready state.

Use `-NoStart` to install without launching it immediately:

```powershell
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File .\install.ps1 -NoStart
```

`-NoStart` does not disable automatic startup at the next Windows sign-in.

## Use

The popup is intentionally tied to the Codex window rather than to a particular Codex task. Once enabled, it follows you across all chats.

| Control | Action |
| --- | --- |
| Account button | Makes that account active in OpenCodex |
| `↗` | Opens the full OpenCodex dashboard |
| `↻` | Refreshes quotas and task status immediately |
| `×` or `Esc` | Hides the popup while leaving the tray running |
| Tray icon, left-click | Shows or hides the popup |
| Tray icon, right-click | Opens show, refresh, dashboard, and exit commands |
| **OpenCodex Usage** in Start | Starts the tray or reveals the existing instance |

Account switching is not display-only: it changes the active account used by OpenCodex. The popup confirms the switch and then refreshes usage.

### Focus and positioning

When the popup has been enabled:

- focusing Codex shows it above the Codex window;
- focusing another application hides it;
- returning to Codex restores it without taking focus from the editor or chat;
- opening Codex Browser keeps a reserved area on the right so the popup does not cover the Browser panel; and
- moving or resizing Codex causes the popup to reposition within the active monitor's working area.

If you explicitly hide the popup with `×`, `Esc`, or the tray icon, it stays hidden until you show it again.

## Start with Windows

The installer adds `OpenCodex Usage Tray.lnk` to your per-user Startup folder. Exiting from the tray menu stops it for the current session, but it starts again after the next Windows sign-in.

To disable automatic startup without uninstalling:

1. Press `Win+R`.
2. Enter `shell:startup`.
3. Remove **OpenCodex Usage Tray**.

Run `install.ps1` again to recreate the shortcut.

## Update

Download or pull the newer source and rerun `install.ps1`. The installer asks the running instance to stop, validates the existing install directory, replaces only known application files, recreates the shortcuts, and starts the updated version.

## Uninstall

From an extracted or cloned copy of the repository, run:

```powershell
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File .\uninstall.ps1
```

The uninstaller stops the tray and removes its installed files, Startup shortcut, and Start menu shortcut. It does not remove OpenCodex, Codex, accounts, task history, or usage data.

## Troubleshooting

### The installer says Node.js is missing or too old

Check both the version and SQLite support:

```powershell
node --version
node -e "require('node:sqlite'); console.log('node:sqlite available')"
```

Install or select Node.js 22 or newer, then rerun the installer.

### The tray says OpenCodex data is unavailable

- Confirm OpenCodex is running and its local dashboard loads.
- Confirm `%USERPROFILE%\.opencodex\config.json` and `%USERPROFILE%\.opencodex\admin-api-token` exist.
- If you use non-default locations, set `OPENCODEX_HOME` and `CODEX_HOME` before starting the tray.
- Refresh from the tray menu after OpenCodex becomes available.

The provider reads the port from OpenCodex's local configuration and falls back to port `10100`.

### The popup is not visible

- Focus the Codex desktop app; the popup hides while another app is active.
- Check the notification-area overflow menu and left-click the OpenCodex Usage icon.
- Open **OpenCodex Usage** from the Start menu to reveal an existing instance.
- If you selected **Exit usage tray**, start it again from the Start menu.

### An account will not switch

Open the full OpenCodex dashboard and check whether the account is paused, unhealthy, or needs authentication. Re-authenticate it there, then refresh the tray.

### The full dashboard button does not open a working page

Confirm the OpenCodex dashboard is reachable on the port stored in `%USERPROFILE%\.opencodex\config.json`. If the file has no valid port, the tray opens `http://127.0.0.1:10100/`.

## Privacy and security

- The tray has no telemetry and makes no direct remote requests.
- OpenCodex API calls are sent only to its loopback address, `127.0.0.1`.
- The OpenCodex management token is read from the existing environment variable or token file, used in process memory, and never displayed by the UI.
- Codex task databases are opened read-only.
- Switching accounts is the only OpenCodex state change, and it occurs only after you press an account button.
- The app writes only its installation files, a small readiness heartbeat, and per-user shortcuts.

Treat the OpenCodex admin token as a credential. Do not publish it, copy it into an issue, or expose the OpenCodex management API beyond the local machine.

## Project files

| File | Purpose |
| --- | --- |
| `OpenCodexUsageTray.ps1` | WPF popup, focus behavior, theme, and tray controls |
| `OpenCodexUsageTray.WinForms.ps1` | Preserved legacy presentation for rollback and troubleshooting |
| `status-provider.mjs` | Local OpenCodex and read-only Codex task data adapter |
| `install.ps1` | Safe per-user installation and shortcut creation |
| `uninstall.ps1` | Safe removal of installed files and shortcuts |
| `OpenCodexUsage.ico` | Application and notification-area icon |
| `test.ps1` | Offline syntax and documentation-asset validation |

There is no build step. To run directly from a checkout for development:

```powershell
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File .\OpenCodexUsageTray.ps1 -ShowOnStart
```

Stop that instance with:

```powershell
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File .\OpenCodexUsageTray.ps1 -Mode Stop
```

## Limitations

- Windows only.
- The compact layout is designed for a maximum of three OpenCodex accounts.
- Task status depends on the local Codex database schema and may require updates after major Codex releases.
- Very narrow Codex windows leave less room for the popup; it remains constrained to the monitor's working area.

## License

MIT. See [LICENSE](LICENSE).
