#include "batt_mon.h"
#include <pigpio.h>

//#define DEBUG_PRINT_TIMING

//-----------------------------------------------------------------------------
// PRIVATE VARIABLES

int data_pos = -1;
uint32_t data_byte = 0;
uint16_t checksum_byte = 0;
#if defined DEBUG_PRINT_TIMING
uint32_t tmp_raw[32];
#endif

volatile uint16_t data_valid = 0;
volatile bool new_data = 0;

static uint32_t last_tick = 0;

//-----------------------------------------------------------------------------
// METHODS

// Calculate 8bit CRC
uint8_t calc_crc8(uint8_t bytes[], uint8_t len) {
    uint16_t crc = 0xFFFF;
    for (uint8_t byteIndex = 0; byteIndex < len; ++byteIndex) {
        uint8_t bit = 0x80;
        for (uint8_t bitIndex = 0; bitIndex < 8; ++bitIndex) {
            bool xorFlag = ((crc & 0x8000) == 0x8000);
            crc <<= 1;
            if (((bytes[byteIndex] & bit) ^ (uint8_t)0xff) != (uint8_t)0xff) {
                crc += 1;
            }
            if (xorFlag) {
                crc ^= 0x1021;
            }
            bit >>= 1;
        }
    }
    return (uint8_t)crc;
}

//-----------------------------------------------------------------------------
// CALLBACKS

void batt_mon_callback(int gpio, int level, uint32_t tick)
{
    uint32_t elapsed = tick - last_tick;
    last_tick = tick;

    if (elapsed > DATA_PULSE_SYNC) {
        data_pos = 0;
        data_byte = 0;
        checksum_byte = 0;
    } else if (data_pos >= 0) {
        if (data_pos < DATA_WIDTH) {
#if defined DEBUG_PRINT_TIMING
            tmp_raw[data_pos] = elapsed;
#endif
            if (elapsed < DATA_PULSE_THRESHOLD) {
                data_byte |= (1 << data_pos);
            }
            data_pos += 1;
        } else if (data_pos < DATA_WIDTH + CHECKSUM_WIDTH) {
            if (elapsed < DATA_PULSE_THRESHOLD) {
                checksum_byte |= (1 << (data_pos - CHECKSUM_OFFSET));
            }
            data_pos += 1;
            if (data_pos == DATA_WIDTH + CHECKSUM_WIDTH) {
                uint8_t tmp_crc = calc_crc8((uint8_t[]){(data_byte >> 8) & 0xFF, data_byte & 0xFF}, 2);
                if (checksum_byte == tmp_crc) {
                    data_valid = data_byte;
                    new_data = 1;
                } else {
                    printf("[!] Checksum failed! DATA:[%x] CHECKSUM:[%x] CRC:[%x]\n", data_byte, checksum_byte, tmp_crc);
#if defined DEBUG_PRINT_TIMING
                    for (uint8_t x = 0; x < 16; x++) {
                        printf("[%u]", tmp_raw[x]);
                    }
                    printf("\n");
#endif
                }
            }
        } else {
            printf("[!] Too many batt_mon_callback events\n");
        }
    }
}

void batt_mon_callback_8x3(int gpio, int level, uint32_t tick)
{
    uint32_t elapsed = tick - last_tick;
    last_tick = tick;

    if (elapsed > DATA_PULSE_SYNC) {
        data_pos = 0;
        data_byte = 0;
        checksum_byte = 0;
    } else if (data_pos >= 0) {
        if (data_pos < 24) {
#if defined DEBUG_PRINT_TIMING
            tmp_raw[data_pos] = elapsed;
#endif
            if (elapsed < DATA_PULSE_THRESHOLD) {
                data_byte |= (1 << data_pos);
            }
            data_pos += 1;

            if (data_pos == 24) {
                uint8_t a = (uint8_t)((data_byte >> 0) & 0xFF);
                uint8_t b = (uint8_t)((data_byte >> 8) & 0xFF);
                uint8_t c = (uint8_t)((data_byte >> 16) & 0xFF);
                if (a == b && a == c) {
                    data_valid = a;
                    new_data = 1;
                } else {
                    printf("[!] Checksum failed! [%x]\n", data_byte);
#if defined DEBUG_PRINT_TIMING
                    for (uint8_t x = 0; x < 24; x++) {
                        printf("[%u]", tmp_raw[x]);
                    }
                    printf("\n");
#endif
                }
            }
        } else {
            printf("[!] Too many batt_mon_callback events\n");
        }
    }
}

void batt_mon_callback_16x2(int gpio, int level, uint32_t tick)
{
    uint32_t elapsed = tick - last_tick;
    last_tick = tick;

    if (elapsed > DATA_PULSE_SYNC) {
        data_pos = 0;
        data_byte = 0;
        checksum_byte = 0;
    } else if (data_pos >= 0) {
        if (data_pos < 32) {
#if defined DEBUG_PRINT_TIMING
            tmp_raw[data_pos] = elapsed;
#endif
            if (elapsed < DATA_PULSE_THRESHOLD) {
                data_byte |= (1 << data_pos);
            }
            data_pos += 1;

            if (data_pos == 32) {
                uint16_t a = (uint16_t)((data_byte >> 0) & 0xFFFF);
                uint16_t b = (uint16_t)((data_byte >> 16) & 0xFFFF);
                if (a == b) {
                    if (a >= DATA_VALID_MIN && a <= DATA_VALID_MAX) {
                        data_valid = a;
                        new_data = 1;
                    } else {
                        printf("[!] Data out of range! [%x]\n", data_byte);
                    }
                } else {
                    printf("[!] Checksum failed! [%x]\n", data_byte);
#if defined DEBUG_PRINT_TIMING
                    for (uint8_t x = 0; x < 32; x++) {
                        printf("[%u]", tmp_raw[x]);
                    }
                    printf("\n");
#endif
                }
            }
        } else {
            printf("[!] Too many batt_mon_callback events\n");
        }
    }
}

//-----------------------------------------------------------------------------
// PUBLIC METHODS

uint16_t batt_mon_voltage()
{
    if (data_valid > 0) {
        return (uint16_t)((uint32_t)((uint32_t)1100 * (uint32_t)1023) / data_valid);
    } else {
        return 0;
    }
}

bool batt_mon_new_data()
{
    if (new_data) {
        new_data = 0;
        return true;
    } else {
        return false;
    }
}

void batt_mon_init(int pin_data)
{
    printf("[*] batt_mon_init..\n");

    gpioSetMode(pin_data, PI_INPUT);
    gpioSetPullUpDown(pin_data, PI_PUD_UP);

    last_tick = gpioTick();

    gpioSetISRFunc(pin_data, FALLING_EDGE, 0, batt_mon_callback_16x2);
}

void batt_mon_unload()
{
    printf("[*] batt_mon_unload (TODO!)..\n");
}
