#!/bin/bash

# Bestand waar de wijziging moet worden toegepast
FILE="mixer.c"

# Zoek naar de regel met USB_ID(0x0d8c, 0x0103) en verwijder het bijbehorende blok
sed -i '/case USB_ID(0x0d8c, 0x0103):/,/break;/d' $FILE
