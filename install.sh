#!/usr/bin/env bash
# LiteView one-command installer for Linux (X11) and macOS:
#
#   curl -fsSL https://raw.githubusercontent.com/Subodh584/LiteView/main/install.sh | bash
#
# Downloads LiteView, installs its Python packages, makes it start at login,
# and starts it now. Re-run it to update.
set -euo pipefail

REPO=Subodh584/LiteView
DIR="${LITEVIEW_DIR:-$HOME/.local/share/liteview}"
LOG="$HOME/.liteview.log"

say()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m    %s\033[0m\n' "$*"; }
die()  { printf '\033[31mLiteView install failed: %s\033[0m\n' "$*" >&2; exit 1; }

command -v python3 >/dev/null || die "python3 is not installed."
command -v curl >/dev/null || die "curl is not installed."
if [ "$(uname)" = Linux ] && [ "${XDG_SESSION_TYPE:-}" = wayland ]; then
  warn "This is a Wayland session: LiteView can't capture the screen or control input here."
  warn "Log out and pick an X11/Xorg session on the login screen, then re-run this command."
fi

# Stop a running copy so its files can be replaced.
pkill -f "$DIR/host.py" 2>/dev/null || true

say "Downloading LiteView to $DIR ..."
mkdir -p "$DIR"
curl -fsSL "https://github.com/$REPO/archive/refs/heads/main.tar.gz" | tar -xz -C "$DIR" --strip-components=1

say "Installing Python packages (first time takes a minute)..."
if [ ! -x "$DIR/.venv/bin/python" ]; then
  python3 -m venv "$DIR/.venv" || die "creating a virtualenv failed. On Debian/Ubuntu run: sudo apt install python3-venv"
fi
"$DIR/.venv/bin/python" -m pip install --disable-pip-version-check -q -r "$DIR/requirements.txt"

TS_FLAG=""
if command -v tailscale >/dev/null || [ -d /Applications/Tailscale.app ]; then
  TS_FLAG="--tailscale-only"
else
  warn "Tailscale is not installed, so LiteView will only work on this local network."
  warn "For access over the internet, install it from https://tailscale.com/download and re-run this command."
fi

PY="$DIR/.venv/bin/python"
if [ "$(uname)" = Darwin ]; then
  say "Making LiteView start automatically when you log in..."
  PLIST="$HOME/Library/LaunchAgents/com.liteview.host.plist"
  mkdir -p "$(dirname "$PLIST")"
  cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.liteview.host</string>
  <key>ProgramArguments</key><array>
    <string>$PY</string><string>$DIR/host.py</string>${TS_FLAG:+<string>$TS_FLAG</string>}
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
EOF
  say "Starting LiteView in the background..."
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load "$PLIST"
  warn "macOS will ask for Screen Recording and Accessibility permission for Python. Allow both,"
  warn "then re-run this command so LiteView restarts with the permissions."
else
  say "Making LiteView start automatically when you log in..."
  mkdir -p "$HOME/.config/autostart"
  cat >"$HOME/.config/autostart/liteview.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=LiteView
Exec=sh -c '"$PY" "$DIR/host.py" $TS_FLAG >>"$LOG" 2>&1'
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF
  say "Starting LiteView in the background..."
  nohup "$PY" "$DIR/host.py" $TS_FLAG >>"$LOG" 2>&1 </dev/null &
  disown
fi

sleep 4
if ! pgrep -f "$DIR/host.py" >/dev/null; then
  warn "LiteView stopped right after starting. Last lines of $LOG:"
  tail -n 15 "$LOG" >&2 || true
  exit 1
fi

echo
printf '\033[1;32mLiteView is running. On the other computer, open:\033[0m\n'
"$PY" "$DIR/host.py" --show-address $TS_FLAG
echo
echo "It starts automatically at every login. Log file: $LOG"
echo "To stop it: pkill -f '$DIR/host.py'"
