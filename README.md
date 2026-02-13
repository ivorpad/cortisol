# Cortisol

A macOS menu bar app that prevents your Mac from sleeping. Lives in the menu bar, toggles sleep on and off, and shows power source and network info at a glance.

## Usage

Cortisol sits in the menu bar with a bolt icon.

- **bolt.fill** — sleep is disabled (your Mac is being kept awake)
- **bolt.slash** — sleep is enabled (normal behavior)

Click the icon to open the menu:

- **Keep Awake** — disable sleep indefinitely
- **Keep Awake For...** — disable sleep for 1, 2, 4, or 8 hours (countdown shown in menu bar)
- **Allow Sleep** — re-enable normal sleep behavior
- **Quit Cortisol** — re-enables sleep and exits

The menu also shows your current power source (AC or battery percentage) and active network interfaces with their IP addresses.

## First Launch

On first launch, Cortisol asks for administrator privileges (via the standard macOS auth dialog, which supports Touch ID). This installs a sudoers entry so all future sleep toggling is passwordless — you only authenticate once.

## The Watchdog

Cortisol installs a LaunchAgent (`io.gradion.cortisol.watchdog`) that acts as a safety net. It exists to handle one scenario: **Cortisol is killed or crashes while sleep is disabled.**

Without the watchdog, force-quitting or crashing while awake would leave your Mac permanently unable to sleep until you manually run `sudo pmset -a disablesleep 0`.

### How it works

The watchdog is a launchd job that runs every **120 seconds**. It executes a shell script that follows this logic:

1. **Check marker file** (`/tmp/cortisol-awake`) — if it doesn't exist, sleep was never forced, so exit immediately. This means the watchdog is essentially free when Cortisol isn't keeping the Mac awake.
2. **Check if Cortisol is running** (`pgrep -x cortisol`) — if yes, the app is alive and managing things, so exit.
3. **Check if sleep is actually disabled** (`pmset -g | grep SleepDisabled.*1`) — if sleep isn't disabled, clean up the marker file and exit.
4. **Cortisol is dead and sleep is stuck disabled.** Try passwordless sudo (`sudo -n pmset -a disablesleep 0`) to silently fix it.
5. **If passwordless sudo fails** (sudoers not installed), show a macOS dialog: *"Cortisol was terminated but your Mac is still prevented from sleeping."* with a **Restore Sleep** button that prompts for admin credentials.
6. **Clean up** the marker file.

### Files

| File | Purpose |
|---|---|
| `/tmp/cortisol-awake` | Marker file. Created when sleep is disabled, removed when re-enabled. The watchdog uses this to know whether it needs to act. |
| `~/Library/LaunchAgents/io.gradion.cortisol.watchdog.plist` | The LaunchAgent plist. Written and loaded by Cortisol on every launch. Runs the watchdog script every 120 seconds. |

### Normal quit vs kill

- **Quit from menu** — Cortisol calls `cleanup()`, which re-enables sleep, removes the marker, and the watchdog has nothing to do.
- **Force quit / crash / `kill -9`** — The marker file persists, the watchdog detects Cortisol is gone within 120 seconds, and restores sleep automatically.

## Security

### Sudoers entry

Cortisol installs a file at `/etc/sudoers.d/cortisol` that grants your user passwordless sudo for exactly two commands:

```
<username> ALL=(ALL) NOPASSWD: /usr/bin/pmset -a disablesleep 0
<username> ALL=(ALL) NOPASSWD: /usr/bin/pmset -a disablesleep 1
```

This is scoped as tightly as possible — it only permits toggling the `disablesleep` flag via `pmset`, nothing else.

### Installation process

1. The sudoers content is written to `/tmp/cortisol-sudoers`.
2. Validated with `visudo -cf` (catches syntax errors before they can lock you out of sudo).
3. Moved to `/etc/sudoers.d/cortisol`.
4. Permissions set to `440`, owned by `root:wheel` — the standard for sudoers fragments.

The entire sequence runs inside `osascript "do shell script ... with administrator privileges"`, which triggers the macOS authentication dialog (supports Touch ID if configured). This only happens once.

### Why sudo at all?

`pmset -a disablesleep` requires root. There's no unprivileged API for this on macOS. The alternatives are:

- Prompting for admin credentials every time (bad UX)
- Running the whole app as root (much worse security posture)
- Using `caffeinate` (doesn't actually disable sleep, only prevents idle sleep — closing the lid still sleeps)

The sudoers approach is the least-privilege option.

### What to audit

- `/etc/sudoers.d/cortisol` — the only persistent system-level change. Remove it to fully uninstall Cortisol's privileges.
- `~/Library/LaunchAgents/io.gradion.cortisol.watchdog.plist` — the LaunchAgent. Remove it to stop the watchdog.
- `/tmp/cortisol-awake` — ephemeral marker, cleared on reboot.

## Uninstall

1. Quit Cortisol.
2. `launchctl unload ~/Library/LaunchAgents/io.gradion.cortisol.watchdog.plist`
3. `rm ~/Library/LaunchAgents/io.gradion.cortisol.watchdog.plist`
4. `sudo rm /etc/sudoers.d/cortisol`
5. Delete the app.

## Build

Open `cortisol.xcodeproj` in Xcode and build. Requires macOS and Swift 5.9+/SwiftUI. No external dependencies.
