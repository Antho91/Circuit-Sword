#!/bin/bash
# ============================================================
# Kernel cross-compile script
# Runs inside Dockerfile.kernel
#
# Environment variables:
#   KERNEL_BRANCH   Git branch to build (default: rpi-6.12.y)
#   KERNEL_NAME     Output kernel filename (default: kernel8)
#
# Output at /output/kernel/:
#   kernel8.img    — kernel image
#   *.dtb                 — device trees (broadcom/)
#   overlays/             — overlay device trees
#   modules.tar.gz        — all kernel modules (extract to rootfs /)
# ============================================================
set -euo pipefail

KERNEL_BRANCH=${KERNEL_BRANCH:-rpi-6.12.y}
KERNEL_NAME=${KERNEL_NAME:-kernel8}
LOCALVERSION="-v8-cs"

CACHE_DIR=${CACHE_DIR:-/cache/linux}
OUTPUT=/output/kernel
WIFI_OUTPUT=/output/wifi

echo "=== Kernel build ==="
echo "Branch  : $KERNEL_BRANCH"
echo "Output  : $OUTPUT"
echo "Cache   : $CACHE_DIR"
echo ""

mkdir -p "$OUTPUT" "$OUTPUT/overlays" "$WIFI_OUTPUT"

# ---- 1. Get kernel source (use cache if available) --------
if [ -d "$CACHE_DIR/.git" ]; then
    echo "[kernel] Using cached source — fetching updates..."
    git -C "$CACHE_DIR" fetch --depth=1 origin "$KERNEL_BRANCH"
    git -C "$CACHE_DIR" reset --hard "origin/$KERNEL_BRANCH"
else
    echo "[kernel] Cloning kernel source (branch: $KERNEL_BRANCH)..."
    mkdir -p "$(dirname "$CACHE_DIR")"
    git clone --depth=1 --branch "$KERNEL_BRANCH" \
        https://github.com/raspberrypi/linux "$CACHE_DIR"
fi

cd "$CACHE_DIR"

# ---- 2. Configure ------------------------------------------
echo "[kernel] Configuring..."

# bcm2711_defconfig is the official 64-bit RPi config for all arm64 boards
# (RPi 3, CM3, RPi 4, CM4). Correct base for our CM3 build.
echo "[kernel] Using bcm2711_defconfig as base..."
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- bcm2711_defconfig

# Apply the RPi extra config fragments if present (rpi_defconfig additions)
for cfg in kernel_configs/rpi-base.config kernel_configs/rpi-bcm2711.config; do
    if [ -f "$cfg" ]; then
        echo "[kernel] Applying extra config: $cfg"
        scripts/kconfig/merge_config.sh -m .config "$cfg"
    fi
done

# Set custom version string
scripts/config --set-str CONFIG_LOCALVERSION "$LOCALVERSION"

# Enable RTL8723BS WiFi (SDIO) — in-tree staging driver.
scripts/config --enable CONFIG_STAGING
scripts/config --module CONFIG_RTL8723BS

# Resolve any new symbols introduced by our changes
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig

# ---- 3. Build ----------------------------------------------
echo "[kernel] Compiling ($(nproc) cores)..."
make -j"$(nproc)" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    Image modules dtbs

# ---- 4. Package modules ------------------------------------
echo "[kernel] Packaging modules..."
MODULES_TMP=$(mktemp -d)
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    INSTALL_MOD_PATH="$MODULES_TMP" modules_install
tar czf "$OUTPUT/modules.tar.gz" -C "$MODULES_TMP" .
rm -rf "$MODULES_TMP"

# ---- 5. Copy kernel artifacts ------------------------------
echo "[kernel] Copying artifacts..."
cp arch/arm64/boot/Image                       "$OUTPUT/${KERNEL_NAME}.img"
cp arch/arm64/boot/dts/broadcom/*.dtb          "$OUTPUT/"
cp arch/arm64/boot/dts/overlays/*.dtb*         "$OUTPUT/overlays/"
cp arch/arm64/boot/dts/overlays/README         "$OUTPUT/overlays/"

# ---- 6. Export WiFi DKMS source ----------------------------
echo "[kernel] Exporting RTL8723BS staging source for DKMS..."
WIFI_SRC="drivers/staging/rtl8723bs"
if [ -d "$WIFI_SRC" ]; then
    rm -rf "$WIFI_OUTPUT/src"
    cp -a "$WIFI_SRC" "$WIFI_OUTPUT/src"
    # Rename the staging Makefile to Kbuild — it contains obj-$(CONFIG_RTL8723BS)
    # entries needed by the kernel build system for out-of-tree builds.
    # Our wrapper Makefile goes in as Makefile (called by DKMS/make directly).
    mv "$WIFI_OUTPUT/src/Makefile" "$WIFI_OUTPUT/src/Kbuild"
    cp /opt/wifi-driver/dkms.conf  "$WIFI_OUTPUT/dkms.conf"
    cp /opt/wifi-driver/Makefile   "$WIFI_OUTPUT/Makefile"
    cp /opt/wifi-driver/compat.h   "$WIFI_OUTPUT/src/compat.h"
    # Inject compat.h include into Kbuild for kernel 6.15+ API compat
    echo 'ccflags-y += -include $(src)/compat.h' >> "$WIFI_OUTPUT/src/Kbuild"
    # Write .kver so cs-dkms-setup.sh can detect when source needs refreshing
    echo "$KERNEL_BRANCH" | grep -o '[0-9]*\.[0-9]*' > "$WIFI_OUTPUT/src/.kver"
    echo "[kernel] WiFi source exported to $WIFI_OUTPUT/src ($(find "$WIFI_OUTPUT/src" -name '*.c' | wc -l) .c files)"
else
    echo "[kernel] WARNING: $WIFI_SRC not found in kernel tree — DKMS source not exported"
fi

# ---- 7. Package kernel headers for DKMS ----------------------
# Provides /usr/src/linux-headers-<kver>/ on the Pi.
# Scripts source is included but compiled binaries are stripped (they're
# x86 cross-compile host artifacts). cs-dkms-setup.sh recompiles them
# natively on the Pi via 'make scripts_prepare scripts'.
echo "[kernel] Packaging kernel headers..."
KVER=$(cat include/config/kernel.release)
HT=$(mktemp -d)
HD="$HT/linux-headers-${KVER}"
mkdir -p "$HD"

cp Makefile .config          "$HD/"
cp Module.symvers            "$HD/" 2>/dev/null || true
[ -f Kbuild ] && cp Kbuild   "$HD/"

# Global kernel headers (include/generated/ has autoconf.h with CONFIG_* macros)
cp -a include "$HD/"

# ARM64-specific headers and Makefile
mkdir -p "$HD/arch/arm64"
cp arch/arm64/Makefile "$HD/arch/arm64/"
[ -f arch/arm64/Kbuild ] && cp arch/arm64/Kbuild "$HD/arch/arm64/"
cp -a arch/arm64/include "$HD/arch/arm64/"

# Scripts: copy everything, then strip compiled binaries (x86 host artifacts)
cp -a scripts "$HD/"
find "$HD/scripts" -maxdepth 4 -type f \
    ! -name '*.c' ! -name '*.h' ! -name '*.S' \
    ! -name 'Makefile*' ! -name 'Kbuild*' \
    ! -name '*.sh' ! -name '*.pl' ! -name '*.py' \
    ! -name '*.lds' ! -name '*.lds.S' \
    ! -name '*.o' ! -name '*.a' \
    -exec file {} + 2>/dev/null \
    | grep 'ELF' | cut -d: -f1 | xargs rm -f 2>/dev/null || true

echo "$KVER" > "$HD/.kver"
tar czf "$OUTPUT/headers.tar.gz" -C "$HT" .
rm -rf "$HT"
echo "[kernel] Headers packaged: $OUTPUT/headers.tar.gz ($(du -sh "$OUTPUT/headers.tar.gz" | cut -f1))"

# ---- Done --------------------------------------------------
echo ""
echo "=== Kernel build complete ==="
ls -lh "$OUTPUT/"
echo ""
echo "Kernel version: $(cat include/config/kernel.release 2>/dev/null || echo unknown)"
