# WakeMonitor

Turns your monitor or TV back on when you come back to your Mac.

Some smart monitors and TVs used as Mac displays (for example LG webOS models
like the UltraGear 32G810SA) switch themselves fully off when the Mac sleeps or
the display goes dark, and then **ignore the Mac when it wakes up**. You press a
key, the Mac wakes, and the screen stays black until you find the remote.

WakeMonitor fixes that with one small script. When you come back to your Mac, it
sends the display a standard network wake-up signal
([Wake-on-LAN](https://en.wikipedia.org/wiki/Wake-on-LAN)), and the display
turns on by itself.

- No app to install, no pairing, no admin password
- No keyboard shortcuts, just press any key to wake up your monitor
- Uses only tools built into macOS (bash, perl, pmset, ioreg)
- Works on the lock screen
- Ignores the Mac's own night-time wake-ups
- It works with any monitor or TV that supports Wake-On-Lan

## How it works

A small script runs in the background. While the display is on, it only
checks every 2 seconds whether the display has gone off:

- **The Mac slept**
- **The screen locked** (power button, Ctrl-Cmd-Q). It checks this once each
  time you've been inactive for 10 seconds.
- **You were inactive longer than your display-sleep setting**

Once the display is off, it checks every second for your first key press or
trackpad touch and sends the wake signal. After sleep, if you woke the Mac, it
sends it straight away.

**The Mac's own wake-ups** (night maintenance, Power Nap) are ignored: during
those, macOS keeps the graphics off, and nobody presses anything.

**On battery** it pauses and only checks every 10 seconds whether the Mac is
plugged in again. A Mac on battery is a laptop that isn't running with its lid
closed and the display attached.

The signal is repeated for 20 seconds, because Wi-Fi takes a few seconds to
reconnect after a wake.

## Requirements

- A Mac running macOS (tested on macOS 26 Tahoe).
- A display that can be **turned on over the network**, with that option
  enabled. The setting has a different name on each brand:

  | Brand | Setting to turn on |
  |---|---|
  | LG webOS (TVs, smart monitors) | **Quick Start+** and **Turn on via Wi-Fi** (sometimes under "Mobile TV On") |
  | Samsung (Tizen TVs, Smart Monitors) | **Power On with Mobile** (sometimes under the network's expert settings) |
  | Sony Bravia | **Remote start** |
  | Others | Look for "Wake-on-LAN", "network standby" or "turn on via network/Wi-Fi" |

- The Mac and the display on the **same network**.

## Setup

### 1. Find your display's MAC address

Look in the display's network settings, usually under *About*, *Network status*
or *Wi-Fi details*. Use the address of the connection it actually uses: the
wireless one if it's on Wi-Fi, the wired one if it's on Ethernet.

### 2. Test it

Download `install-wakemonitor.sh`. Turn the display off with its remote, wait a
few seconds, then run this in Terminal with your display's MAC address:

```bash
bash ~/Downloads/install-wakemonitor.sh --test AA:BB:CC:DD:EE:FF
```

The display should turn on. If macOS asks whether Terminal can access the local
network, click **Allow** and run it again. If the display stays off, check the
network wake setting and the MAC address before going further.

### 3. Install

```bash
bash ~/Downloads/install-wakemonitor.sh AA:BB:CC:DD:EE:FF
```

It prints `WakeMonitor <version> installed and running`. macOS shows a notification
that a background item was added (listed as "wakemonitor.sh"); leave it allowed.
If macOS asks whether "wakemonitor.sh", "bash" or "perl" can access the local
network, click **Allow**.

That's it. It starts automatically every time you log in.

## Usage

There's nothing to do: put the Mac to sleep or turn the display off as usual,
and the display comes back when you do.

The log shows what it did:

```bash
cat ~/Library/Logs/wakemonitor.log
```

| Log line | Meaning |
|---|---|
| `started (version <version>)` | The script started (at login or after an update). |
| `screen locked` | The screen was locked (for example with the power button); it now watches for your return. |
| `display went to sleep` | You were inactive longer than the display-sleep setting; it now watches for your return. |
| `Mac woke up` | You woke the Mac from sleep. |
| `you're back -> sending wake signal` | The wake signal was sent. |
| `on battery -> paused` / `plugged in -> resumed` | It pauses while on battery. |

The log keeps only the newest 200 lines. To clear it: `: > ~/Library/Logs/wakemonitor.log`

### Commands

```bash
bash install-wakemonitor.sh --test AA:BB:CC:DD:EE:FF   # send the wake signal once
bash install-wakemonitor.sh AA:BB:CC:DD:EE:FF          # install or update
bash install-wakemonitor.sh --version                  # installer vs installed version
bash install-wakemonitor.sh --uninstall                # remove everything
```

### Settings

The settings are at the top of `~/.wakemonitor/wakemonitor.sh`:

| Setting | Default | Meaning |
|---|---|---|
| `CHECK_EVERY` | 2 | Seconds between checks while the display is on |
| `WATCH_EVERY` | 1 | Seconds between checks while the display is off |
| `SLEEP_GAP` | 10 | A longer gap between two checks means the Mac slept |
| `LOCK_CHECK_MS` | 10000 | Check whether the screen is locked after this long without input (ms) |
| `RECENT_INPUT_MS` | 15000 | After sleep: you woke the Mac if you pressed something this recently (ms) |
| `POWER_CHECK_EVERY` | 30 | Seconds between "still plugged in?" checks |
| `BATTERY_CHECK_EVERY` | 10 | On battery: seconds between "plugged in again?" checks |
| `WAKE_ATTEMPTS` | 20 | How many times to send the signal, 1 second apart |
| `LOG_LINES` | 200 | How many lines the log keeps (older ones are removed) |

After editing, restart it:

```bash
launchctl kickstart -k gui/$(id -u)/io.github.wakemonitor
```

Running the installer again overwrites your changes.

## What it doesn't do

- **Turn the display on at startup.** It runs inside your user account, so it
  starts after you log in. Use the remote when you power on the Mac.
- **Turn the display off.** It only wakes it. Most monitors turn off automatically when idle.
- **Reach displays on another network.** The wake signal is a local broadcast
  and doesn't cross subnets.
- **Run on battery.** It pauses until the Mac is plugged in again, so a laptop
  on battery with the lid open and a TV as an extra screen won't get the signal.
- **Work with displays that don't support network wake.** Some TVs only accept
  it over Ethernet, not Wi-Fi. Regular monitors without a network connection
  normally wake from the Mac's video signal anyway, so they don't need this.

## Resources and privacy

- While the display is on: one tiny system query every 2 seconds, one lock
  check per pause of 10+ seconds, and a power-source check every 30 seconds.
  Nothing heavier runs while you work. Nothing runs while the Mac is asleep.
- No internet access. The only network traffic is the wake-up packet, sent to
  your local network.
- No admin rights. It reads the time since your last key press, whether the
  screen is locked, the power source and display-sleep setting, and writes its
  own log file.

### Files

| File | Purpose |
|---|---|
| `~/.wakemonitor/wakemonitor.sh` | The script that does the work |
| `~/Library/LaunchAgents/io.github.wakemonitor.plist` | Starts it at login and restarts it if it stops |
| `~/Library/Logs/wakemonitor.log` | What it did and when |

## Troubleshooting

**Nothing appears in the log when you come back.** Check that it's running:

```bash
launchctl print gui/$(id -u)/io.github.wakemonitor | grep -E "state =|pid ="
```

**The log says "sending wake signal" but the display stays off.**
- Run the `--test` command. If that doesn't work either, the problem is the
  display's network wake setting or the MAC address.
- Check System Settings → Privacy & Security → **Local Network** and allow
  "wakemonitor.sh", "bash" or "perl" if listed.

**To see what macOS recorded** (sleep, wake reasons, display on/off):

```bash
pmset -g log | grep -E "Entering Sleep|Wake from|Display is turned" | tail -20
```

## Uninstall

```bash
bash install-wakemonitor.sh --uninstall
```

This stops it and deletes all three files.

## Tested on

| Display | Connection | Mac | macOS |
|---|---|---|---|
| LG UltraGear 32G810SA (webOS 24) | Wi-Fi | MacBook Air M4, lid closed | 26 Tahoe |

Works with your display? Please open an issue with the model, how it's
connected (Wi-Fi or Ethernet) and your macOS version, so it can be added here.

## License

MIT. See [LICENSE](LICENSE).
