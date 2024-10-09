#!/bin/bash

# File where the changes should be applied
FILE="mixer.c"

# Look for the line with USB_ID(0x0d8c, 0x0103) and remove the corresponding block
sed -i '/case USB_ID(0x0d8c, 0x0103):/,/break;/d' $FILE
