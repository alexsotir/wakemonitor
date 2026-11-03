#!/bin/bash
#
# install-wakemonitor.sh: installs or removes WakeMonitor, which turns your
# monitor or TV back on (Wake-on-LAN) when you come back to your Mac.
# Run it from the downloaded folder: it installs the wakemonitor.sh next to it.
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
# Your own ~/.wakemonitor/settings, if you create one, is kept on update.

SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wakemonitor.sh"

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

require_source() {
  if [ ! -f "$SOURCE" ]; then
    echo "wakemonitor.sh not found next to the installer ($SOURCE)." >&2
    echo "Download the whole folder (GitHub: Code -> Download ZIP) and run the installer from it." >&2
    exit 1
  fi
}

# The VERSION="..." line of a WakeMonitor script.
version_of() {
  sed -n 's/^VERSION="\(.*\)".*/\1/p' "$1"
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
  local available="not found" installed="not installed"
  [ -f "$SOURCE" ] && available=$(version_of "$SOURCE")
  [ -f "$SCRIPT" ] && installed=$(version_of "$SCRIPT")
  echo "This download:  $available"
  echo "Installed:      $installed"
}


# ---- Test: send the wake signal once, without installing anything ---------------

send_test_signal() {
  local mac=$1
  require_mac_address "$mac"
  require_source
  echo "Sending the wake signal to $mac ..."
  bash "$SOURCE" --test "$mac" || exit 1
  echo "Sent. If your display didn't turn on, check its network wake setting and the MAC address."
}


# ---- The startup file (tells macOS to run the script at login) ------------------

write_launch_agent() {
  local mac=$1
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
    <string>$mac</string>
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
  require_source

  mkdir -p "$INSTALL_DIR" "$(dirname "$LOG_FILE")"
  cp "$SOURCE" "$SCRIPT"
  chmod +x "$SCRIPT"
  write_launch_agent "$mac"
  stop_service                                   # stop an older version, if running
  if launchctl bootstrap "gui/$(id -u)" "$PLIST"; then
    echo "WakeMonitor $(version_of "$SCRIPT") installed and running. Log: ~/Library/Logs/wakemonitor.log"
  else
    echo "WakeMonitor $(version_of "$SCRIPT") installed, but macOS couldn't start it." >&2
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
