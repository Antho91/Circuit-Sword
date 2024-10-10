#!/bin/bash

if [ "$EUID" -ne 0 ]
  then echo "Please run as root (sudo)"
  exit 1
fi

if [ $# != 3 ] ; then
  echo "Usage: ./<cmd> YES [fat32 root] [ext4 root]"
  exit 1
fi

#####################################################################
# Vars

if [[ $2 != "" ]] ; then
  DESTBOOT=$2
else
  DESTBOOT="/boot"
fi

if [[ $3 != "" ]] ; then
  DEST=$3
else
  DEST=""
fi
KERNEL=kernel7

#####################################################################
# Functions
execute() { #STRING
  if [ $# != 1 ] ; then
    echo "ERROR: No args passed"
    exit 1
  fi
  cmd=$1
  
  echo "[*] EXECUTE: [$cmd]"
  eval "$cmd"
  ret=$?
  
  if [ $ret != 0 ] ; then
    echo "ERROR: Command exited with [$ret]"
    exit 1
  fi
  
  return 0
}

#####################################################################
# LOGIC!
echo "INSTALL KERNEL.."

execute "cp config /build/images/"

execute "cp $DESTBOOT/$KERNEL.img $DESTBOOT/$KERNEL-backup.img"
execute "cp pi/zImage $DESTBOOT/$KERNEL.img"
execute "cp pi/*.dtb $DESTBOOT/"
# execute "rm $DESTBOOT/overlays/*"
execute "cp pi/overlays/*.dtb* $DESTBOOT/overlays/"
execute "cp pi/overlays/README $DESTBOOT/overlays/"

# Copy modules and headers to the appropriate locations
# Ensure that the necessary directories exist
execute "mkdir -p $DEST/lib/modules/"
execute "mkdir -p /lib/modules/$(uname -r)/build"

# Install the kernel modules from the compiled kernel
execute "rsync -avh --delete modules/lib/modules/* $DEST/lib/modules/"

# Optionally, if you want to copy headers as well
execute "cp -r /usr/src/linux-headers-$(uname -r) $DEST/lib/modules/$(uname -r)/build"


#####################################################################
# DONE
echo "DONE!"
