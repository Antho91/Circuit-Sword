#pragma once

#include <stdbool.h>
#include <stdint.h>

// Snapshot of all hardware state
typedef struct {
    double  batt_voltage;   // Battery voltage in Volts
    int     batt_percent;   // Battery percentage (0-100)
    bool    charging;       // True if USB power + charging
    bool    power_good;     // True if USB power present
    int     volume;         // Volume percentage (0-100), -1 = unknown
    int     brightness;     // Brightness percentage (0-100), -1 = unknown
    bool    wifi_enabled;   // WiFi on/off
    int     wifi_signal;    // WiFi signal quality (0-100)
    bool    muted;          // Mute state
} cs_hw_state_t;

// Lifecycle
int  hardware_init(void);
// Serial-only init for the standalone `cs-hud --menu` helper (no pigpio — the
// daemon owns it). See hardware.c.
int  hardware_init_serial_only(void);
void hardware_cleanup(void);

// Battery
double hardware_read_battery_voltage(void);
int    hardware_voltage_to_percent(double voltage);
bool   hardware_read_charging(void);
bool   hardware_read_power_good(void);

// Power switch (GPIO 37): true = switch in the ON position, false = OFF.
bool   hardware_read_power_switch(void);

// CPU temperature in degrees Celsius (reads /sys/class/thermal). <0 on error.
double hardware_read_cpu_temp(void);

// Fan control (GPIO_PIN_OVERTEMP, active LOW). true = full on, false = off.
// Thin wrapper around hardware_set_fan_speed (0 or FAN_HIGH_SPEED).
void   hardware_set_fan(bool on);

// Fan speed 0..100%. 0 = off, 100 = full on (static pin), anything in between
// runs a bit-banged software-PWM thread on GPIO 35 (with a kickstart burst when
// spinning up from a stop). Safe to call repeatedly; only the poll thread does.
void   hardware_set_fan_speed(int percent);

// Menu/mode button, reported by the board's MCU over serial (CMD_GET_STATUS
// bit 0). true = currently pressed. Returns false if no board is attached.
bool   hardware_read_mode_button(void);

// Power supply sysfs emulation (for EmulationStation / RetroArch battery indicator)
void hardware_write_power_supply(int percent, bool charging);

// Send a command to RetroArch via its FIFO (e.g. "SAVE_STATE\n").
// Returns true if RetroArch was listening (i.e. a game is running), false
// otherwise — opening the FIFO write-only non-blocking only succeeds when a
// reader is attached, so this doubles as a "is a game running?" check.
bool hardware_retroarch_send(const char *cmd);

// Volume
int  hardware_get_volume(void);          // current ALSA volume (amixer sget)
void hardware_set_volume(int percent);   // set ALSA + tell the board (CMD_SET_VOL)

// Volume level the BOARD tracks (0-100), read over serial (CMD_GET_VOL). The
// hardware MODE+Up/Down combo (or an analog pot) changes this on the board; the
// daemon polls it and mirrors it to ALSA so volume works everywhere — including
// in-game, where the cs-hud overlay can't open. Returns -1 on error.
int  hardware_read_board_volume(void);

// Apply a volume % to the ALSA mixer only (no serial write-back). Used by the
// poll loop's board->ALSA sync to avoid echoing the value back to the board.
void hardware_apply_volume(int percent);

// Brightness
int  hardware_get_brightness(void);
void hardware_set_brightness(int percent);

// WiFi
bool hardware_get_wifi(void);
void hardware_set_wifi(bool enabled);
int  hardware_get_wifi_signal(void);

// Full state snapshot
cs_hw_state_t hardware_read_state(void);
