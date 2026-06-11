#!/bin/bash
set -e

echo "=== cs-hud installer ==="

# --- Dependencies ---
echo "[1/4] Installing dependencies..."
apt-get update -qq
apt-get install -y \
    libsdl2-dev \
    libsdl2-ttf-dev \
    libdrm-dev \
    pigpio \
    fonts-dejavu-core

# Enable pigpiod service
systemctl enable pigpiod
systemctl start  pigpiod

# --- Build ---
echo "[2/4] Building cs-hud..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
make clean
make

# --- Install ---
echo "[3/4] Installing binary and service..."
make install

# --- Power supply symlink for RetroArch / ES-DE ---
echo "[4/4] Setting up power supply directory..."
mkdir -p /run/cs-power

# Create a tmpfiles.d entry so /run/cs-power persists across reboots
cat > /etc/tmpfiles.d/cs-power.conf << 'EOF'
d /run/cs-power 0755 root root -
EOF

echo ""
echo "=== Done! ==="
echo "cs-hud is now running. Press the mode button on the Game Boy to open the overlay."
echo ""
echo "Useful commands:"
echo "  systemctl status cs-hud    — check daemon status"
echo "  journalctl -u cs-hud -f    — follow live logs"
echo "  systemctl restart cs-hud   — restart the daemon"
