# Create a Raspberry Pi Image with F2FS Root

A script that automatically converts an image to an f2fs root.
Tested on `Ubuntu 24.04 x86_64` with the conversion of the `2025-05-13-raspios-bookworm-arm64-lite` image.

Usage: `sudo bash rpi-f2fs.bash 2025-05-13-raspios-bookworm-arm64-lite.img 2025-05-13-raspios-bookworm-arm64-lite-f2fs.img`

- ✅ Auto expanding root partition
