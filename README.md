# clset

Lightweight Windows CLI to schedule and toggle Claude 5-hour session window triggers via Windows Task Scheduler.

Works identically in **PowerShell (`pwsh` / `powershell`), CMD, and Git Bash** with zero runtime dependencies and no admin rights required.

## Default 4-Session Preset

Out of the box, `clset init` sets up 4 daily 5-hour sessions (leaving 4:00 AM – 9:30 AM prompt-free):

| Session | Time | Default |
| :---: | :--- | :---: |
| **1** | `09:30` | **ON** |
| **2** | `14:30` | OFF |
| **3** | `19:30` | OFF |
| **4** | `00:30` | **ON** |

You can address any session by its **number (`1`, `2`, `3`, `4`)** or **time (`14:30` / `1430`)**, and freely edit, add, or delete custom times.

## Prerequisites

- Windows 10/11
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated (`claude` on `PATH`)

## Install

### From a cloned repo
```powershell
.\install.ps1
```

### Portable one-liner (after publishing to GitHub)
```powershell
irm https://raw.githubusercontent.com/arzakyo/clset/main/install.ps1 | iex
```

### WinGet (after publishing manifest)
```powershell
winget install arzakyo.clset
```

## Usage

Works in `pwsh`, `powershell`, `cmd`, and Git Bash:

```text
# Status & setup
clset                             # Show all sessions (aliases: status, list, ls)
clset init                        # Install default 4-session preset
clset init --anchor 08:00         # Auto-generate 4x 5h sessions from 08:00
clset init --slots 09:30,14:30,19:30,00:30 --default 1,4

# Toggle by session number OR time
clset 2                           # Quick-toggle session 2 (14:30)
clset on 2 3                      # Turn sessions 2 & 3 ON
clset off 2 3                     # Turn sessions 2 & 3 OFF
clset on                          # Turn all sessions ON
clset off                         # Turn all sessions OFF
clset default                     # Restore default ON/OFF (1 & 4 ON)

# Customize session times
clset set 2 15:00                 # Change session 2 to 15:00
clset add 22:00                   # Add a custom session 5 at 22:00 (use --off to add disabled)
clset del 5                       # Remove session 5
clset preset                      # Reset back to the default 4-session preset

# Test & cleanup
clset test 1                      # Fire session 1 trigger now
clset test --direct               # Run the claude ping directly in this terminal
clset remove                      # Remove all scheduled tasks
```

## Publishing to WinGet

1. Push this repo to GitHub and tag a release (`git tag v0.2.0 && git push --tags`).
2. `.github/workflows/release.yml` automatically attaches `clset-v0.2.0-windows.zip` to the GitHub Release.
3. Fill in `winget/manifest-template.yaml` (or run `wingetcreate new <release-zip-url>`) and open a PR to `microsoft/winget-pkgs`.

## License

MIT
