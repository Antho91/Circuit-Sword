#!/bin/bash

# File where the changes should be applied
FILE="mixer.c"

# Check if the specific USB_ID block exists before attempting to remove it
if grep -q "case USB_ID(0x0d8c, 0x0103):" "$FILE"; then
  echo "Removing block for USB_ID(0x0d8c, 0x0103) in $FILE"
  
  # Use sed to remove the block starting from "case USB_ID(0x0d8c, 0x0103):" to the next "break;"
  # This approach is dynamic and doesn't depend on line numbers.
  sed -i '/case USB_ID(0x0d8c, 0x0103):/,/break;/d' "$FILE"
else
  echo "No block found for USB_ID(0x0d8c, 0x0103) in $FILE"
fi