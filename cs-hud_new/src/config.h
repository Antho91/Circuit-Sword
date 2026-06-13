#pragma once

// ============================================================
// GPIO Pin Definitions (Circuit Sword model)
// ============================================================
// On the Circuit Sword, GPIO 37 is the physical power ON/OFF switch (not the
// menu button). The menu button is reported over the serial link by the board's
// MCU (see hardware_read_mode_button / CMD_GET_STATUS bit 0). This matches the
// original cs-hud config (gpio_pin_pwrsw = 37, setting_mode = INPUT_SERIAL).
#define GPIO_PIN_PWRSW          37   // Power switch (input, switch OFF = LOW -> shutdown)
#define GPIO_PIN_WIFI           34   // WiFi enable/disable (output)
#define GPIO_PIN_CHARGING       36   // Charging indicator (input, active LOW)
#define GPIO_PIN_POWER_GOOD     38   // USB power good (input, active LOW)
#define GPIO_PIN_OVERTEMP       35   // Over-temperature fan (output)

// ============================================================
// Serial Port
// ============================================================
#define SERIAL_PORT             "/dev/ttyACM0"
#define SERIAL_BAUD             9600

// Serial commands (single-byte)
#define CMD_GET_VOLT            'c'   // Returns 2 bytes: raw ADC voltage
#define CMD_GET_VOL             'e'   // Returns 1 byte: volume %
#define CMD_SET_VOL             'E'   // Sends 1 byte: volume %
#define CMD_GET_BL              'q'   // Returns 1 byte: brightness %
#define CMD_SET_BL              'Q'   // Sends 1 byte: brightness %
#define CMD_GET_WIFI            'w'   // Returns 1 byte: wifi state
#define CMD_SET_WIFI            'W'   // Sends 1 byte: wifi state
#define CMD_GET_MUTE            'a'   // Returns 1 byte: mute state
#define CMD_SET_MUTE            'A'   // Sends 1 byte: mute state
#define CMD_GET_STATUS          's'   // Returns 1 byte: status flags
#define CMD_GET_BTN_NOW         'b'   // Returns 1 byte: current button bitmask

// ============================================================
// Battery
// ============================================================
#define BATT_VOLTAGE_MIN        3.20    // Shutdown threshold (V)
#define BATT_VOLTAGE_LOW        3.25    // Low battery warning (V)
#define BATT_VOLTAGE_MAX        4.00    // Full charge voltage (V)

// Auto-shutdown: number of CONSECUTIVE polls at/below BATT_VOLTAGE_MIN
// (while not charging) before triggering shutdown. Guards against a
// momentary voltage sag under load causing a false shutdown.
#define BATT_LOW_SHUTDOWN_COUNT 3

// ============================================================
// Fan / over-temperature (GPIO_PIN_OVERTEMP, active LOW: 0 = on, 1 = off)
// ============================================================
// GPIO 35 sits in pigpio's second bank, where the hardware-PWM and wave helpers
// don't reach, so we bit-bang a software PWM in a thread to get an intermediate
// "quiet" speed. Three tiers (off / low / high) with hysteresis on every
// transition so it can't hunt around a threshold. Temps in deg C.
#define FAN_LOW_ON_TEMP        55.0   // off  -> low   at/above this
#define FAN_OFF_TEMP           50.0   // low  -> off   below this
#define FAN_HIGH_ON_TEMP       68.0   // low  -> high  at/above this
#define FAN_HIGH_OFF_TEMP      62.0   // high -> low   below this
#define FAN_LOW_SPEED          50     // PWM duty (%) for the quiet/low setting
#define FAN_HIGH_SPEED         100    // PWM duty (%) for full speed
#define FAN_PWM_FREQ_HZ        150    // bit-bang PWM frequency, chosen by ear (50-1000 tested)
#define FAN_KICKSTART_MS       400    // full-power burst so the fan reliably starts
#define TEMP_POLL_INTERVAL_S   3      // How often to check CPU temperature

// ADC scaling constants (from original cs-hud state.h)
#define BATT_VOLTSCALE          203.5
#define BATT_DACRES             33.0
#define BATT_DACMAX             1023.0
#define BATT_RESDIVMUL          4.0
#define BATT_RESDIVVAL          1000.0

// ============================================================
// Menu appearance
// ============================================================
// Panel size as fraction of screen (0.0 - 1.0)
#define MENU_PANEL_W_RATIO      0.85f
#define MENU_PANEL_H_RATIO      0.86f   // taller panel for 3-item layout with icon tiles

#define MENU_PADDING            16
#define MENU_CORNER_RADIUS      14      // panel + item rounded corners
#define MENU_ITEM_COUNT         3       // WiFi, Volume, Brightness
#define MENU_ANIM_SPEED         8       // Overlay fade-in steps

// Fonts — tried in order until one opens successfully
#define FONT_PATH_1  "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
#define FONT_PATH_2  "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
#define FONT_PATH_3  "/usr/share/fonts/truetype/freefont/FreeSansBold.ttf"
#define FONT_PATH_4  "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf"
#define FONT_PATH_5  "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf"

// ============================================================
// Runtime paths
// ============================================================
#define RETROARCH_FIFO          "/tmp/retroarch.fifo"
// cs_battery virtual-battery kernel module parameters. cs-hud writes the live
// battery % / charging state here; the module exposes a real
// /sys/class/power_supply/cs_battery that RetroArch's in-game OSD reads.
#define CS_BATTERY_PARAM_DIR    "/sys/module/cs_battery/parameters"

// ============================================================
// Timing
// ============================================================
#define BATT_POLL_INTERVAL_S    30      // How often to poll battery (seconds)
#define VOL_POLL_INTERVAL_MS    150     // How often to sync the board volume -> ALSA
#define MENU_LOOP_DELAY_MS      16      // Menu render loop ~60fps
#define MENU_INACTIVITY_TIMEOUT_MS 30000 // Auto-close the menu after 30s idle (safety)
#define DEBOUNCE_MS             300     // Button debounce time
#define POLL_INTERVAL_MS        50      // Input poll thread tick (menu btn + power switch)
#define PWRSW_OFF_DEBOUNCE_MS   800     // Power switch must read OFF this long before shutdown
// Menu button is read with instant-on / debounced-off: the overlay opens on the
// first "pressed" read (the serial line is clean after tcflush, so a true read is
// a real press), and closes only after this many consecutive "released" reads —
// which tolerates contact bounce while the (physically flaky) button is held.
#define MENU_RELEASE_DEBOUNCE   6       // x POLL_INTERVAL_MS = ~300ms sustained release to close
