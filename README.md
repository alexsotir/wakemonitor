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
- Uses only tools built into macOS (bash, perl, pmset, ioreg)
- Works on the lock screen
- Ignores the Mac's own night-time wake-ups

## How it works

A small script runs in the background and checks every 2 seconds:

1. **After sleep:** when the Mac wakes, it reads the reason from macOS's power
   log. If *you* woke it (a key press or the trackpad), it sends the wake
   signal straight away.
2. **After the display went off without sleep** (power button, display sleep):
   when you touch the keyboard or trackpad after a pause, it checks the power
   log. If the display was turned off in the meantime, it sends the wake signal.
3. **The Mac's own wake-ups** (night maintenance, notifications) are ignored
   until you actually press something.

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

It prints `WakeMonitor 1.0.1 installed and running`. macOS shows a notification
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
| `started (version 1.0.1)` | The script started (at login or after an update). |
| `Mac woke (reason: HID Activity)` | You woke the Mac. Other reasons you may see: `UserActivity Assertion` (also you), `Notification` (the Mac woke itself). |
| `Mac woke briefly by itself` | A night-time maintenance wake. Ignored. |
| `display was off` | You came back after the display had been turned off without sleep. |
| `you're back -> sending wake signal` | The wake signal was sent. |

To clear the log: `: > ~/Library/Logs/wakemonitor.log`

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
| `CHECK_EVERY` | 2 | Seconds between checks |
| `SLEEP_GAP` | 10 | A longer gap between two checks means the Mac slept |
| `PAUSE_MS` | 5000 | Only read the power log after a pause this long (ms) |
| `WAKE_ATTEMPTS` | 20 | How many times to send the signal, 1 second apart |

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
- **Work with displays that don't support network wake.** Some TVs only accept
  it over Ethernet, not Wi-Fi. Regular monitors without a network connection
  normally wake from the Mac's video signal anyway, so they don't need this.

## Resources and privacy

- Each check is a tiny system query. The power log is read only when you come
  back after a pause of 5+ seconds. Nothing runs while the Mac is asleep.
- No internet access. The only network traffic is the wake-up packet, sent to
  your local network.
- No admin rights. It reads the time since your last key press and macOS's
  power log, and writes its own log file.

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
