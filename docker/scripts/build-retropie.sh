#!/bin/bash
# ============================================================
# RetroPie installer
# Runs inside Dockerfile.retropie (--privileged)
#
# Mounts a Raspberry Pi OS Bookworm Lite 64-bit image,
# expands it, and installs RetroPie inside via chroot.
# DNS is explicitly set before any apt/git command — this is
# what the old Gemba-in-Docker approach could not do.
#
# Input:  /output/rpios-base.img
# Output: /output/rpios-retropie.img
# ============================================================
set -euo pipefail

BASE_IMG="/output/rpios-base.img"
OUTPUT_IMG="/output/rpios-retropie.img"
MNT=/mnt/retropie-build
EXTRA_GB=4

# ---- Cleanup trap ------------------------------------------
LOOPDEV=""
cleanup() {
    echo "[retropie] Cleaning up..."
    rm -f "$MNT/usr/bin/qemu-aarch64-static" 2>/dev/null || true
    for m in proc sys dev/pts dev boot/firmware; do
        umount "$MNT/$m" 2>/dev/null || true
    done
    umount "$MNT" 2>/dev/null || true
    [ -n "$LOOPDEV" ] && losetup -d "$LOOPDEV" 2>/dev/null || true
}
trap cleanup EXIT

# ---- Validate ----------------------------------------------
if [ ! -f "$BASE_IMG" ]; then
    echo ""
    echo "ERROR: $BASE_IMG not found."
    echo ""
    echo "  1. Go to: https://www.raspberrypi.com/software/operating-systems/"
    echo "  2. Download 'Raspberry Pi OS Lite' — 64-bit, Bookworm"
    echo "  3. Extract the .img from the zip/xz archive"
    echo "  4. Place it at: output/rpios-base.img"
    echo ""
    exit 1
fi

echo "=== RetroPie image builder ==="
echo "Base  : $BASE_IMG ($(du -h "$BASE_IMG" | cut -f1))"
echo "Output: $OUTPUT_IMG"
echo ""

# ---- 1. Copy and expand image ------------------------------
echo "[retropie] Copying base image..."
cp --sparse=always "$BASE_IMG" "$OUTPUT_IMG"

echo "[retropie] Expanding image by +${EXTRA_GB}GB for RetroPie packages..."
truncate -s "+${EXTRA_GB}G" "$OUTPUT_IMG"

# ---- 2. Resize root partition to fill new space ------------
echo "[retropie] Resizing root partition..."
# parted operates on the image file directly
parted -s "$OUTPUT_IMG" resizepart 2 100%

# Set up loop device after resize so p2 reflects new size
LOOPDEV=$(losetup --partscan --find --show "$OUTPUT_IMG")
echo "[retropie] Loop device: $LOOPDEV"

e2fsck -fy "${LOOPDEV}p2" || true
resize2fs "${LOOPDEV}p2"

# ---- 3. Mount ----------------------------------------------
echo "[retropie] Mounting..."
mkdir -p "$MNT"
mount "${LOOPDEV}p2" "$MNT"
mkdir -p "$MNT/boot/firmware"
mount "${LOOPDEV}p1" "$MNT/boot/firmware"

# Bind mounts needed for a functional chroot
mount --bind /proc    "$MNT/proc"
mount --bind /sys     "$MNT/sys"
mount --bind /dev     "$MNT/dev"
mount --bind /dev/pts "$MNT/dev/pts"

# ---- 4. QEMU (no-op on ARM64 host, harmless elsewhere) -----
cp /usr/bin/qemu-aarch64-static "$MNT/usr/bin/qemu-aarch64-static"

# ---- 5. Fix DNS --------------------------------------------
# THIS is what was broken in the old approach: Docker Desktop's
# internal DNS (127.0.0.11) doesn't work in a nested chroot.
# We own this chroot, so we set it explicitly.
echo "nameserver 8.8.8.8"  > "$MNT/etc/resolv.conf"
echo "nameserver 8.8.4.4" >> "$MNT/etc/resolv.conf"
echo "[retropie] DNS set to 8.8.8.8 in chroot"

# Fix hostname resolution so sudo doesn't spam warnings
echo "127.0.0.1 $(hostname)" >> "$MNT/etc/hosts"

# ---- 6. Ensure pi user exists ------------------------------
chroot "$MNT" bash -c "
    id pi 2>/dev/null || (
        useradd -m -s /bin/bash pi &&
        echo 'pi:raspberry' | chpasswd
    )
    usermod -aG sudo,video,audio,input pi 2>/dev/null || true
"

# ---- 7. Update + install git -------------------------------
echo "[retropie] Updating package lists..."
chroot "$MNT" bash -c "apt-get update -qq"

echo "[retropie] Installing git..."
chroot "$MNT" bash -c "apt-get install -y --no-install-recommends git dialog"

# ---- 8. Clone RetroPie-Setup (Gemba Bookworm fork) ---------
echo "[retropie] Cloning RetroPie-Setup (Bookworm/aarch64 branch)..."
chroot "$MNT" bash -c "
    if [ ! -d /home/pi/RetroPie-Setup ]; then
        git clone --depth=1 \
            -b fb_image_sh_bookworm_aarch64 \
            https://github.com/Gemba/RetroPie-Setup.git \
            /home/pi/RetroPie-Setup
    fi
    chown -R 1000:1000 /home/pi/RetroPie-Setup
"

# ---- 9. Install RetroPie -----------------------------------
echo ""
echo "[retropie] Installing RetroPie basic packages (~1 hour)..."
echo "[retropie] This compiles emulators from source — go get a coffee."
echo ""

# CRITICAL: force __platform=rpi3 so RetroPie compiles for the CM3's Cortex-A53
# (-mcpu=cortex-a53). The build runs in a Docker container with no real Pi to
# detect, so without this RetroPie picks the wrong CPU and the binaries crash
# on the CM3 with "Illegal instruction" (SIGILL) — EmulationStation included.
chroot "$MNT" bash -c "
    cd /home/pi/RetroPie-Setup
    export __platform=rpi3
    SUDO_USER=pi HOME=/home/pi __platform=rpi3 \
        bash retropie_packages.sh setup basic_install
" || echo "[retropie] WARNING: Some packages may have failed — continuing."

# ---- 10. Cleanup inside chroot -----------------------------
chroot "$MNT" bash -c "apt-get clean && rm -rf /var/lib/apt/lists/*" || true
rm -f "$MNT/usr/bin/qemu-aarch64-static"

echo ""
echo "=== RetroPie installation complete ==="
echo "Output: $(ls -lh "$OUTPUT_IMG" | awk '{print $5, $9}')"
