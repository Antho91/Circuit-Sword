#!/bin/bash

# Driver locatie on GitHub
GITHUB_URL="https://github.com/raspberrypi/linux/archive/refs/heads/rpi-6.6.y.zip"

# Download the sourcode
wget $GITHUB_URL -O /tmp/rpi-6.6.y.zip

# Pak het zip-bestand uit
unzip /tmp/rpi-6.6.y.zip -d /tmp/

# Kopieer de benodigde bestanden naar de DKMS-build directory
cp -r /tmp/linux-rpi-6.6.y/sound/usb/* /usr/src/usb-sound-1.0/

# Verwijder tijdelijke bestanden
rm -rf /tmp/rpi-6.6.y.zip /tmp/linux-rpi-6.6.y
