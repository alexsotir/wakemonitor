#!/bin/bash
#
# WakeMonitor: turns your monitor or TV back on when you come back to your Mac.
#
# Some displays (smart monitors and TVs) ignore the Mac's video signal once
# they have switched themselves off, but respond to a network wake-up signal
# (Wake-on-LAN). This script sends that signal when you return after the
# display was off.
#
# While the display is on it only notices when the display goes off:
#   - the Mac slept (a long gap between two checks)
#   - the screen locked (power button, Ctrl-Cmd-Q), checked once per pause
#   - you were inactive longer than the display-sleep setting
# Then it checks every second for your first key press or trackpad touch and
# sends the signal. The Mac's own night-time wake-ups are ignored: the
# graphics stay off during those.
#
# On battery it does nothing but check whether it's plugged in again: a
# laptop on battery isn't running a closed-lid setup with the display.
#
# Installed and started at login by install-wakemonitor.sh:
#   wakemonitor.sh AA:BB:CC:DD:EE:FF          watch and wake (what runs at login)
#   wakemonitor.sh --test AA:BB:CC:DD:EE:FF   send the wake signal 3 times and exit
#
# Log: ~/Library/Logs/wakemonitor.log
# To change a setting, edit it below. Installing an update replaces this file.

VERSION="1.3.3"                 # bump this when you change anything

# ---- Settings ----------------------------------------------------------------

CHECK_EVERY=2                   # seconds between checks while the display is on
WATCH_EVERY=1                   # seconds between checks while the display is off
SLEEP_GAP=10                    # a longer gap between two checks = the Mac slept
LOCK_CHECK_MS=3000              # check whether the screen is locked after a pause this long
                                # (short, so a key press while the display is still
                                # switching off is already noticed)
RECENT_INPUT_MS=15000           # after a sleep: you woke it if you pressed something this recently
POWER_CHECK_EVERY=30            # seconds between "still plugged in?" checks
BATTERY_CHECK_EVERY=10          # on battery: seconds between "plugged in again?" checks
WAKE_ATTEMPTS=30                # send the signal this many times, 1 second apart
LOG_FILE="$HOME/Library/Logs/wakemonitor.log"
LOG_LINES=200                   # keep only this many lines in the log

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"


# ---- Reading the system's state -----------------------------------------------

# Append a line, then trim the log to its newest LOG_LINES lines.
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
  if [ "$(wc -l < "$LOG_FILE")" -gt "$LOG_LINES" ]; then
    tail -n "$LOG_LINES" "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
  fi
}

# Milliseconds since the last key press, click or trackpad touch.
idle_ms() {
  local ms
  ms=$(ioreg -r -d 1 -k HIDIdleTime -c IOHIDSystem 2>/dev/null |
       awk '/HIDIdleTime/ { print int($NF / 1000000); exit }')
  if [ -z "$ms" ]; then   # fallback: slower full query
    ms=$(ioreg -c IOHIDSystem 2>/dev/null |
         awk '/HIDIdleTime/ { print int($NF / 1000000); exit }')
  fi
  echo "${ms:-0}"
}

# Is the screen locked?
screen_locked() {
  ioreg -n Root -d 1 2>/dev/null | grep -q '"CGSSessionScreenIsLocked"=Yes'
}

# Is the Mac running on battery? (Desktop Macs never are.)
on_battery() {
  pmset -g ps 2>/dev/null | head -1 | grep -q "'Battery Power'"
}

# The display-sleep setting in milliseconds (0 = never).
display_sleep_ms() {
  local ms
  ms=$(pmset -g 2>/dev/null | awk '$1 == "displaysleep" { print $2 * 60000; exit }')
  echo "${ms:-0}"
}

# Is the Mac fully awake? During its own night-time wake-ups ("dark wakes")
# the graphics stay off.
fully_awake() {
  case "$(pmset -g systemstate 2>/dev/null)" in
    *Capabilities*Graphics*) return 0 ;;
    *Capabilities*)          return 1 ;;
    *)                       return 0 ;;   # unexpected output: assume awake
  esac
}


# ---- Acting -----------------------------------------------------------------------

# Broadcast the Wake-on-LAN "magic packet" $1 times, 1 second apart.
# A failed send (Wi-Fi still reconnecting) is reported and retried next second.
# Fails only if no packet at all could be sent.
broadcast_magic_packet() {
  perl -MSocket -e '
    my ($mac, $times) = @ARGV;
    $mac =~ s/[:-]//g;
    # magic packet: 6 bytes of 0xFF, then the MAC address 16 times
    my $packet = ("\xff" x 6) . (pack("H12", $mac) x 16);
    socket(my $sock, PF_INET, SOCK_DGRAM, getprotobyname("udp")) or die "socket: $!\n";
    setsockopt($sock, SOL_SOCKET, SO_BROADCAST, 1) or die "setsockopt: $!\n";
    my $sent = 0;
    for my $i (1 .. $times) {
      if (send($sock, $packet, 0, sockaddr_in(9, INADDR_BROADCAST))) { $sent++ }
      else { warn "send: $!\n" }
      sleep 1 if $i < $times;
    }
    exit($sent ? 0 : 1);
  ' "$MONITOR_MAC" "$1"
}

# Send it repeatedly: Wi-Fi may still be reconnecting after a wake, and a
# display that is still switching itself off ignores the signal until it's
# fully in standby.
send_wake_signal() {
  log "you're back -> sending wake signal"
  broadcast_magic_packet "$WAKE_ATTEMPTS" 2>/dev/null
}


# ---- Main loop -------------------------------------------------------------------
#
# What the loop remembers between checks:
#   display_off        1 = the display went off: watch for your return
#   just_woke          1 = the Mac just woke from sleep, and it isn't known
#                      yet whether you woke it
#   lock_checked       1 = the lock was already checked during this pause
#   paused             1 = on battery
#   slept_on_battery   1 = the Mac slept while paused
#   display_sleep      the display-sleep setting (ms), refreshed with the power check
#   prev_idle          idle time at the previous check (it drops when you
#                      touch the keyboard or trackpad)
#   prev_check         time of the previous check (a big jump = the Mac slept)

if [ "$1" = "--test" ]; then
  MONITOR_MAC=$2
  broadcast_magic_packet 3
  exit
fi

MONITOR_MAC=$1                  # MAC address of the display's network connection
if [ -z "$MONITOR_MAC" ]; then
  echo "Usage: wakemonitor.sh AA:BB:CC:DD:EE:FF" >&2
  exit 1
fi

log "started (version $VERSION)"
display_off=0
just_woke=0
lock_checked=0
paused=0
slept_on_battery=0
display_sleep=$(display_sleep_ms)
next_power_check=$SECONDS
prev_idle=$(idle_ms)
prev_check=$SECONDS

while true; do
  # Still plugged in? On battery, only check again later.
  if [ $SECONDS -ge $next_power_check ]; then
    if on_battery; then
      if [ $paused -eq 0 ]; then
        log "on battery -> paused"
        paused=1
      fi
      before=$SECONDS
      sleep $BATTERY_CHECK_EVERY
      [ $((SECONDS - before)) -gt $((BATTERY_CHECK_EVERY + SLEEP_GAP)) ] && slept_on_battery=1
      continue
    fi
    if [ $paused -eq 1 ]; then
      log "plugged in -> resumed"
      paused=0
      display_off=$slept_on_battery              # it slept: the display was off
      just_woke=$slept_on_battery
      slept_on_battery=0
      prev_idle=$(idle_ms)
      prev_check=$SECONDS
    fi
    display_sleep=$(display_sleep_ms)
    next_power_check=$((SECONDS + POWER_CHECK_EVERY))
  fi

  idle=$(idle_ms)

  if [ $((SECONDS - prev_check)) -gt $SLEEP_GAP ]; then
    display_off=1                                # the Mac slept: the display was off
    just_woke=1
  fi

  if [ $display_off -eq 1 ]; then
    # The display is off: watch for your return.
    if [ $just_woke -eq 1 ] && fully_awake; then
      just_woke=0
      if [ "$idle" -lt $RECENT_INPUT_MS ]; then  # you woke it
        log "Mac woke up"
        send_wake_signal
        display_off=0
      fi                                         # otherwise: keep watching
    elif [ "$idle" -lt "$prev_idle" ]; then      # you pressed something
      send_wake_signal
      display_off=0
    fi
    if [ $display_off -eq 0 ]; then
      lock_checked=0
      idle=$(idle_ms)
    fi

  else
    # The display is on: has it gone off?
    if [ "$idle" -lt "$prev_idle" ]; then
      lock_checked=0                             # you're active: a new pause starts
    elif [ $lock_checked -eq 0 ] && [ "$idle" -ge $LOCK_CHECK_MS ]; then
      lock_checked=1
      if screen_locked; then
        log "screen locked"
        display_off=1
      fi
    fi
    if [ $display_off -eq 0 ] && [ "$display_sleep" -gt 0 ] && [ "$idle" -ge "$display_sleep" ]; then
      log "display went to sleep"
      display_off=1
    fi
  fi

  prev_idle=$idle
  prev_check=$SECONDS
  if [ $display_off -eq 1 ]; then sleep $WATCH_EVERY; else sleep $CHECK_EVERY; fi
done
