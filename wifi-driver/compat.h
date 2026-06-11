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
 * and removed in 6.15. Both names work on 6.1–6.14; only the new
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
 * kzalloc_obj(*ptr)           → kzalloc(sizeof(*ptr), GFP_KERNEL)
 * kzalloc_obj(*ptr, GFP_XXX) → kzalloc(sizeof(*ptr), GFP_XXX)
 * The two-macro trick defaults the optional gfp argument to GFP_KERNEL.
 */
#ifndef kzalloc_obj
#define __cs_kzalloc_obj(p, gfp, ...) ((typeof(&(p)))kzalloc(sizeof(p), gfp))
#define kzalloc_obj(p, ...) __cs_kzalloc_obj(p, ##__VA_ARGS__, GFP_KERNEL)
#endif

#endif /* _RTL8723BS_COMPAT_H */
