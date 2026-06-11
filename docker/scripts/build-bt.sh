#!/bin/bash
# ============================================================
# rtk_hciattach cross-compile script
# Runs inside Dockerfile.bt
#
# Clones lwfinger/rtl8723bs_bt and cross-compiles rtk_hciattach
# for ARM64.
#
# Output at /output/bt/:
#   rtk_hciattach   — ARM64 binary
# ============================================================
set -euo pipefail

OUTPUT=/output/bt
REPO_URL="https://github.com/lwfinger/rtl8723bs_bt.git"
SRC_DIR=$(mktemp -d)

echo "=== rtk_hciattach build ==="
echo "Source : $REPO_URL"
echo "Output : $OUTPUT"
echo ""

mkdir -p "$OUTPUT"

# ---- Clone ------------------------------------------------
echo "[bt] Cloning rtl8723bs_bt..."
git clone --depth=1 "$REPO_URL" "$SRC_DIR"

# ---- Cross-compile ----------------------------------------
echo "[bt] Cross-compiling for ARM64..."
make -C "$SRC_DIR" \
    CC=aarch64-linux-gnu-gcc \
    CFLAGS="-O2 -static"

[ -f "$SRC_DIR/rtk_hciattach" ] || {
    echo "ERROR: rtk_hciattach not produced — check Makefile output above."
    exit 1
}

# ---- Save artifact ----------------------------------------
cp "$SRC_DIR/rtk_hciattach" "$OUTPUT/rtk_hciattach"
chmod 755 "$OUTPUT/rtk_hciattach"
rm -rf "$SRC_DIR"

echo ""
echo "=== rtk_hciattach build complete ==="
echo "Binary: $(ls -lh "$OUTPUT/rtk_hciattach")"
