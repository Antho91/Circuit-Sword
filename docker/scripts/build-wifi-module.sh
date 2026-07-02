#!/bin/bash
# ============================================================
# RTL8723BS WiFi DKMS module cross-compile script
# Runs inside Dockerfile.wifi
#
# Source: drivers/staging/rtl8723bs from the Raspberry Pi kernel
#         tree that is already in the kernel cache volume.
#         No external repositories required.
#
# Environment variables:
#   KSRC   Path to built kernel source (default: /cache/linux)
#
# Output at /output/wifi/:
#   r8723bs.ko          — pre-compiled ARM64 module
#   src/                — staging tree source snapshot (for DKMS)
#   Makefile            — out-of-tree wrapper Makefile (for DKMS)
#   dkms.conf           — DKMS configuration
# ============================================================
set -euo pipefail

KSRC=${KSRC:-/cache/linux}
OUTPUT=/output/wifi
STAGING_SRC="$KSRC/drivers/staging/rtl8723bs"

echo "=== RTL8723BS WiFi module build ==="
echo "Kernel source : $KSRC"
echo "Staging path  : $STAGING_SRC"
echo "Output        : $OUTPUT"
echo ""

# ---- Validate --------------------------------------------------
[ -d "$KSRC/.git" ] || {
    echo "ERROR: Kernel source not found at $KSRC"
    echo "       Run './build.sh kernel' first, then './build.sh wifi'"
    exit 1
}
[ -f "$KSRC/Module.symvers" ] || {
    echo "ERROR: $KSRC/Module.symvers missing — kernel must be fully built first."
    exit 1
}
[ -d "$STAGING_SRC" ] || {
    echo "ERROR: $STAGING_SRC not found in kernel tree."
    echo "       Ensure the kernel branch contains drivers/staging/rtl8723bs"
    exit 1
}

mkdir -p "$OUTPUT/src"

# ---- Cross-compile using kernel build system -------------------
# We invoke the kernel's own build system with M= pointing at the
# staging directory. CONFIG_RTL8723BS=m is required because the
# staging Makefile uses obj-$(CONFIG_RTL8723BS).
echo "[wifi] Cross-compiling r8723bs.ko ..."

cd "$KSRC"

# Clean previous build artifacts in staging dir
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    M="$STAGING_SRC" \
    CONFIG_RTL8723BS=m \
    clean 2>/dev/null || true

make -j"$(nproc)" \
    ARCH=arm64 \
    CROSS_COMPILE=aarch64-linux-gnu- \
    M="$STAGING_SRC" \
    CONFIG_RTL8723BS=m \
    modules

[ -f "$STAGING_SRC/r8723bs.ko" ] || {
    echo "ERROR: r8723bs.ko not produced — build failed."
    exit 1
}

# ---- Save artifacts --------------------------------------------
echo "[wifi] Saving artifacts..."

cp "$STAGING_SRC/r8723bs.ko" "$OUTPUT/r8723bs.ko"

# Copy staging source snapshot for DKMS (strip build artifacts)
rsync -a --delete \
    --exclude='*.ko' \
    --exclude='*.o' \
    --exclude='*.mod' \
    --exclude='*.mod.c' \
    --exclude='.tmp_versions' \
    --exclude='Module.symvers' \
    --exclude='modules.order' \
    "$STAGING_SRC/" "$OUTPUT/src/"

# Fix source layout for out-of-tree DKMS use.
# The staging Makefile is a Kbuild object list — rename it so the kernel
# build system reads it correctly, then place our wrapper as Makefile.
mv "$OUTPUT/src/Makefile" "$OUTPUT/src/Kbuild"
cp /workspace/wifi-driver/Makefile  "$OUTPUT/src/Makefile"

# Bundle compat.h for forward API compatibility across kernel versions.
cp /workspace/wifi-driver/compat.h  "$OUTPUT/src/compat.h"
# $(src) is a literal Make variable written into Kbuild, not a shell expansion.
# shellcheck disable=SC2016
grep -q 'compat.h' "$OUTPUT/src/Kbuild" \
    || echo 'ccflags-y += -include $(src)/compat.h' >> "$OUTPUT/src/Kbuild"

# Patch cfg80211 ops signatures for kernel 6.18+ (MLO link_id additions).
python3 /workspace/wifi-driver/patches/fix-cfg80211-6.18.py \
    "$OUTPUT/src/os_dep/ioctl_cfg80211.c"

# Place dkms.conf
cp /workspace/wifi-driver/dkms.conf "$OUTPUT/src/dkms.conf"
cp /workspace/wifi-driver/dkms.conf "$OUTPUT/dkms.conf"

# Record which kernel version this was built for
KVER=$(cat "$KSRC/include/config/kernel.release" 2>/dev/null || echo "unknown")
echo "$KVER" > "$OUTPUT/built-for-kernel"

echo ""
echo "=== WiFi module build complete ==="
echo "Module    : $(ls -lh "$OUTPUT/r8723bs.ko")"
echo "Built for : $KVER"
echo "Sources   : $(find "$OUTPUT/src" -name '*.c' | wc -l) C files from staging tree"
