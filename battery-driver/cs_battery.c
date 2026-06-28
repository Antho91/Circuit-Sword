// SPDX-License-Identifier: GPL-2.0
/*
 * cs_battery — minimal virtual battery for the Circuit Sword.
 *
 * Registers /sys/class/power_supply/cs_battery so RetroArch's on-screen battery
 * indicator works IN-GAME. On the 64-bit KMS stack a cs-hud overlay cannot draw
 * on top of a running emulator (the emulator holds the DRM master and won't
 * yield it the way EmulationStation does), so in-game info has to come from the
 * app that is actually drawing — RetroArch's own OSD. RetroArch reads the
 * battery from /sys/class/power_supply, which is a kernel-only class; userspace
 * can't create one. The cs-hud daemon feeds live values by writing the module
 * parameters every poll:
 *
 *     echo 47 > /sys/module/cs_battery/parameters/capacity
 *     echo 1  > /sys/module/cs_battery/parameters/charging
 *
 * The mainline test_power module does the same job but isn't built into the RPi
 * kernels, so we ship this tiny equivalent via DKMS (rebuilds on kernel updates,
 * exactly like the WiFi driver).
 */
#include <linux/module.h>
#include <linux/init.h>
#include <linux/err.h>
#include <linux/minmax.h>
#include <linux/power_supply.h>

static int capacity = 50;          /* 0..100, written by cs-hud */
static int charging;               /* 0 = discharging, 1 = charging */
module_param(capacity, int, 0644);
MODULE_PARM_DESC(capacity, "Battery charge level 0-100 (written by cs-hud)");
module_param(charging, int, 0644);
MODULE_PARM_DESC(charging, "1 = charging, 0 = discharging (written by cs-hud)");

static enum power_supply_property cs_battery_props[] = {
	POWER_SUPPLY_PROP_PRESENT,
	POWER_SUPPLY_PROP_STATUS,
	POWER_SUPPLY_PROP_CAPACITY,
	POWER_SUPPLY_PROP_TECHNOLOGY,
	POWER_SUPPLY_PROP_SCOPE,
};

static int cs_battery_get_property(struct power_supply *psy,
				   enum power_supply_property psp,
				   union power_supply_propval *val)
{
	switch (psp) {
	case POWER_SUPPLY_PROP_PRESENT:
		val->intval = 1;
		break;
	case POWER_SUPPLY_PROP_STATUS:
		val->intval = charging ? POWER_SUPPLY_STATUS_CHARGING
				       : POWER_SUPPLY_STATUS_DISCHARGING;
		break;
	case POWER_SUPPLY_PROP_CAPACITY:
		val->intval = clamp(capacity, 0, 100);
		break;
	case POWER_SUPPLY_PROP_TECHNOLOGY:
		val->intval = POWER_SUPPLY_TECHNOLOGY_LIPO;
		break;
	case POWER_SUPPLY_PROP_SCOPE:
		val->intval = POWER_SUPPLY_SCOPE_SYSTEM;
		break;
	default:
		return -EINVAL;
	}
	return 0;
}

static const struct power_supply_desc cs_battery_desc = {
	.name		= "cs_battery",
	.type		= POWER_SUPPLY_TYPE_BATTERY,
	.properties	= cs_battery_props,
	.num_properties	= ARRAY_SIZE(cs_battery_props),
	.get_property	= cs_battery_get_property,
};

static struct power_supply *cs_battery_psy;

static int __init cs_battery_init(void)
{
	struct power_supply_config cfg = {};

	cs_battery_psy = power_supply_register(NULL, &cs_battery_desc, &cfg);
	if (IS_ERR(cs_battery_psy))
		return PTR_ERR(cs_battery_psy);

	pr_info("cs_battery: registered virtual battery for RetroArch OSD\n");
	return 0;
}

static void __exit cs_battery_exit(void)
{
	power_supply_unregister(cs_battery_psy);
}

module_init(cs_battery_init);
module_exit(cs_battery_exit);

MODULE_AUTHOR("Circuit Sword");
MODULE_DESCRIPTION("Virtual battery feeding RetroArch's OSD from cs-hud");
MODULE_LICENSE("GPL");
MODULE_VERSION("0.1.0");
