#!/bin/bash
 
# Auto-create a RetroPie image for Raspberry Pi (Bookworm)
echo "Ensure at least 8GB of free storage (workspace + final image)."
 
# Step 1: Clone RetroPie-Setup repository
echo "Cloning RetroPie-Setup..."
git clone -b fb_image_sh_bookworm_aarch64 --depth 1 https://github.com/Gemba/RetroPie-Setup.git rp_build_image
cd rp_build_image
 
# Step 2: Install dependencies
echo "Installing dependencies..."
sudo ./retropie_packages.sh image depends
 
# Step 3: Set platform & distribution
arm64="1"  # 1 = 64-bit (aarch64), 0 = 32-bit (armhf)
dist="bookworm"
platform="rpi3"  # Adjust for your Raspberry Pi model
 
# Update config based on architecture
[[ "$arm64" -eq 1 ]] && sed -i "s/_armhf_/_arm64_/" "scriptmodules/admin/image/dists/rpios-$dist.ini" || sed -i "s/_arm64_/_armhf_/" "scriptmodules/admin/image/dists/rpios-$dist.ini"
 
# Step 4: Create chroot image
echo "Creating chroot image..."
sudo ./retropie_packages.sh image create_chroot "rpios-$dist"
 
# Step 5: Install RetroPie packages
echo "Installing RetroPie packages..."
sudo ./retropie_packages.sh image install_rp $platform "rpios-$dist"
 
# Step 6: Generate final image
echo "Creating final RetroPie image..."
sudo ./retropie_packages.sh image create "$(pwd)/tmp/build/image/rpios-$dist.img" "$(pwd)/tmp/build/image/rpios-$dist"
 
# Step 7: Done!
echo "RetroPie image created: $(pwd)/tmp/build/image/rpios-$dist.img"
echo "Flash it to an SD card using dd, Raspberry Pi Imager, or Etcher."
echo "Installation complete! Enjoy RetroPie!"
