#!/bin/bash
#
# install-wakemonitor.sh: installs or removes WakeMonitor, which turns your
# monitor or TV back on (Wake-on-LAN) when you come back to your Mac.
# See README.md for setup and details.
#
#   Test first:         bash install-wakemonitor.sh --test AA:BB:CC:DD:EE:FF
#   Install or update:  bash install-wakemonitor.sh AA:BB:CC:DD:EE:FF
#   Remove:             bash install-wakemonitor.sh --uninstall
#   Show versions:      bash install-wakemonitor.sh --version
#
# Files it creates:
#   ~/.wakemonitor/wakemonitor.sh                     the script that does the work
#   ~/Library/LaunchAgents/io.github.wakemonitor.plist  starts it at login, restarts it if it stops
#   ~/Library/Logs/wakemonitor.log                    what it did and when

VERSION="1.2.0"               # bump this when you change anything below

LABEL="io.github.wakemonitor"
INSTALL_DIR="$HOME/.wakemonitor"
SCRIPT="$INSTALL_DIR/wakemonitor.sh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_FILE="$HOME/Library/Logs/wakemonitor.log"
SERVICE="gui/$(id -u)/$LABEL"


usage() {
  echo "Test first:         bash install-wakemonitor.sh --test AA:BB:CC:DD:EE:FF"
  echo "Install or update:  bash install-wakemonitor.sh AA:BB:CC:DD:EE:FF"
  echo "Remove:             bash install-wakemonitor.sh --uninstall"
  echo "Show versions:      bash install-wakemonitor.sh --version"
  echo
  echo "AA:BB:CC:DD:EE:FF is the MAC address of your display's network connection."
}

is_mac_address() {
  local pattern='^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$'
  [[ "$1" =~ $pattern ]]
}

require_mac_address() {
  if ! is_mac_address "$1"; then
    usage
    exit 1
  fi
}

# Stop the running service and wait until launchd has really let go of it
# (bootout returns early, and bootstrapping too soon fails with error 5).
stop_service() {
  launchctl bootout "$SERVICE" 2>/dev/null || return 0
  local i
  for ((i = 0; i < 20; i++)); do
    launchctl print "$SERVICE" &>/dev/null || return 0
    sleep 0.5
  done
}

show_versions() {
  local installed="not installed"
  if [ -f "$SCRIPT" ]; then
    installed=$(sed -n 's/^VERSION="\(.*\)".*/\1/p' "$SCRIPT")
  fi
  echo "This installer:  $VERSION"
  echo "Installed:       $installed"
}


# ---- Test: send the wake signal once, without installing anything ---------------

# Uses the same code as the installed script: writes it to a temporary file
# and runs it in --test mode.
send_test_signal() {
  local mac=$1 tmp status
  require_mac_address "$mac"
  tmp=$(mktemp) || exit 1
  write_script "$mac" "$tmp"
  echo "Sending the wake signal to $mac ..."
  bash "$tmp" --test
  status=$?
  rm -f "$tmp"
  [ $status -eq 0 ] || exit 1
  echo "Sent. If your display didn't turn on, check its network wake setting and the MAC address."
}


# ---- The script that does the work (copied to ~/.wakemonitor/wakemonitor.sh) ----

write_script() {
  local mac=$1 dest=$2
  sed -e "s/__MONITOR_MAC__/$mac/" -e "s/__VERSION__/$VERSION/" > "$dest" <<'SCRIPT_END'
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
# Started at login by install-wakemonitor.sh. Log: ~/Library/Logs/wakemonitor.log
# Run with --test to send the wake signal 3 times and exit.

VERSION="__VERSION__"           # set by install-wakemonitor.sh

# ---- Settings ----------------------------------------------------------------

MONITOR_MAC="__MONITOR_MAC__"   # MAC address of the display's network connection
CHECK_EVERY=2                   # seconds between checks while the display is on
WATCH_EVERY=1                   # seconds between checks while the display is off
SLEEP_GAP=10                    # a longer gap between two checks = the Mac slept
LOCK_CHECK_MS=10000             # check whether the screen is locked after a pause this long
RECENT_INPUT_MS=15000           # after a sleep: you woke it if you pressed something this recently
POWER_CHECK_EVERY=30            # seconds between "still plugged in?" checks
BATTERY_CHECK_EVERY=10          # on battery: seconds between "plugged in again?" checks
WAKE_ATTEMPTS=20                # send the signal this many times, 1 second apart
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

# Send it repeatedly, in case Wi-Fi is still reconnecting after a wake.
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
  broadcast_magic_packet 3
  exit
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
SCRIPT_END
}


# ---- The startup file (tells macOS to run the script at login) ------------------

write_launch_agent() {
  mkdir -p "$(dirname "$PLIST")"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$SCRIPT</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
</dict>
</plist>
EOF
}


# ---- Install / uninstall -----------------------------------------------------------

install() {
  local mac=$1
  require_mac_address "$mac"

  mkdir -p "$INSTALL_DIR" "$(dirname "$LOG_FILE")"
  write_script "$mac" "$SCRIPT"
  chmod +x "$SCRIPT"
  write_launch_agent
  stop_service                                   # stop an older version, if running
  if launchctl bootstrap "gui/$(id -u)" "$PLIST"; then
    echo "WakeMonitor $VERSION installed and running. Log: ~/Library/Logs/wakemonitor.log"
  else
    echo "WakeMonitor $VERSION installed, but macOS couldn't start it." >&2
    echo "Try: launchctl kickstart -k $SERVICE" >&2
    exit 1
  fi
}

uninstall() {
  stop_service
  rm -rf "$INSTALL_DIR" "$PLIST" "$LOG_FILE"
  echo "WakeMonitor removed."
}


case "$1" in
  --test)       send_test_signal "$2" ;;
  --uninstall)  uninstall ;;
  --version)    show_versions ;;
  -h | --help)  usage ;;
  *)            install "$1" ;;
esac
