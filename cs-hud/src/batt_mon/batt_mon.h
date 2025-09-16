#ifndef BATT_MON_H
#define BATT_MON_H

//-----------------------------------------------------------------------------

#include <stdio.h>
#include <stdbool.h>
#include <stdint.h>
#include <pigpio.h>

//-----------------------------------------------------------------------------
// STATIC VARIABLES

// #define DATA_PULSE_SYNC 7000
#define DATA_PULSE_SYNC 25000
#define DATA_PULSE_THRESHOLD 9500
#define DATA_WIDTH 16
#define CHECKSUM_WIDTH 8
#define CHECKSUM_OFFSET DATA_WIDTH
#define DATA_VALID_MIN 210
#define DATA_VALID_MAX 400

//-----------------------------------------------------------------------------
// METHODS

// Init GPIOs for reading
void batt_mon_init(int data);

// Calculate 8bit CRC
uint8_t calc_crc8(uint8_t bytes[], uint8_t len);

// Get voltage
uint16_t batt_mon_voltage(void);

// Check if new data available
bool batt_mon_new_data(void);

// Cleanup / unload
void batt_mon_unload(void);

// CALLBACKS (pigpio)
void batt_mon_callback(int gpio, int level, uint32_t tick);
void batt_mon_callback_8x3(int gpio, int level, uint32_t tick);
void batt_mon_callback_16x2(int gpio, int level, uint32_t tick);

//-----------------------------------------------------------------------------

#endif
