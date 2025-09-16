# How to build your own IMG
Good luck! (Just joking…)
***
Some basic stuff and knowledge is needed
- Create a Ubuntu VM. I've tried countless hours with Debian, until I hit a roadblock. UBUNTU was stable (your experience may vary)
- Some hours (I think 5)
### So
---
> REMARK: if you have questions about the retropie repo plz ask the creator at: https://retropie.org.uk/forum/topic/36915/howto-create-a-bookworm-retropie-image-hands-free

1. Copy my repo locally
2. Run  `sudo ./1_build_retropie.sh`
> If you have run the `1_build_retropie.sh` Check if you dont get `Loop device not found` In step 5

Most of the time I got this error and then you need to run `sudo ./retropie_packages.sh image create "$(pwd)/tmp/build/image/rpios-bookworm.img" "$(pwd)/tmp/build/image/rpios-bookworm"` again.

3. After that, copy the `rpios-bookworm.img` out of `rp_build_image/tmp/build/image` and place it in your root directory (where you copied the repo)
4. Now run `sudo ./2_upgrade_patch_kernel_64bit.sh`
5. Rename the IMG to `rpios-bookworm64bit.img`
6. Run `sudo ./3_install_additional_software.sh`

Done! You just built your own IMG!!