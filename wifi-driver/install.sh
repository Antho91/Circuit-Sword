#!/bin/bash
# ============================================================
# RTL8723BS WiFi DKMS — on-Pi installer / repair tool
#
# Run this on the Raspberry Pi to (re)install the DKMS module.
# Useful after a fresh flash or if DKMS becomes desynced.
#
# Source: Raspberry Pi kernel staging tree (sparse checkout —
#         only drivers/staging/rtl8723bs, not the full kernel)
#
# Usage:  sudo bash wifi-driver/install.sh
# ============================================================
set -euo pipefail

DKMS_NAME="rtl8723bs"
DKMS_VER="1.0.0"
SRC_DIR="/usr/src/${DKMS_NAME}-${DKMS_VER}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root (sudo)"
    exit 1
fi

echo "=== RTL8723BS WiFi DKMS installer ==="

# ---- 1. Dependencies ----------------------------------------
echo "[wifi] Installing build dependencies..."
apt-get update -qq
apt-get install -y --no-install-recommends \
    dkms \
    build-essential \
    raspberrypi-kernel-headers \
    git

# ---- 2. Source ----------------------------------------------
# Prefer pre-installed source (placed by Docker assembler).
# Fall back to a sparse git checkout of ONLY the staging driver
# directory — much faster than cloning the full kernel (~50 MB
# vs ~1.5 GB).
if [ ! -d "$SRC_DIR" ]; then
    echo "[wifi] Source not found — fetching from Raspberry Pi kernel staging tree..."

    # Derive branch from running kernel: 6.12.34-v8-... → rpi-6.12.y
    KBRANCH="rpi-$(uname -r | grep -oP '^\d+\.\d+').y"
    echo "[wifi] Using kernel branch: $KBRANCH"

    SPARSE_DIR=$(mktemp -d)
    git clone \
        --filter=blob:none \
        --sparse \
        --depth=1 \
        --branch "$KBRANCH" \
        https://github.com/raspberrypi/linux.git \
        "$SPARSE_DIR"

    git -C "$SPARSE_DIR" sparse-checkout set drivers/staging/rtl8723bs

    mkdir -p "$SRC_DIR"
    rsync -a "$SPARSE_DIR/drivers/staging/rtl8723bs/" "$SRC_DIR/"
    rm -rf "$SPARSE_DIR"

    # Place our wrapper Makefile and dkms.conf
    cp "$SCRIPT_DIR/Makefile"   "$SRC_DIR/Makefile.dkms"
    cp "$SCRIPT_DIR/dkms.conf"  "$SRC_DIR/dkms.conf"
fi

# Ensure wrapper Makefile is present (may be missing on older installs)
[ -f "$SRC_DIR/Makefile.dkms" ] && \
    cp "$SRC_DIR/Makefile.dkms" "$SRC_DIR/Makefile"

# ---- 3. Remove old registration if present ------------------
dkms status "${DKMS_NAME}/${DKMS_VER}" 2>/dev/null \
    | grep -q "^${DKMS_NAME}" \
    && dkms remove "${DKMS_NAME}/${DKMS_VER}" --all || true

# ---- 4. Register + build + install --------------------------
echo "[wifi] Registering with DKMS..."
dkms add "${DKMS_NAME}/${DKMS_VER}"

echo "[wifi] Building module (this may take a few minutes)..."
dkms build "${DKMS_NAME}/${DKMS_VER}"

echo "[wifi] Installing module..."
dkms install "${DKMS_NAME}/${DKMS_VER}"

# ---- 5. Load module -----------------------------------------
modprobe r8723bs 2>/dev/null || true

echo ""
echo "=== Done ==="
dkms status "${DKMS_NAME}/${DKMS_VER}"
echo ""
echo "The module rebuilds automatically after kernel updates."
echo "Required: 'raspberrypi-kernel-headers' must remain installed."
