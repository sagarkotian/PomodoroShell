# PomodoroShell

A minimal, flat terminal Pomodoro timer written in PowerShell. It runs without third-party modules, keeps time against a real deadline so redraws do not introduce drift, and alerts you whenever an interval finishes—even when the terminal is behind another window.

![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-00bcd4?style=flat-square)

## Run

Open an interactive PowerShell terminal in this directory:

```powershell
.\PomodoroShell.ps1
```

If script execution is disabled for the current process, use:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\PomodoroShell.ps1
```

The default rotation is four 25-minute focus intervals, with 5-minute short breaks and a 15-minute long break. Finished intervals buzz with a short ascending tone sequence and, on Windows, display a desktop notification. The timer waits at the next interval so an unattended break does not disappear; pass `-AutoStart` to keep the rotation moving automatically.

Label the work you are about to do:

```powershell
.\PomodoroShell.ps1 -Task "Write project proposal"
```

The label appears in the TUI, terminal title, completion notification, and session history.

## Controls

| Key | Action |
| --- | --- |
| `Space` | Pause or resume |
| `R` | Reset the current interval |
| `S` | Skip to the next interval |
| `Left` / `Right` | Remove or add one minute |
| `Q` | Quit cleanly |

## Options

```powershell
.\PomodoroShell.ps1 `
  -Task "Deep work" `
  -FocusMinutes 50 `
  -ShortBreakMinutes 10 `
  -LongBreakMinutes 30 `
  -SessionsBeforeLongBreak 3 `
  -AutoStart
```

Command-line choices become the defaults for the next run. Use `-NoSound` for silent transitions, `-NoNotification` to disable desktop notifications, or `-NoPersistence` for a one-off session that neither loads nor saves user data. An empty task (`-Task ''`) clears the saved label.

Run `Get-Help .\PomodoroShell.ps1 -Detailed` for built-in help.

## Settings and history

PomodoroShell stores two human-readable files in `%LOCALAPPDATA%\PomodoroShell` on Windows:

- `settings.json` contains durations, alert preferences, auto-start behavior, and the last task label.
- `history.jsonl` contains one JSON object per completed focus interval. It records the timestamp, task, duration, and session number.

Pass `-DataDirectory <path>` to use a portable or custom storage location. The TUI reads history at startup and displays today's completed focus count and minutes.

## Test

The dependency-free test runner covers interval rotation, skipped-session behavior, task sanitization, settings recovery, and history totals:

```powershell
.\tests\Test-PomodoroShell.ps1
```

## Notes

- Requires Windows PowerShell 5.1 or PowerShell 7+ and an interactive console.
- `Console.Beep` is used first. If a host does not support it, PomodoroShell falls back to the terminal bell and the operating system notification sound.
- On Windows, notifications use the built-in notification-area API. They require no PowerShell module or external package.
- In terminals with virtual-terminal support, the TUI uses an alternate screen and restores the original terminal contents when it closes.
- The terminal should be at least 28 columns by 13 rows. The layout recenters itself after a resize.
