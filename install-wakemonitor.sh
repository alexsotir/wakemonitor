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

VERSION="1.0.1"               # bump this when you change anything below

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

stop_service() {
  launchctl bootout "$SERVICE" 2>/dev/null
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

send_test_signal() {
  local mac=$1
  require_mac_address "$mac"
  echo "Sending the wake signal to $mac ..."
  local i
  for ((i = 0; i < 3; i++)); do
    /usr/bin/perl -MSocket -e '
      my $mac = shift;
      $mac =~ s/[:-]//g;
      my $packet = ("\xff" x 6) . (pack("H12", $mac) x 16);
      socket(my $sock, PF_INET, SOCK_DGRAM, getprotobyname("udp")) or die "socket: $!\n";
      setsockopt($sock, SOL_SOCKET, SO_BROADCAST, 1) or die "setsockopt: $!\n";
      send($sock, $packet, 0, sockaddr_in(9, INADDR_BROADCAST)) or die "send: $!\n";
    ' "$mac" || exit 1
    sleep 1
  done
  echo "Sent. If your display didn't turn on, check its network wake setting and the MAC address."
}


# ---- The script that does the work (copied to ~/.wakemonitor/wakemonitor.sh) ----

write_script() {
  local mac=$1
  mkdir -p "$INSTALL_DIR" "$(dirname "$LOG_FILE")"
  sed -e "s/__MONITOR_MAC__/$mac/" -e "s/__VERSION__/$VERSION/" > "$SCRIPT" <<'SCRIPT_END'
#!/bin/bash
#
# WakeMonitor: turns your monitor or TV back on when you come back to your Mac.
#
# Some displays (smart monitors and TVs) ignore the Mac's video signal once
# they have switched themselves off, but respond to a network wake-up signal
# (Wake-on-LAN). This script sends that signal when you return after the
# display was off:
#
#   1. After sleep: as soon as the power log says YOU woke the Mac
#      (key press, trackpad).
#   2. After the display went off without sleep (power button, display sleep):
#      when you touch the keyboard or trackpad after a pause and the power log
#      shows the display was turned off in the meantime.
#
# The Mac's own wake-ups (night maintenance, notifications) are ignored until
# you actually press something.
#
# Started at login by install-wakemonitor.sh. Log: ~/Library/Logs/wakemonitor.log

VERSION="__VERSION__"           # set by install-wakemonitor.sh

# ---- Settings ----------------------------------------------------------------

MONITOR_MAC="__MONITOR_MAC__"   # MAC address of the display's network connection
CHECK_EVERY=2                   # seconds between checks
SLEEP_GAP=10                    # a longer gap between two checks = the Mac slept
PAUSE_MS=5000                   # only read the power log after a pause this long
WAKE_ATTEMPTS=20                # send the signal this many times, 1 second apart
LOG_FILE="$HOME/Library/Logs/wakemonitor.log"

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"


# ---- Reading the system's state -----------------------------------------------

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
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

# Newest "Wake" entry in the power log ("DarkWake" entries don't count).
newest_wake_entry() {
  pmset -g log 2>/dev/null |
    grep -E '^[0-9-]{10} [0-9:]{8} [+-][0-9]{4} Wake[[:space:]]' |
    tail -1
}

# Newest "Display is turned off" entry in the power log.
newest_display_off_entry() {
  pmset -g log 2>/dev/null | grep 'Display is turned off' | tail -1
}


# ---- Deciding --------------------------------------------------------------------

# After a sleep: wait up to 8 seconds for the new Wake entry,
# then succeed only if it says the wake was caused by you.
woken_by_user() {
  local entry reason tries=0

  while [ $tries -lt 8 ]; do
    entry=$(newest_wake_entry)
    if [ -n "$entry" ] && [ "$entry" != "$seen_wake" ]; then
      seen_wake=$entry
      reason=${entry#*due to }
      reason=${reason%% Using*}
      log "Mac woke (reason: $reason)"
      case "$entry" in
        *"HID Activity"* | *UserActivity* | *LidOpen* | *PowerButton* | *PwrBtn*)
          return 0 ;;
        *)
          return 1 ;;
      esac
    fi
    sleep 1
    tries=$((tries + 1))
  done

  log "Mac woke briefly by itself"
  return 1
}

# After a pause: has the display been turned off since we last looked?
display_was_off() {
  local entry
  entry=$(newest_display_off_entry)
  [ "$entry" = "$seen_display_off" ] && return 1
  seen_display_off=$entry
  return 0
}


# ---- Acting -----------------------------------------------------------------------

# Broadcast the Wake-on-LAN "magic packet" a few times, in case Wi-Fi is
# still reconnecting after a wake.
send_wake_signal() {
  log "you're back -> sending wake signal"
  local i
  for ((i = 0; i < WAKE_ATTEMPTS; i++)); do
    perl -MSocket -e '
      my $mac = shift;
      $mac =~ s/[:-]//g;
      # magic packet: 6 bytes of 0xFF, then the MAC address 16 times
      my $packet = ("\xff" x 6) . (pack("H12", $mac) x 16);
      socket(my $sock, PF_INET, SOCK_DGRAM, getprotobyname("udp")) or die;
      setsockopt($sock, SOL_SOCKET, SO_BROADCAST, 1) or die;
      send($sock, $packet, 0, sockaddr_in(9, INADDR_BROADCAST)) or die;
    ' "$MONITOR_MAC" 2>/dev/null
    sleep 1
  done
}


# ---- Main loop -------------------------------------------------------------------
#
# What the loop remembers between checks:
#   seen_wake          newest Wake entry already handled
#   seen_display_off   newest "display off" entry already handled
#   check_next_input   1 after the Mac woke by itself: check at your next
#                      key press even if there was no pause
#   prev_idle          idle time at the previous check (it drops when you
#                      touch the keyboard or trackpad)
#   prev_check         time of the previous check (a big jump = the Mac slept)

log "started (version $VERSION)"
seen_wake=$(newest_wake_entry)
seen_display_off=$(newest_display_off_entry)
check_next_input=0
prev_idle=$(idle_ms)
prev_check=$SECONDS

while true; do
  idle=$(idle_ms)

  if [ $((SECONDS - prev_check)) -gt $SLEEP_GAP ]; then
    # Case 1: the Mac was asleep.
    if woken_by_user; then
      send_wake_signal
      seen_display_off=$(newest_display_off_entry)   # handled by this wake
      check_next_input=0
    else
      check_next_input=1                              # it woke itself; wait for you
    fi
    idle=$(idle_ms)

  elif [ "$idle" -lt "$prev_idle" ] &&
       { [ "$prev_idle" -ge $PAUSE_MS ] || [ $check_next_input -eq 1 ]; }; then
    # Case 2: you're back after a pause (or after the Mac woke itself).
    if display_was_off; then
      log "display was off"
      send_wake_signal
    fi
    check_next_input=0
    idle=$(idle_ms)
  fi

  prev_idle=$idle
  prev_check=$SECONDS
  sleep $CHECK_EVERY
done
SCRIPT_END
  chmod +x "$SCRIPT"
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

  write_script "$mac"
  write_launch_agent
  stop_service                                   # stop an older version, if running
  launchctl bootstrap "gui/$(id -u)" "$PLIST" &&
    echo "WakeMonitor $VERSION installed and running. Log: ~/Library/Logs/wakemonitor.log"
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
