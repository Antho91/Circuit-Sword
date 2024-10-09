#!/bin/bash
set -e  # Stop by any error

# kernelver is not set during kernel upgrades via apt
# DPKG_MAINTSCRIPT_PACKAGE contains the kernel image or header package being upgraded
if [ -z "$kernelver" ] ; then
  echo "Using DPKG_MAINTSCRIPT_PACKAGE instead of unset kernelver"
  kernelver=$( echo $DPKG_MAINTSCRIPT_PACKAGE | sed -r 's/linux-(headers|image)-//')
fi

# Ensure that the necessary tools are installed
if ! command -v wget &> /dev/null ; then
  echo "wget could not be found. Please install wget."
  exit 1
fi

if ! command -v patch &> /dev/null ; then
  echo "patch could not be found. Please install patch."
  exit 1
fi

# Split kernel version into individual elements
vers=(${kernelver//./ })
major="${vers[0]}"
minor="${vers[1]}"
version="$major.$minor"
subver=$(grep "SUBLEVEL =" /usr/src/linux-headers-${kernelver}/Makefile | tr -d " " | cut -d "=" -f 2)

echo "Downloading kernel source $version.$subver for $kernelver"
wget https://mirrors.edge.kernel.org/pub/linux/kernel/v$major.x/linux-$version.$subver.tar.xz

echo "Extracting original source"
tar -xf linux-$version.$subver.tar.* linux-$version.$subver/$1 --xform=s,linux-$version.$subver/$1,.

# Here we apply the dynamic patch as the next step:
if [ -x /usr/local/bin/apply-dynamic-patch.sh ]; then
  echo "Applying dynamic patch to mixer.c"
  /usr/local/bin/apply-dynamic-patch.sh
else
  echo "Error: apply-dynamic-patch.sh not found or not executable!"
  exit 1
fi