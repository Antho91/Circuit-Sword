#!/bin/bash
set -e

# === Basic settings ===
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
START_FOLDER="$BASE_DIR/build"
IMG_DIR="$START_FOLDER/img"
BUILD_DIR="$START_FOLDER/kernel"

IMG="rpios-bookworm.img"

LOCALVERSION="-v8-CUSTOM_KERNEL"
KERNEL="kernel8-custom"
KERNELOLD="kernel8"

MNT_BOOT="$IMG_DIR/mnt_boot"
MNT_ROOT="$IMG_DIR/mnt_root"

# === Create directories ===
mkdir -p "$START_FOLDER" "$IMG_DIR" "$BUILD_DIR" "$MNT_BOOT" "$MNT_ROOT"

# === 1. Mount image ===
echo "Mounting image..."
loopdev=$(sudo losetup --partscan --find --show "$IMG")
bootp="${loopdev}p1"
rootp="${loopdev}p2"

sudo mount "$rootp" "$MNT_ROOT"
# === FIX: ensure that /boot/firmware mountpoint exists in rootfs ===
if [ ! -d "$MNT_ROOT/boot/firmware" ]; then
    echo "📂 Creating /boot/firmware mountpoint in rootfs..."
    sudo mkdir -p "$MNT_ROOT/boot/firmware"
fi
sudo mount "$bootp" "$MNT_BOOT"

# === 2. Kernel build ===
echo "Building kernel..."
sudo apt-get update
sudo apt-get install -y gcc-aarch64-linux-gnu git bc bison flex libssl-dev make libc6-dev libncurses5-dev

rm -rf "$BUILD_DIR/linux"
git clone --depth=1 --branch rpi-6.12.y https://github.com/raspberrypi/linux "$BUILD_DIR/linux"
cd "$BUILD_DIR/linux"

# === 2A. Config & Build ===
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- bcm2711_defconfig
sed -i 's|# CONFIG_RTL8723BS is not set|CONFIG_RTL8723BS=m|' .config
echo "CONFIG_LOCALVERSION=\"$LOCALVERSION\"" >> .config

make -j$(nproc) ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- Image modules dtbs

make -j$(nproc) ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- INSTALL_MOD_PATH="$MNT_ROOT" modules_install

sudo cp "$MNT_BOOT/${KERNELOLD}.img" "$MNT_BOOT/${KERNELOLD}-backup.img"
sudo cp arch/arm64/boot/Image "$MNT_BOOT/${KERNEL}.img"
sudo cp arch/arm64/boot/dts/broadcom/*.dtb "$MNT_BOOT/"
sudo cp arch/arm64/boot/dts/overlays/*.dtb* "$MNT_BOOT/overlays/"
sudo cp arch/arm64/boot/dts/overlays/README "$MNT_BOOT/overlays/"

# Change config.txt
if ! grep -q "^kernel=${KERNEL}.img" "$MNT_BOOT/config.txt"; then
    echo "kernel=${KERNEL}.img" | sudo tee -a "$MNT_BOOT/config.txt" > /dev/null
fi

# === 3. Cleanup ===
echo "Unmounting..."
sudo umount "$MNT_BOOT"
sudo umount "$MNT_ROOT"
sudo losetup -d "$loopdev"

echo "Done! Image is ready at: $IMG"

