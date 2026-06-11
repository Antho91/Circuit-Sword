#!/bin/bash
# ============================================================
# snd-usb-audio DKMS module cross-compile script
# Runs inside Dockerfile.sound
#
# What it does:
#   1. Copies sound/usb/ from the kernel source cache
#   2. Applies the volume fix patch (patches/fix-volume.patch)
#   3. Cross-compiles snd-usb-audio.ko for ARM64
#   4. Saves the .ko + patched source for DKMS first-boot rebuilds
#
# Environment variables:
#   KSRC   Path to built kernel source (default: /cache/linux)
#
# Output at /output/sound/:
#   snd-usb-audio.ko    — pre-compiled ARM64 module
#   src/                — patched sound/usb/ source snapshot (for DKMS)
#   Makefile.dkms       — out-of-tree wrapper Makefile (for DKMS)
#   dkms.conf           — DKMS configuration
# ============================================================
set -euo pipefail

KSRC=${KSRC:-/cache/linux}
OUTPUT=/output/sound
SOUND_SRC="$KSRC/sound/usb"
PATCH="/workspace/sound-module/snd-usb-audio-0.1/patches/fix-volume.patch"
BUILD_DIR="$(mktemp -d)"

echo "=== snd-usb-audio module build ==="
echo "Kernel source : $KSRC"
echo "Sound path    : $SOUND_SRC"
echo "Output        : $OUTPUT"
echo ""

# ---- Validate --------------------------------------------------
[ -d "$KSRC/.git" ] || {
    echo "ERROR: Kernel source not found at $KSRC"
    echo "       Run './build.sh kernel' first, then './build.sh sound'"
    exit 1
}
[ -f "$KSRC/Module.symvers" ] || {
    echo "ERROR: $KSRC/Module.symvers missing — kernel must be fully built first."
    exit 1
}
[ -d "$SOUND_SRC" ] || {
    echo "ERROR: $SOUND_SRC not found in kernel tree."
    exit 1
}
[ -f "$PATCH" ] || {
    echo "ERROR: Patch not found at $PATCH"
    exit 1
}

mkdir -p "$OUTPUT/src"

# ---- Copy sound/usb/ source ------------------------------------
echo "[sound] Copying sound/usb/ source..."
rsync -a --delete \
    --exclude='*.ko' \
    --exclude='*.o' \
    --exclude='*.mod' \
    --exclude='*.mod.c' \
    --exclude='.tmp_versions' \
    --exclude='Module.symvers' \
    --exclude='modules.order' \
    "$SOUND_SRC/" "$BUILD_DIR/"

# ---- Apply volume fix patch ------------------------------------
echo "[sound] Applying volume fix patch..."
if patch -p1 -d "$BUILD_DIR" --forward < "$PATCH"; then
    echo "[sound] Patch applied successfully."
else
    echo "[sound] WARNING: patch did not apply cleanly — may already be applied or context mismatch."
    echo "[sound]          Continuing with unpatched source."
fi

# ---- Cross-compile ---------------------------------------------
echo "[sound] Cross-compiling snd-usb-audio.ko ..."

cd "$KSRC"

# Clean previous artifacts
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    M="$BUILD_DIR" \
    CONFIG_SND_USB_AUDIO=m \
    clean 2>/dev/null || true

make -j"$(nproc)" \
    ARCH=arm64 \
    CROSS_COMPILE=aarch64-linux-gnu- \
    M="$BUILD_DIR" \
    CONFIG_SND_USB_AUDIO=m \
    modules

[ -f "$BUILD_DIR/snd-usb-audio.ko" ] || {
    echo "ERROR: snd-usb-audio.ko not produced — build failed."
    exit 1
}

# ---- Save artifacts --------------------------------------------
echo "[sound] Saving artifacts..."

cp "$BUILD_DIR/snd-usb-audio.ko" "$OUTPUT/snd-usb-audio.ko"

# Save patched source snapshot for DKMS (strip build artifacts)
rsync -a --delete \
    --exclude='*.ko' \
    --exclude='*.o' \
    --exclude='*.mod' \
    --exclude='*.mod.c' \
    --exclude='.tmp_versions' \
    --exclude='Module.symvers' \
    --exclude='modules.order' \
    "$BUILD_DIR/" "$OUTPUT/src/"

# Copy DKMS wrapper Makefile and config
cp /workspace/sound-module/Makefile.dkms  "$OUTPUT/src/Makefile.dkms"
cp /workspace/sound-module/dkms.conf      "$OUTPUT/src/dkms.conf"
cp /workspace/sound-module/dkms.conf      "$OUTPUT/dkms.conf"

rm -rf "$BUILD_DIR"

# Record which kernel version this was built for
KVER=$(cat "$KSRC/include/config/kernel.release" 2>/dev/null || echo "unknown")
echo "$KVER" > "$OUTPUT/built-for-kernel"

echo ""
echo "=== snd-usb-audio module build complete ==="
echo "Module    : $(ls -lh "$OUTPUT/snd-usb-audio.ko")"
echo "Built for : $KVER"
