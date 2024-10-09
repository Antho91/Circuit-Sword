#!/bin/bash

# Driver locatie on GitHub
GITHUB_URL="https://github.com/raspberrypi/linux/archive/refs/heads/rpi-6.6.y.zip"

# Download the sourcode
wget $GITHUB_URL -O /tmp/rpi-6.6.y.zip

# Extract the zip file
unzip /tmp/rpi-6.6.y.zip -d /tmp/

# Copy the necessary files to the DKMS build directory
cp -r /tmp/linux-rpi-6.6.y/sound/usb/* /usr/src/usb-sound-1.0/

# Remove temporary files
rm -rf /tmp/rpi-6.6.y.zip /tmp/linux-rpi-6.6.y
