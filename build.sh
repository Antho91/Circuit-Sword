#!/bin/bash
# ============================================================
# Circuit Sword — Docker build orchestrator
#
# Usage:
#   ./build.sh [target]
#
# Targets:
#   all        Full build: kernel + wifi + hud + bt → assembler
#   kernel     Rebuild kernel only      (output/kernel/)
#   wifi       Rebuild WiFi DKMS module (output/wifi/)   ← needs kernel first
#   sound      Rebuild snd-usb-audio DKMS module (output/sound/) ← needs kernel first
#   hud        Rebuild cs-hud_new only  (output/hud/cs-hud)
#   software   Re-run assembler         (kernel+wifi+hud must exist)
#   retropie   Build base RetroPie image (very slow, rarely needed)
#   clean      Remove all build outputs
#   help       Show this message
#
# Optional environment variables:
#   KERNEL_BRANCH   Raspberry Pi kernel branch (default: rpi-6.12.y)
#   KERNEL_NAME     Kernel filename without .img (default: kernel8)
#
# Examples:
#   ./build.sh all                        # First build
#   ./build.sh software                   # Only re-run config (reuses kernel+hud)
#   ./build.sh kernel                     # Rebuild kernel after branch update
#   ./build.sh hud                        # Rebuild HUD after source change
#   KERNEL_BRANCH=rpi-6.6.y ./build.sh kernel
# ============================================================
set -euo pipefail

TARGET=${1:-help}

COMPOSE="docker compose"
OUTPUT_DIR="$(cd "$(dirname "$0")" && pwd)/output"
BT_BINARY="$OUTPUT_DIR/bt/rtk_hciattach"

# ---- Colour helpers ----------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[build]${RESET} $*"; }
success() { echo -e "${GREEN}[build]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[build]${RESET} $*"; }
error()   { echo -e "${RED}[build] ERROR:${RESET} $*"; exit 1; }

# ---- Prerequisite checks -----------------------------------
check_deps() {
    command -v docker >/dev/null 2>&1 \
        || error "Docker is not installed. https://docs.docker.com/get-docker/"

    docker info >/dev/null 2>&1 \
        || error "Docker daemon is not running."

    # Check for docker compose (v2 plugin or v1 standalone)
    if ! docker compose version >/dev/null 2>&1; then
        if command -v docker-compose >/dev/null 2>&1; then
            COMPOSE="docker-compose"
        else
            error "docker compose (v2) or docker-compose (v1) is required."
        fi
    fi

    # Check buildx is available (needed for ARM64 HUD build)
    docker buildx version >/dev/null 2>&1 \
        || warn "docker buildx not found — HUD ARM64 build may fail."
}

# ---- Ensure output directory exists ------------------------
mkdir -p "$OUTPUT_DIR"

# ---- Build helpers -----------------------------------------

build_base_image() {
    info "Building base Docker image (cs-build-base)..."
    docker build \
        -f docker/Dockerfile.base \
        -t cs-build-base \
        .
}

build_kernel() {
    info "=== Stage: kernel ==="
    build_base_image
    docker build \
        -f docker/Dockerfile.kernel \
        -t cs-build-kernel \
        .
    docker run --rm \
        -v "$OUTPUT_DIR":/output \
        -v cs-kernel-cache:/cache \
        -e KERNEL_BRANCH="${KERNEL_BRANCH:-rpi-6.12.y}" \
        -e KERNEL_NAME="${KERNEL_NAME:-kernel8}" \
        -e CACHE_DIR=/cache/linux \
        cs-build-kernel
    success "Kernel artifacts saved to output/kernel/"
}

build_bt() {
    info "=== Stage: bt (rtk_hciattach from source) ==="
    build_base_image
    docker build \
        -f docker/Dockerfile.bt \
        -t cs-build-bt \
        .
    mkdir -p "$OUTPUT_DIR/bt"
    docker run --rm \
        -v "$OUTPUT_DIR":/output \
        cs-build-bt
    success "rtk_hciattach saved to output/bt/rtk_hciattach"
}

build_hud() {
    info "=== Stage: hud ==="
    # Ensure buildx has an arm64-capable builder
    docker buildx inspect cs-builder >/dev/null 2>&1 \
        || docker buildx create --name cs-builder --use >/dev/null
    docker buildx use cs-builder

    docker buildx build \
        --platform linux/arm64 \
        --load \
        -f docker/Dockerfile.hud \
        -t cs-build-hud \
        .

    mkdir -p "$OUTPUT_DIR/hud"
    docker run --rm \
        --platform linux/arm64 \
        -v "$OUTPUT_DIR/hud":/output/hud \
        cs-build-hud
    success "HUD binary saved to output/hud/cs-hud"
}

build_wifi() {
    info "=== Stage: wifi (RTL8723BS DKMS module) ==="

    [ -f "$OUTPUT_DIR/kernel/${KERNEL_NAME:-kernel8}.img" ] \
        || error "Kernel artifacts missing in output/kernel/. Run './build.sh kernel' first."

    docker build \
        -f docker/Dockerfile.wifi \
        -t cs-build-wifi \
        .
    docker run --rm \
        -v "$OUTPUT_DIR":/output \
        -v cs-kernel-cache:/cache \
        -v "$(pwd)":/workspace:ro \
        -e KSRC=/cache/linux \
        cs-build-wifi
    success "WiFi module saved to output/wifi/"
}

build_sound() {
    info "=== Stage: sound (snd-usb-audio DKMS module) ==="

    [ -f "$OUTPUT_DIR/kernel/${KERNEL_NAME:-kernel8}.img" ] \
        || error "Kernel artifacts missing in output/kernel/. Run './build.sh kernel' first."

    docker build \
        -f docker/Dockerfile.sound \
        -t cs-build-sound \
        .
    docker run --rm \
        -v "$OUTPUT_DIR":/output \
        -v cs-kernel-cache:/cache \
        -v "$(pwd)":/workspace:ro \
        -e KSRC=/cache/linux \
        cs-build-sound
    success "Sound module saved to output/sound/"
}

build_assembler() {
    info "=== Stage: assembler (software) ==="

    [ -f "$OUTPUT_DIR/rpios-bookworm.img" ] \
        || error "output/rpios-bookworm.img not found. Run './build.sh retropie' first."
    [ -f "$OUTPUT_DIR/kernel/${KERNEL_NAME:-kernel8}.img" ] \
        || error "Kernel artifacts missing in output/kernel/. Run './build.sh kernel' first."
    [ -f "$OUTPUT_DIR/wifi/r8723bs.ko" ] \
        || error "WiFi module missing in output/wifi/. Run './build.sh wifi' first."
    # NOTE: snd-usb-audio (sound stage) is NOT required — we no longer bake the
    # patched volume-fix module (vermagic mismatch blocked audio); the stock
    # in-kernel snd-usb-audio drives the chip. The 'sound' target stays available
    # for the future port (see FUTURE.md) but is not part of the assembler/all.
    [ -f "$OUTPUT_DIR/hud/cs-hud" ] \
        || error "HUD binary missing in output/hud/. Run './build.sh hud' first."
    [ -f "$BT_BINARY" ] \
        || error "rtk_hciattach missing in output/bt/. Run './build.sh bt' first."

    build_base_image
    docker build --no-cache \
        -f docker/Dockerfile.assembler \
        -t cs-build-assembler \
        .
    docker run --rm \
        --privileged \
        -v "$OUTPUT_DIR":/output \
        -v "$(pwd)":/workspace:ro \
        -v /dev:/dev \
        -e KERNEL_NAME="${KERNEL_NAME:-kernel8}" \
        cs-build-assembler
    success "Final image: output/rpios-cs-final.img"
}

download_base() {
    info "=== Stage: download-base (Raspberry Pi OS Bookworm Lite 64-bit) ==="

    if [ -f "$OUTPUT_DIR/rpios-base.img" ]; then
        success "output/rpios-base.img already exists — skipping download."
        return 0
    fi

    # Stable redirect URL maintained by the Raspberry Pi Foundation —
    # always points to the latest Raspberry Pi OS Lite 64-bit (Bookworm).
    local URL="https://downloads.raspberrypi.com/raspios_lite_arm64_latest"
    local XZ="$OUTPUT_DIR/rpios-base.img.xz"

    command -v curl >/dev/null 2>&1 || error "curl is required. Install with: brew install curl"
    command -v xz   >/dev/null 2>&1 || error "xz is required. Install with: brew install xz"

    info "Downloading latest Raspberry Pi OS Lite 64-bit..."
    info "(This is ~500 MB — grab a coffee)"
    curl -L --progress-bar -o "$XZ" "$URL"

    info "Extracting image..."
    xz --decompress --keep --stdout "$XZ" > "$OUTPUT_DIR/rpios-base.img"
    rm -f "$XZ"

    success "Base image saved to output/rpios-base.img ($(du -h "$OUTPUT_DIR/rpios-base.img" | cut -f1))"
}

build_retropie() {
    info "=== Stage: retropie (install RetroPie into RPi OS base image) ==="

    # Auto-download base image if not present
    download_base

    if [ ! -f "$OUTPUT_DIR/rpios-base.img" ]; then
        error "output/rpios-base.img not found and download failed."
    fi

    build_base_image
    docker build \
        -f docker/Dockerfile.retropie \
        -t cs-build-retropie \
        .
    docker run --rm \
        --privileged \
        -v "$OUTPUT_DIR":/output \
        -v /dev:/dev \
        cs-build-retropie
    success "RetroPie image saved to output/rpios-bookworm.img"
}

show_help() {
    cat <<EOF
${BOLD}Circuit Sword build system${RESET}

Usage: ./build.sh [target]

${BOLD}Targets:${RESET}
  ${CYAN}all${RESET}        Full build: kernel + wifi + hud + bt → assembler
  ${CYAN}kernel${RESET}     Rebuild kernel only            → output/kernel/
  ${CYAN}wifi${RESET}       Rebuild WiFi DKMS module       → output/wifi/   (needs kernel)
  ${CYAN}sound${RESET}      Rebuild snd-usb-audio module   → output/sound/  (needs kernel)
  ${CYAN}hud${RESET}        Rebuild cs-hud_new only        → output/hud/cs-hud
  ${CYAN}bt${RESET}         Build rtk_hciattach from source → output/bt/rtk_hciattach
  ${CYAN}software${RESET}   Re-run assembler               → output/rpios-cs-final.img
  ${CYAN}download-base${RESET} Download Raspberry Pi OS Lite 64-bit  → output/rpios-base.img
  ${CYAN}retropie${RESET}      Install RetroPie into base image       → output/rpios-bookworm.img
  ${CYAN}clean${RESET}      Remove all build outputs (keeps Docker image cache)
  ${CYAN}help${RESET}       Show this message

${BOLD}Environment variables:${RESET}
  KERNEL_BRANCH   e.g. rpi-6.12.y (default: rpi-6.12.y)
  KERNEL_NAME     e.g. kernel8 (default: kernel8)
  WIFI_BRANCH     (unused — WiFi source taken from kernel cache directly)

${BOLD}First-time build:${RESET}
  ./build.sh retropie    # downloads RPi OS + installs RetroPie (~1h)
  ./build.sh all         # kernel + wifi + hud + bt + assembler

${BOLD}Typical iteration (only software changed):${RESET}
  ./build.sh software

${BOLD}Typical iteration (HUD source changed):${RESET}
  ./build.sh hud && ./build.sh software
EOF
}

# ---- Main --------------------------------------------------
check_deps

case "$TARGET" in
    all)
        build_kernel
        build_wifi
        # build_sound — skipped: snd-usb-audio volume-fix module isn't baked
        # (stock in-kernel driver is used). Run './build.sh sound' only when
        # working on the future port. See FUTURE.md.
        build_hud
        build_bt
        build_assembler
        success "=== Full build complete: output/rpios-cs-final.img ==="
        ;;
    kernel)   build_kernel   ;;
    wifi)     build_wifi     ;;
    sound)    build_sound    ;;
    hud)      build_hud      ;;
    bt)       build_bt       ;;
    software) build_assembler ;;
    retropie)      build_retropie  ;;
    download-base) download_base   ;;
    clean)
        info "Removing build outputs..."
        rm -rf "$OUTPUT_DIR/kernel" \
               "$OUTPUT_DIR/wifi" \
               "$OUTPUT_DIR/sound" \
               "$OUTPUT_DIR/hud" \
               "$OUTPUT_DIR/bt" \
               "$OUTPUT_DIR/rpios-cs-final.img"
        warn "Kept output/rpios-bookworm.img (base image — slow to rebuild)."
        warn "To also delete it: rm output/rpios-bookworm.img"
        success "Clean done."
        ;;
    help|--help|-h) show_help ;;
    *)
        error "Unknown target: '$TARGET'. Run './build.sh help' for usage."
        ;;
esac
