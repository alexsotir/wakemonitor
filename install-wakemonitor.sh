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

VERSION="1.1.1"               # bump this when you change anything below

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
# Run with --test to send the wake signal 3 times and exit.

VERSION="__VERSION__"           # set by install-wakemonitor.sh

# ---- Settings ----------------------------------------------------------------

MONITOR_MAC="__MONITOR_MAC__"   # MAC address of the display's network connection
CHECK_EVERY=2                   # seconds between checks
SLEEP_GAP=10                    # a longer gap between two checks = the Mac slept
PAUSE_MS=30000                  # only read the power log after a pause this long
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

# Read the power log once (it's long, so it's slow) and set:
#   newest_wake         newest "Wake" entry ("DarkWake" entries don't count)
#   newest_display_off  newest "Display is turned off" entry
read_power_log() {
  { IFS= read -r newest_wake; IFS= read -r newest_display_off; } < <(
    pmset -g log 2>/dev/null | awk '
      /^[0-9-]+ [0-9:]+ [+-][0-9]+ Wake[ \t]/ { wake = $0 }
      /Display is turned off/                { off = $0 }
      END { print wake; print off }')
}


# ---- Deciding --------------------------------------------------------------------

# After a sleep: wait up to 8 seconds for the new Wake entry,
# then succeed only if it says the wake was caused by you.
woken_by_user() {
  local entry reason tries=0

  while [ $tries -lt 8 ]; do
    read_power_log
    entry=$newest_wake
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
  read_power_log
  [ "$newest_display_off" = "$seen_display_off" ] && return 1
  seen_display_off=$newest_display_off
  return 0
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
#   seen_wake          newest Wake entry already handled
#   seen_display_off   newest "display off" entry already handled
#   check_next_input   1 after the Mac woke by itself: check at your next
#                      key press even if there was no pause
#   prev_idle          idle time at the previous check (it drops when you
#                      touch the keyboard or trackpad)
#   prev_check         time of the previous check (a big jump = the Mac slept)

if [ "$1" = "--test" ]; then
  broadcast_magic_packet 3
  exit
fi

log "started (version $VERSION)"
read_power_log
seen_wake=$newest_wake
seen_display_off=$newest_display_off
check_next_input=0
prev_idle=$(idle_ms)
prev_check=$SECONDS

while true; do
  idle=$(idle_ms)

  if [ $((SECONDS - prev_check)) -gt $SLEEP_GAP ]; then
    # Case 1: the Mac was asleep.
    if woken_by_user; then
      seen_display_off=$newest_display_off           # handled by this wake
      send_wake_signal
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
