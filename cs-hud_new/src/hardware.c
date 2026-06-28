#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <termios.h>
#include <errno.h>
#include <sys/stat.h>
#include <pthread.h>
#include <pigpio.h>

#include "config.h"
#include "hardware.h"

static int serial_fd = -1;

// True once gpioInitialise() has run (i.e. the full daemon via hardware_init()).
// The standalone `cs-hud --menu` helper does NOT init pigpio (the daemon owns
// it), so every GPIO call here must be guarded — otherwise pigpio spams
// "uninitialised" warnings and the calls no-op anyway. Guarding makes the no-op
// explicit and keeps the helper's log clean.
static int g_have_pigpio = 0;

static void fan_pwm_stop(void);   // defined with the fan PWM code below

// Serialises access to the UART. The input poll thread (menu button), the
// battery poll and menu actions (volume/brightness) all talk to the board, so
// each command+response must be atomic to avoid interleaved/corrupted framing.
static pthread_mutex_t serial_mtx = PTHREAD_MUTEX_INITIALIZER;

// ============================================================
// Serial port
// ============================================================

static int serial_open(void) {
    serial_fd = open(SERIAL_PORT, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (serial_fd < 0) {
        fprintf(stderr, "[hw] Cannot open serial port %s: %s\n",
                SERIAL_PORT, strerror(errno));
        return -1;
    }

    struct termios options;
    tcgetattr(serial_fd, &options);
    cfsetispeed(&options, B9600);
    cfsetospeed(&options, B9600);

    options.c_cflag = (options.c_cflag & ~CSIZE) | CS8;
    options.c_cflag |= (CLOCAL | CREAD);
    options.c_cflag &= ~(PARENB | PARODD | CSTOPB | CRTSCTS);
    options.c_iflag &= ~(IXON | IXOFF | IXANY | IGNBRK | BRKINT |
                         PARMRK | ISTRIP | INLCR | IGNCR | ICRNL);
    options.c_lflag = 0;
    options.c_oflag = 0;
    options.c_cc[VMIN]  = 0;
    options.c_cc[VTIME] = 5;   // 0.5s read timeout

    tcflush(serial_fd, TCIFLUSH);
    tcsetattr(serial_fd, TCSANOW, &options);

    // Open used O_NONBLOCK (so it never hangs if the board is absent), but with
    // O_NONBLOCK set read() ignores VMIN/VTIME and returns immediately — so a read
    // right after writing a command sees 0 bytes before the board has replied.
    // Switch to BLOCKING now so VMIN=0/VTIME=5 actually waits up to 0.5s for the
    // reply. (This is why the 'c' voltage read returned nothing.)
    int fl = fcntl(serial_fd, F_GETFL, 0);
    if (fl != -1) fcntl(serial_fd, F_SETFL, fl & ~O_NONBLOCK);

    return 0;
}

// Send a 1-byte command and read back `len` bytes into buf.
// Returns number of bytes actually read, or -1 on error.
static int serial_cmd(char cmd, uint8_t *buf, int len) {
    if (serial_fd < 0) return -1;

    pthread_mutex_lock(&serial_mtx);
    // Discard any stale/async bytes still in the input buffer so the response we
    // read corresponds to THIS command. Without this, leftover bytes misalign the
    // read and e.g. the menu-button status bit reads as random noise.
    tcflush(serial_fd, TCIFLUSH);
    int rc;
    if (write(serial_fd, &cmd, 1) != 1) {
        rc = -1;
    } else if (len <= 0 || buf == NULL) {
        rc = 0;
    } else {
        int total = 0;
        while (total < len) {
            int n = read(serial_fd, buf + total, len - total);
            if (n <= 0) break;
            total += n;
        }
        rc = total;
    }
    pthread_mutex_unlock(&serial_mtx);
    return rc;
}

// Send a 2-byte command+value packet.
static int serial_set(char cmd, uint8_t value) {
    if (serial_fd < 0) return -1;
    uint8_t pkt[2] = {(uint8_t)cmd, value};
    pthread_mutex_lock(&serial_mtx);
    int rc = write(serial_fd, pkt, 2) == 2 ? 0 : -1;
    pthread_mutex_unlock(&serial_mtx);
    return rc;
}

// ============================================================
// Lifecycle
// ============================================================

int hardware_init(void) {
    serial_open();  // non-fatal — runs without Arduino attached

    g_have_pigpio = 1;  // gpioInitialise() ran before us (main.c) — GPIO usable

    // WiFi GPIO output
    gpioSetMode(GPIO_PIN_WIFI, PI_OUTPUT);
    gpioWrite(GPIO_PIN_WIFI, 1);

    // Status GPIO inputs
    gpioSetMode(GPIO_PIN_CHARGING,    PI_INPUT);
    gpioSetPullUpDown(GPIO_PIN_CHARGING,    PI_PUD_UP);
    gpioSetMode(GPIO_PIN_POWER_GOOD,  PI_INPUT);
    gpioSetPullUpDown(GPIO_PIN_POWER_GOOD,  PI_PUD_UP);
    gpioSetMode(GPIO_PIN_PWRSW,       PI_INPUT);
    gpioSetPullUpDown(GPIO_PIN_PWRSW,       PI_PUD_UP);

    // Fan output — start OFF (active LOW, so drive HIGH). The poll thread turns
    // it on by temperature. Without this the pin floats and the fan can run
    // continuously.
    gpioSetMode(GPIO_PIN_OVERTEMP, PI_OUTPUT);
    gpioWrite(GPIO_PIN_OVERTEMP, 1);

    return 0;
}

// Lightweight init for the standalone menu helper (`cs-hud --menu`, launched on
// its own VT via openvt). It must NOT call gpioInitialise/pigpio — the daemon
// already owns pigpio, and a second instance conflicts. Just open the serial
// line (the daemon keeps it open too, so this second fd does NOT re-toggle DTR /
// reset the Arduino). GPIO-only actions (e.g. the WiFi enable pin) are no-ops
// here; nmcli/amixer/serial actions still work.
int hardware_init_serial_only(void) {
    return serial_open();
}

void hardware_cleanup(void) {
    fan_pwm_stop();   // stop bit-banging and leave the fan pin OFF
    if (serial_fd >= 0) {
        close(serial_fd);
        serial_fd = -1;
    }
}

// ============================================================
// Battery
// ============================================================

double hardware_read_battery_voltage(void) {
    // The firmware answers 'c' with exactly 2 bytes via serialWrite2():
    // low byte first (data & 0xFF), then high byte (data >> 8). Pure
    // request/response. Retry a couple of times in case a reply is missed.
    uint16_t raw = 0;
    for (int attempt = 0; attempt < 3; attempt++) {
        uint8_t buf[2] = {0, 0};
        if (serial_cmd(CMD_GET_VOLT, buf, 2) == 2) {
            raw = (uint16_t)((buf[1] << 8) | buf[0]);   // [low][high]
            if (raw > 0 && raw <= 1023) break;
            raw = 0;
        }
        usleep(25000);   // 25ms between attempts
    }

    if (raw == 0) return 0.0;

    // Voltage calculation from original cs-hud state.c
    double v = ((double)raw * BATT_VOLTSCALE * BATT_DACRES
                + (BATT_DACMAX * 5.0))
               / ((BATT_DACRES * BATT_RESDIVVAL) / BATT_RESDIVMUL);
    return v / 100.0;
}

int hardware_voltage_to_percent(double voltage) {
    if (voltage <= BATT_VOLTAGE_MIN) return 0;
    if (voltage >= BATT_VOLTAGE_MAX) return 100;
    return (int)(((voltage - BATT_VOLTAGE_MIN) /
                  (BATT_VOLTAGE_MAX - BATT_VOLTAGE_MIN)) * 100.0);
}

bool hardware_read_charging(void) {
    // Active HIGH — charging when the pin reads 1 (matches original cs-hud:
    // chrg_state = gpioRead(pin); the charge icon shows when chrg_state is true).
    if (!g_have_pigpio) return false;   // menu helper has no GPIO
    return gpioRead(GPIO_PIN_CHARGING) != 0;
}

bool hardware_read_power_good(void) {
    // Active HIGH — USB power present when the pin reads 1 (matches original).
    if (!g_have_pigpio) return false;   // menu helper has no GPIO
    return gpioRead(GPIO_PIN_POWER_GOOD) != 0;
}

bool hardware_read_power_switch(void) {
    // Pin is pulled up: switch ON idles HIGH, switch OFF pulls it LOW.
    if (!g_have_pigpio) return true;    // menu helper: assume ON (never shut down)
    return gpioRead(GPIO_PIN_PWRSW) != 0;   // true = ON
}

double hardware_read_cpu_temp(void) {
    FILE *f = fopen("/sys/class/thermal/thermal_zone0/temp", "r");
    if (!f) return -1.0;
    double milli = 0;
    int ok = fscanf(f, "%lf", &milli);
    fclose(f);
    if (ok != 1) return -1.0;
    double c = milli / 1000.0;
    if (c <= 0 || c > 160) return -1.0;   // implausible reading
    return c;
}

// --- Software PWM for the fan ---------------------------------------------
// GPIO 35 is in pigpio's second bank (>31), where gpioPWM and the wave helpers
// don't reach — they only drive GPIO 0-31. So we bit-bang the PWM ourselves in
// a small thread. Active LOW: pin LOW = fan powered, HIGH = fan off.
//   duty 0   -> thread stopped, pin held HIGH (off)
//   duty 100 -> thread stopped, pin held LOW  (full on)
//   1..99    -> thread loops, LOW for `duty`% of each period, HIGH for the rest
static pthread_t    fan_pwm_tid;
static volatile int fan_pwm_run    = 0;   // 1 while the PWM thread should keep looping
static volatile int fan_pwm_duty   = 0;   // target fan power 0..100 (read each period)
static int          fan_pwm_active = 0;   // is the thread currently created?

static void *fan_pwm_thread(void *arg) {
    (void)arg;
    const long period_us = 1000000L / FAN_PWM_FREQ_HZ;
    while (fan_pwm_run) {
        int  duty   = fan_pwm_duty;                 // snapshot (may change live)
        long on_us  = period_us * duty / 100;       // time the fan is POWERED (LOW)
        long off_us = period_us - on_us;
        if (on_us > 0) {
            gpioWrite(GPIO_PIN_OVERTEMP, 0);        // fan on
            usleep(on_us);
        }
        if (off_us > 0) {
            gpioWrite(GPIO_PIN_OVERTEMP, 1);        // fan off
            usleep(off_us);
        }
    }
    gpioWrite(GPIO_PIN_OVERTEMP, 1);                // leave it OFF when we stop
    return NULL;
}

static void fan_pwm_stop(void) {
    if (fan_pwm_active) {
        fan_pwm_run = 0;
        pthread_join(fan_pwm_tid, NULL);
        fan_pwm_active = 0;
    }
}

static void fan_pwm_start(void) {
    if (!fan_pwm_active) {
        fan_pwm_run = 1;
        if (pthread_create(&fan_pwm_tid, NULL, fan_pwm_thread, NULL) == 0)
            fan_pwm_active = 1;
        else
            fan_pwm_run = 0;
    }
}

void hardware_set_fan_speed(int percent) {
    static int last_pct = 0;
    if (!g_have_pigpio) return;   // menu helper doesn't drive the fan
    if (percent < 0)   percent = 0;
    if (percent > 100) percent = 100;

    if (percent == 0) {                 // off
        fan_pwm_stop();
        gpioWrite(GPIO_PIN_OVERTEMP, 1);
        last_pct = 0;
        return;
    }
    if (percent >= 100) {               // full on (static, no PWM)
        fan_pwm_stop();
        gpioWrite(GPIO_PIN_OVERTEMP, 0);
        last_pct = 100;
        return;
    }

    // Intermediate speed via bit-banged PWM. Spinning up from a full stop, give
    // the fan a brief full-power kickstart — small fans often won't start at a
    // low duty cycle. (Blocks the caller for FAN_KICKSTART_MS, but this only
    // happens on the off->low transition, which is rare.)
    if (last_pct == 0) {
        gpioWrite(GPIO_PIN_OVERTEMP, 0);
        usleep(FAN_KICKSTART_MS * 1000);
    }
    fan_pwm_duty = percent;
    fan_pwm_start();
    last_pct = percent;
}

void hardware_set_fan(bool on) {
    hardware_set_fan_speed(on ? FAN_HIGH_SPEED : 0);
}

bool hardware_read_mode_button(void) {
    // The board reports button state over serial. CMD_GET_STATUS returns a
    // single byte; bit 0 is the MODE/menu button (see original cs-hud state.c).
    uint8_t st = 0;
    if (serial_cmd(CMD_GET_STATUS, &st, 1) < 1)
        return false;
    return (st & (1 << 0)) != 0;
}

void hardware_write_power_supply(int percent, bool charging) {
    // Feed the cs_battery virtual-battery kernel module, which exposes a real
    // /sys/class/power_supply/cs_battery that RetroArch's in-game OSD reads.
    // (Userspace can't create a power_supply, and the cs-hud overlay can't draw
    // over a running emulator on KMS — so in-game battery comes from RetroArch's
    // own OSD fed by this module.) Writes silently no-op when the module isn't
    // loaded (e.g. the transient first-boot custom kernel).
    FILE *f;

    f = fopen(CS_BATTERY_PARAM_DIR "/capacity", "w");
    if (f) { fprintf(f, "%d\n", percent); fclose(f); }

    f = fopen(CS_BATTERY_PARAM_DIR "/charging", "w");
    if (f) { fprintf(f, "%d\n", charging ? 1 : 0); fclose(f); }
}

bool hardware_retroarch_send(const char *cmd) {
    // O_WRONLY | O_NONBLOCK on a FIFO returns ENXIO when no reader is attached,
    // so a successful open means RetroArch is running and reading commands.
    int fd = open(RETROARCH_FIFO, O_WRONLY | O_NONBLOCK);
    if (fd < 0) return false;
    write(fd, cmd, strlen(cmd));
    close(fd);
    return true;
}

// ============================================================
// Volume
// ============================================================

int hardware_get_volume(void) {
    char buf[256];
    int volume = -1;

    FILE *fp = popen("amixer sget PCM 2>/dev/null", "r");
    if (!fp) return -1;

    while (fgets(buf, sizeof(buf), fp)) {
        char *p = strstr(buf, "[");
        if (p && strstr(p, "%]")) {
            if (sscanf(p, "[%d%%]", &volume) == 1)
                break;
        }
    }
    pclose(fp);
    return volume;
}

// Apply a volume % to the ALSA mixer only. The default mixer (set by
// /etc/asound.conf) is the USB sound card, whose playback control is 'PCM'
// (verified via `amixer scontrols`). No serial write-back here.
void hardware_apply_volume(int percent) {
    if (percent < 0)   percent = 0;
    if (percent > 100) percent = 100;

    char cmd[64];
    snprintf(cmd, sizeof(cmd),
             "amixer sset PCM %d%% >/dev/null 2>&1", percent);
    system(cmd);
}

void hardware_set_volume(int percent) {
    if (percent < 0)   percent = 0;
    if (percent > 100) percent = 100;

    hardware_apply_volume(percent);          // ALSA
    serial_set(CMD_SET_VOL, (uint8_t)percent); // keep the board's value in sync
}

int hardware_read_board_volume(void) {
    // The board answers 'e' with a single byte: its volume 0-100. This is the
    // value the MODE+Up/Down hardware combo (or an analog pot) changes.
    uint8_t v = 0;
    if (serial_cmd(CMD_GET_VOL, &v, 1) < 1)
        return -1;
    if (v > 100)
        return -1;   // implausible / framing error
    return (int)v;
}

// ============================================================
// Brightness
// ============================================================

int hardware_get_brightness(void) {
    uint8_t val = 0;
    if (serial_cmd(CMD_GET_BL, &val, 1) < 1)
        return -1;
    return (int)val;
}

void hardware_set_brightness(int percent) {
    if (percent < 5)   percent = 5;    // avoid completely dark screen
    if (percent > 100) percent = 100;
    serial_set(CMD_SET_BL, (uint8_t)percent);
}

// ============================================================
// WiFi
// ============================================================

bool hardware_get_wifi(void) {
    char buf[256];
    bool enabled = false;

    FILE *fp = popen("rfkill list wlan 2>/dev/null", "r");
    if (!fp) return false;

    while (fgets(buf, sizeof(buf), fp)) {
        if (strstr(buf, "Soft blocked: no")) {
            enabled = true;
            break;
        }
    }
    pclose(fp);
    return enabled;
}

void hardware_set_wifi(bool enabled) {
    // rfkill + the board's serial flag do the real work; GPIO_PIN_WIFI is only
    // touched when we own pigpio (the daemon). In the menu helper the GPIO write
    // is skipped — rfkill already toggles the radio.
    if (enabled) {
        system("rfkill unblock wlan >/dev/null 2>&1");
        if (g_have_pigpio) gpioWrite(GPIO_PIN_WIFI, 1);
    } else {
        system("rfkill block wlan >/dev/null 2>&1");
        if (g_have_pigpio) gpioWrite(GPIO_PIN_WIFI, 0);
    }
    serial_set(CMD_SET_WIFI, enabled ? 1 : 0);
}

int hardware_get_wifi_signal(void) {
    char buf[256];
    FILE *fp = fopen("/proc/net/wireless", "r");
    if (!fp) return 0;

    // Skip two header lines
    if (!fgets(buf, sizeof(buf), fp)) { fclose(fp); return 0; }
    if (!fgets(buf, sizeof(buf), fp)) { fclose(fp); return 0; }

    int signal = 0;
    while (fgets(buf, sizeof(buf), fp)) {
        if (strncmp(buf + strspn(buf, " "), "wlan0", 5) == 0) {
            int status;
            float link, level, noise;
            if (sscanf(buf, " wlan0: %d %f. %f. %f.",
                       &status, &link, &level, &noise) >= 2) {
                // link quality is 0-70 on most drivers; normalise to 0-100
                signal = (int)((link / 70.0f) * 100.0f);
                if (signal > 100) signal = 100;
            }
            break;
        }
    }
    fclose(fp);
    return signal;
}

// ============================================================
// Full state snapshot
// ============================================================

cs_hw_state_t hardware_read_state(void) {
    cs_hw_state_t s;
    memset(&s, 0, sizeof(s));

    s.batt_voltage  = hardware_read_battery_voltage();
    s.batt_percent  = hardware_voltage_to_percent(s.batt_voltage);
    s.charging      = hardware_read_charging();
    s.power_good    = hardware_read_power_good();
    s.volume        = hardware_get_volume();
    s.brightness    = hardware_get_brightness();
    s.wifi_enabled  = hardware_get_wifi();
    s.wifi_signal   = hardware_get_wifi_signal();

    return s;
}
