#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <time.h>
#include <pigpio.h>

#include "config.h"
#include "hardware.h"
#include "menu.h"

static volatile int g_running      = 1;
static volatile int g_menu_request = 0;
// Set by the main loop while the menu helper (a SEPARATE `cs-hud --menu` process
// on its own VT) is up. poll_thread parks itself — completely off the serial
// line — so the two processes never read /dev/ttyACM0 at the same time. The
// helper owns the serial during that window.
static volatile int g_menu_active  = 0;
// poll_thread sets this once it has observed g_menu_active and parked at the top
// of its loop (no serial op in flight). The main loop waits for it before
// launching the helper, closing the hand-off race.
static volatile int g_poll_parked  = 0;
// Debounced menu-button state, owned by poll_thread. Kept here for the rising-
// edge open logic (and the legacy extern in menu.c).
volatile int g_menu_btn_down       = 0;

// ============================================================
// Signal handler
// ============================================================

static void signal_handler(int sig) {
    (void)sig;
    g_running = 0;
}

// ============================================================
// Shutdown
// ============================================================

// Graceful power-off, triggered either by the power switch going OFF or by a
// critically low battery.
//   - If a game is running, ask RetroArch to save a state and give it time to
//     flush to disk before powering off.
//   - On low battery with no game running, show an on-screen warning first.
//   - Run /opt/cs_shutdown.sh if present (signals the board) then shutdown.
static void do_shutdown(bool low_battery) {
    printf("[cs-hud] shutdown requested (%s)\n",
           low_battery ? "low battery" : "power switch");

    bool game = hardware_retroarch_send("SAVE_STATE\n");
    if (game) {
        printf("[cs-hud] game running — sent SAVE_STATE, waiting for flush\n");
        sleep(3);
    } else if (low_battery) {
        printf("[cs-hud] no game running — showing warning\n");
        menu_show_warning("LOW BATTERY", "Shutting down...", 4);
    }

    sync();
    if (access("/opt/cs_shutdown.sh", X_OK) == 0)
        system("sudo /opt/cs_shutdown.sh");
    system("sudo /sbin/shutdown -h now");
}

// ============================================================
// Input + battery poll thread
//   - menu button (serial, CMD_GET_STATUS bit 0) -> g_menu_request on press
//   - power switch (GPIO 37)                     -> shutdown when held OFF
//   - battery voltage (every BATT_POLL_INTERVAL_S) -> power-supply + low-batt
// ============================================================

static void *poll_thread(void *arg) {
    (void)arg;

    bool menu_btn_down  = false;   // debounced button state (debounced both ways)
    int  menu_true_cnt  = 0;       // consecutive "pressed" reads (open debounce)
    int  menu_false_cnt = 0;       // consecutive "released" reads
    bool pwrsw_seen_on  = false;   // only honour OFF after we've seen ON
    int  pwrsw_off_ms   = 0;
    int  batt_timer_ms  = BATT_POLL_INTERVAL_S * 1000; // poll once immediately
    int  low_count      = 0;
    int  shutdown_armed = 1;       // one-shot guard
    int  temp_timer_ms  = TEMP_POLL_INTERVAL_S * 1000; // check once immediately
    int  fan_on         = 0;       // 0 = off, 1 = full on (steady DC, no PWM)
    int  vol_timer_ms   = 0;       // board-volume -> ALSA sync timer
    int  last_vol       = -1;      // last board volume mirrored to ALSA

    while (g_running) {
        // --- Park while the menu helper owns the display + serial ---
        // The menu now runs as a separate `cs-hud --menu` process (own VT, so it
        // can become DRM master). Two processes must not read /dev/ttyACM0 at
        // once, so we go fully idle here until the helper exits. We deliberately
        // do NOT update menu_btn_down: the button is held when the helper opens,
        // and keeping menu_btn_down=true means that holding it across the close
        // produces no fresh rising edge -> no instant re-open.
        if (g_menu_active) {
            g_poll_parked = 1;
            usleep(POLL_INTERVAL_MS * 1000);
            continue;
        }
        g_poll_parked = 0;

        // --- Menu button (serial): instant-on, debounced-off ---
        // poll_thread is the SOLE serial reader of the button. The overlay opens
        // on the first "pressed" read (rising edge) and stays "down" until the
        // button has read "released" MENU_RELEASE_DEBOUNCE times in a row, which
        // rides out the contact bounce of the physical button while it's held.
        if (hardware_read_mode_button()) {
            menu_false_cnt = 0;
            // Open only after the button has read "pressed" several ticks in a
            // row, so a single noisy serial sample can't launch the menu.
            if (!menu_btn_down && ++menu_true_cnt >= MENU_PRESS_DEBOUNCE) {
                menu_btn_down = true;
                g_menu_request = 1;   // debounced rising edge opens the menu
            }
        } else {
            menu_true_cnt = 0;
            if (menu_btn_down && ++menu_false_cnt >= MENU_RELEASE_DEBOUNCE)
                menu_btn_down = false;
        }
        g_menu_btn_down = menu_btn_down ? 1 : 0;

        // --- Power switch (GPIO 37) ---
        if (hardware_read_power_switch()) {
            pwrsw_seen_on = true;
            pwrsw_off_ms  = 0;
        } else if (pwrsw_seen_on) {
            pwrsw_off_ms += POLL_INTERVAL_MS;
            if (pwrsw_off_ms >= PWRSW_OFF_DEBOUNCE_MS && shutdown_armed) {
                shutdown_armed = 0;
                do_shutdown(false);
            }
        }

        // --- Battery (every BATT_POLL_INTERVAL_S) ---
        batt_timer_ms += POLL_INTERVAL_MS;
        if (batt_timer_ms >= BATT_POLL_INTERVAL_S * 1000) {
            batt_timer_ms = 0;

            double voltage = hardware_read_battery_voltage();
            int    pct     = hardware_voltage_to_percent(voltage);
            bool   chg     = hardware_read_charging();

            hardware_write_power_supply(pct, chg);
            printf("[batt] %.2fV  %d%%  %s\n",
                   voltage, pct, chg ? "CHG" : "DCH");

            // Low-battery auto-shutdown. Only when discharging and the reading
            // is plausible (a failed serial read returns 0.0V — must not fire).
            if (!chg && voltage > 0.5 && voltage <= BATT_VOLTAGE_MIN) {
                if (++low_count >= BATT_LOW_SHUTDOWN_COUNT && shutdown_armed) {
                    shutdown_armed = 0;
                    do_shutdown(true);
                }
            } else {
                low_count = 0;
            }
        }

        // --- Fan / temperature (every TEMP_POLL_INTERVAL_S, ON/OFF + hysteresis) ---
        // The 2-wire blower must not be PWM speed-controlled (datasheet), so we
        // drive it full-on / off only:  off --[>=FAN_ON_TEMP]--> on
        //                               on  --[< FAN_OFF_TEMP]--> off
        temp_timer_ms += POLL_INTERVAL_MS;
        if (temp_timer_ms >= TEMP_POLL_INTERVAL_S * 1000) {
            temp_timer_ms = 0;
            double temp = hardware_read_cpu_temp();
            if (temp > 0) {
                int want = fan_on;
                if (!fan_on && temp >= FAN_ON_TEMP)  want = 1;
                if ( fan_on && temp <  FAN_OFF_TEMP) want = 0;
                if (want != fan_on) {
                    fan_on = want;
                    hardware_set_fan_speed(fan_on ? FAN_HIGH_SPEED : 0);
                    printf("[fan] %s (%.1f C)\n", fan_on ? "ON " : "OFF", temp);
                }
            }
        }

        // --- Volume (every VOL_POLL_INTERVAL_MS): mirror the board volume to ALSA ---
        // The MODE+Up/Down hardware combo (and an analog pot, if fitted) changes
        // the volume the board tracks. Brightness is driven by the board itself,
        // but audio is the USB card's — so the daemon must apply the board's value
        // to ALSA. This is what makes the volume buttons work everywhere, incl.
        // in-game where the overlay can't open. (Skipped while the menu helper is
        // up — poll_thread is fully parked then, so it owns the serial.)
        vol_timer_ms += POLL_INTERVAL_MS;
        if (vol_timer_ms >= VOL_POLL_INTERVAL_MS) {
            vol_timer_ms = 0;
            int bv = hardware_read_board_volume();
            if (bv >= 0 && bv != last_vol) {
                hardware_apply_volume(bv);
                printf("[vol] board %d%% -> ALSA\n", bv);
                last_vol = bv;
            }
        }

        usleep(POLL_INTERVAL_MS * 1000);
    }
    return NULL;
}

// ============================================================
// Main
// ============================================================

int main(int argc, char **argv) {
    // Line-buffer stdout so logs show up live in journalctl (otherwise printf is
    // block-buffered when stdout is a pipe and nothing appears until it fills).
    setvbuf(stdout, NULL, _IOLBF, 0);

    // --- Standalone menu mode -------------------------------------------------
    // Launched on its OWN VT (via `openvt -s -w -- cs-hud --menu`) so SDL/KMSDRM
    // can become DRM master and actually render — which the headless daemon
    // can't. Serial-only init (NO pigpio: the daemon owns it). The daemon pauses
    // its serial polling while we run. Closes on B/Cancel (see menu.c).
    // --- Input-diagnostic mode -----------------------------------------------
    // `cs-hud --inputdump` grabs the input devices and prints raw evdev codes so
    // we can map this controller's buttons/axes. No VT/SDL needed — run over SSH.
    if (argc > 1 && strcmp(argv[1], "--inputdump") == 0) {
        menu_input_dump(15);
        return 0;
    }

    if (argc > 1 && strcmp(argv[1], "--menu") == 0) {
        printf("[cs-hud-menu] starting (standalone, own VT)\n");
        hardware_init_serial_only();
        menu_show();
        hardware_cleanup();
        return 0;
    }

    printf("[cs-hud] starting\n");

    // --- pigpio ---
    // Stop pigpio from installing its own signal handlers. By default it catches
    // every signal (incl. SIGTERM and the SIGCONT systemd sends on stop) and
    // "terminates" — but doesn't exit cleanly, so systemd has to SIGKILL after a
    // 90s timeout, which would also stall shutdown/reboot. We handle SIGINT/TERM.
    gpioCfgSetInternals(gpioCfgGetInternals() | PI_CFG_NOSIGHANDLER);
    if (gpioInitialise() < 0) {
        fprintf(stderr, "[cs-hud] gpioInitialise failed\n");
        return 1;
    }

    signal(SIGINT,  signal_handler);
    signal(SIGTERM, signal_handler);

    // --- Hardware (also configures the power-switch GPIO) ---
    if (hardware_init() < 0) {
        fprintf(stderr, "[cs-hud] hardware_init failed\n");
        gpioTerminate();
        return 1;
    }

    // --- DPI backlight follows the active display ---
    // When docked to HDMI, ES runs on HDMI but the DPI panel stays driven (so it
    // never shows stuck garbage) — which means RetroPie console dialogs (audio,
    // bluetooth, …) ghost onto it. Dim the DPI backlight to its floor here so the
    // handheld panel stays dark while docked, and restore the user's brightness
    // when running on DPI again. We run before the poll thread starts, so this
    // owns the serial line. The board persists brightness in EEPROM, so we stash
    // the real value in a file to survive the dim/restore across reboots.
    {
        const char *BRIGHT_FILE = "/var/lib/cs-hud-brightness";
        char status[32] = {0};
        FILE *sf = fopen("/sys/class/drm/card0-HDMI-A-1/status", "r");
        if (sf) { if (!fgets(status, sizeof status, sf)) status[0] = 0; fclose(sf); }

        if (strncmp(status, "connected", 9) == 0) {
            int cur = hardware_get_brightness();   // user's brightness (board EEPROM)
            if (cur > 0) {
                FILE *bf = fopen(BRIGHT_FILE, "w");
                if (bf) { fprintf(bf, "%d\n", cur); fclose(bf); }
            }
            hardware_set_brightness(0);            // DPI floor (firmware min PWM)
            printf("[cs-hud] HDMI active — DPI backlight dimmed\n");
        } else {
            // Always set a valid brightness so a previous HDMI session that left
            // the board's EEPROM at 0 can never leave the handheld panel dark.
            int restore = 100;   // default if we have no saved value
            FILE *bf = fopen(BRIGHT_FILE, "r");
            if (bf) {
                int saved = -1;
                if (fscanf(bf, "%d", &saved) == 1 && saved > 0 && saved <= 100)
                    restore = saved;
                fclose(bf);
            }
            hardware_set_brightness(restore);
            printf("[cs-hud] DPI mode — brightness %d%%\n", restore);
        }
    }

    // --- Input + battery poll thread ---
    pthread_t poll_tid;
    if (pthread_create(&poll_tid, NULL, poll_thread, NULL) != 0) {
        fprintf(stderr, "[cs-hud] failed to start poll thread\n");
        // non-fatal — continue without background polling
    }

    printf("[cs-hud] running — menu via serial, power switch on GPIO %d\n",
           GPIO_PIN_PWRSW);

    // --- Main loop ---
    while (g_running) {
        if (g_menu_request) {
            g_menu_request = 0;
            printf("[cs-hud] menu button pressed — launching menu on its own VT\n");

            // Park the poll thread (off the serial line) before the helper opens
            // its own fd. Wait until poll_thread acknowledges it is idle — this
            // also waits out any in-flight serial read (e.g. a battery poll, up
            // to ~1.5s) so the hand-off is clean.
            g_menu_active = 1;
            for (int i = 0; i < 200 && !g_poll_parked; i++)
                usleep(10000);          // up to 2s for an in-flight poll to finish

            // Launch the menu on a fresh VT so SDL/KMSDRM can become DRM master
            // and actually render over ES / the running emulator. openvt -w
            // blocks until the menu process exits, then switches the VT back.
            // Output goes to a log (keeps the VT clean + lets us diagnose SDL).
            int rc = system("openvt -s -w -- /bin/sh -c "
                            "'/usr/local/bin/cs-hud --menu "
                            ">/var/log/cs-hud-menu.log 2>&1'");
            if (rc != 0)
                fprintf(stderr, "[cs-hud] openvt menu exited rc=%d\n", rc);

            g_menu_active = 0;          // resume normal polling
            printf("[cs-hud] menu closed\n");
            g_menu_request = 0;         // discard presses that arrived while open
        }
        usleep(10000); // 10 ms
    }

    // --- Shutdown ---
    printf("[cs-hud] stopping\n");
    pthread_join(poll_tid, NULL);
    hardware_cleanup();
    gpioTerminate();
    return 0;
}
