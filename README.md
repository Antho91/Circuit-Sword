# Circuit Sword Software
Power management and safe shutdown software for the Circuit Sword. Running on Bookworm with a 64bit kernel

# Installation
1. After flashing the IMG to the SD, you need to paste the `custom.toml` on your SD card. In the custom.toml you need to add your WIFI credentials. 
2. Now you can put the SD card in the Game-boy. And let it boot.
3. After boot, connect with a SSH connection (like putty or taby) and run `sudo raspi-config` now you need to expand the root partition.
4. After the reboot connect one more time and run : `sudo apt update sudo apt install libraspberrypi0 libraspberrypi-dev libraspberrypi-bin` this should fix the CS-HUD service dependencies.

# Things to do
- Create a new DKMS for the Wi-Fi

# Things broken (if you have spare time, please help me out ;))
- GPU crashes after exiting the emulator. A full reboot is needed.
- The CS-HUD battery HUD (where we could see the overlay info), no longer works due to the implementation of KMS. Maybe we can create a game (emulation) overlay (I haven’t explored this)

# When will I fix these issues?
- To be honest I dont know when those issues are being addressed. I dont have that much time and my knowledge is also not up to date for this :). I just hacked this together in my spare time.

## Other Downloads
- [Latest 1.4.x releases](https://github.com/weese/Circuit-Sword/releases)
- [Kite's 1.3.x releases](https://github.com/kiteretro/Circuit-Sword/releases)
