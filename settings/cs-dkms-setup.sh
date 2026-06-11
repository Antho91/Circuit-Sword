#!/bin/bash
# Register RTL8723BS with DKMS and install the postinst hook.
#
# The driver source is pre-installed at /usr/src/rtl8723bs-1.0.0/ by the
# image builder (from mainline staging, with compat.h shims).
# The pre-compiled .ko already covers the custom kernel.
#
# AUTOINSTALL=yes in dkms.conf means DKMS recompiles automatically when
# apt installs a new raspberrypi-kernel + raspberrypi-kernel-headers.
# The postinst hook (cs-dkms-refresh, sorts before 'dkms') refreshes
# compat.h before each autoinstall so API shims stay current.
set -e

WIFI_NAME="rtl8723bs"
WIFI_VER="1.0.0"
SRC="/usr/src/${WIFI_NAME}-${WIFI_VER}"
HOOK="/etc/kernel/postinst.d/cs-dkms-refresh"

log() { echo "[cs-dkms] $*"; logger -t cs-dkms "$*" 2>/dev/null || true; }

# ── Section 1: install/refresh the postinst hook (always, unconditionally) ──
mkdir -p /etc/kernel/postinst.d
cat > "$HOOK" << 'HOOKEOF'
#!/bin/bash
# /etc/kernel/postinst.d/cs-dkms-refresh
# Refresh RTL8723BS compat.h shims before dkms autoinstall runs.
# Sorts before 'dkms' alphabetically so it always runs first.
set -e
KVER="$1"
SRC="/usr/src/rtl8723bs-1.0.0"
log() { echo "[cs-dkms-refresh] $*"; logger -t cs-dkms-refresh "$*" 2>/dev/null || true; }

[ -d "$SRC" ] || { log "source not found — skip"; exit 0; }

log "Refreshing compat.h for kernel $KVER ..."

cat > "$SRC/compat.h" << 'COMPATEOF'
/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Compatibility shim for RTL8723BS out-of-tree DKMS build.
 * Included via ccflags-y in Kbuild so all .c files get it.
 */
#ifndef _RTL8723BS_COMPAT_H
#define _RTL8723BS_COMPAT_H

#include <linux/version.h>

/*
 * del_timer_sync() was renamed to timer_delete_sync() in kernel 6.1
 * and removed in 6.15. Both names work on 6.1-6.14; only the new
 * name works on 6.15+.
 */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 15, 0)
#define del_timer_sync(t) timer_delete_sync(t)
#endif

/*
 * from_timer() was renamed to timer_container_of() in kernel 6.15
 * and removed. Both names are equivalent (same container_of logic).
 */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 15, 0)
#define from_timer(var, callback_timer, timer_fieldname) \
	timer_container_of(var, callback_timer, timer_fieldname)
#endif

/*
 * kzalloc_obj() was added in kernel 6.15 as a type-safe kzalloc wrapper.
 * kzalloc_obj(*ptr)           -> kzalloc(sizeof(*ptr), GFP_KERNEL)
 * kzalloc_obj(*ptr, GFP_XXX) -> kzalloc(sizeof(*ptr), GFP_XXX)
 * Only shim it for OLDER kernels. On 6.15+ the kernel provides it; because this
 * header is force-included (before slab.h) a plain #ifndef would always fire and
 * then clash with the real macro ("kzalloc_obj redefined" warnings on 6.18).
 */
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 15, 0)
#define __cs_kzalloc_obj(p, gfp, ...) ((typeof(&(p)))kzalloc(sizeof(p), gfp))
#define kzalloc_obj(p, ...) __cs_kzalloc_obj(p, ##__VA_ARGS__, GFP_KERNEL)
#endif

#endif /* _RTL8723BS_COMPAT_H */
COMPATEOF

grep -q 'compat.h' "$SRC/Kbuild" 2>/dev/null \
    || echo 'ccflags-y += -include $(src)/compat.h' >> "$SRC/Kbuild"

log "Done — compat.h refreshed for kernel $KVER"
exit 0
HOOKEOF
chmod +x "$HOOK"
log "postinst hook installed: $HOOK"

# ── Section 2: verify kernel scripts are usable ─────────────────────────────
# The kernel is built in an ARM64 Docker container (Apple Silicon), so
# scripts/mod/modpost and scripts/basic/fixdep are already ARM64 binaries —
# no recompilation needed. Just verify they run. Do NOT run 'make scripts_prepare'
# as it needs Kconfig files (not in the headers package) and would delete autoconf.h.
KVER=$(uname -r)
HEADERS_DIR="/usr/src/linux-headers-${KVER}"
MODPOST="${HEADERS_DIR}/scripts/mod/modpost"

if [ -d "$HEADERS_DIR" ]; then
    if "$MODPOST" --version >/dev/null 2>&1; then
        log "Kernel scripts OK (ARM64 native)"
    else
        log "WARNING: $MODPOST not runnable — DKMS build may fail"
    fi
    if [ ! -f "${HEADERS_DIR}/include/generated/autoconf.h" ]; then
        log "WARNING: autoconf.h missing — DKMS build will fail"
    fi
else
    log "WARNING: $HEADERS_DIR not found — DKMS build will fail without headers"
fi

# ── Section 3: register with DKMS ───────────────────────────────────────────
if ! command -v dkms >/dev/null 2>&1; then
    log "dkms not installed yet — will register once cs-firstboot-packages completes"
    exit 0
fi

[ -d "$SRC" ] || { log "ERROR: $SRC not found — image build incomplete"; exit 1; }

if dkms status "${WIFI_NAME}/${WIFI_VER}" 2>/dev/null | grep -q "^${WIFI_NAME}"; then
    log "Already registered — nothing to do"
    touch /var/lib/cs-dkms-firstboot.done
    exit 0
fi

log "Registering ${WIFI_NAME}/${WIFI_VER}..."
dkms add "${WIFI_NAME}/${WIFI_VER}"
log "Done — DKMS AUTOINSTALL handles future kernel updates automatically"
touch /var/lib/cs-dkms-firstboot.done
