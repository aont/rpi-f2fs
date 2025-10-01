# Create a Raspberry Pi Image with an F2FS Root

This repository contains a single Bash script, [`rpi-f2fs.bash`](./rpi-f2fs.bash),
that converts an official Raspberry Pi OS image so that the root filesystem
(`rootfs`) uses the [Flash-Friendly File System (F2FS)](https://www.kernel.org/doc/html/latest/filesystems/f2fs.html)
instead of the default ext4. The script automates every step of the conversion,
including repartitioning, filesystem migration, boot configuration updates, and
the installation of F2FS tooling inside the image.

The script has been tested on **Ubuntu 24.04 (x86_64)** using the
`2025-05-13-raspios-bookworm-arm64-lite` image, but it should work on any modern
Debian-based host that provides the required tooling.

## Why switch to F2FS?

F2FS is designed for flash storage and can provide faster boot times, lower
write amplification, and better wear leveling on SD cards when compared to ext4.
This script makes it practical to try F2FS on Raspberry Pi devices without
needing to perform the migration manually.

## Key features

- ✅ Runs entirely from a single script—no manual partition editing required.
- ✅ Works on loop-mounted images; no direct SD card access needed.
- ✅ Keeps the existing boot partition intact while rebuilding the root
  partition as F2FS.
- ✅ Uses `rsync` to preserve file attributes, hard links, ACLs, extended
  attributes, and special files.
- ✅ Updates boot parameters (`cmdline.txt`) and `/etc/fstab` so the converted
  image boots correctly.
- ✅ Enables F2FS auto-resize on first boot by updating initramfs scripts.
- ✅ Cleans up loop devices and temporary mounts on completion.

## Prerequisites

The script must be executed with root privileges (either via `sudo` or as root)
because it manipulates loop devices, mounts filesystems, and installs packages.

At runtime the script ensures these Debian packages are installed, fetching any
missing ones with `apt-get`:

- `partclone`
- `f2fs-tools`
- `qemu-user-static`
- `util-linux`
- `rsync`
- `coreutils`
- `grep`

Additionally, it uses `jq` and `losetup` from `util-linux`, and binds
`/etc/resolv.conf` to allow networking inside the chroot when updating the
image.

## Usage

1. Download the Raspberry Pi OS `.img` file you want to convert (e.g.
   `2025-05-13-raspios-bookworm-arm64-lite.img`).
2. Run the script with the source image and the desired output image name:

   ```bash
   sudo bash rpi-f2fs.bash 2025-05-13-raspios-bookworm-arm64-lite.img \
        2025-05-13-raspios-bookworm-arm64-lite-f2fs.img
   ```

   The output image name can be anything you prefer. If the file already exists
   you will be prompted to confirm overwriting it.

3. Wait for the script to finish. It is verbose (`set -x`) so you can monitor
   progress. When you see `[info] Completed` the conversion is done and you can
   flash the new image to an SD card with tools like `rpi-imager`, `dd`, or
   `balenaEtcher`.

## What the script does

The script performs the following high-level steps:

1. **Namespace isolation** – re-executes itself under `unshare --mount` to avoid
   leaking mounts into the host environment.
2. **Loop device setup** – attaches both images with `losetup` and copies the
   partition table and boot partition via `dd` + `partclone.fat`.
3. **F2FS formatting** – formats the destination root partition using
   `mkfs.f2fs` while retaining the original root partition UUID.
4. **Filesystem copy** – mounts both images via `loop` offsets and synchronizes
   files using `rsync -aHAXx --delete`.
5. **Boot configuration** – updates `/etc/fstab`, initramfs first-boot scripts,
   and `cmdline.txt` so that the Pi boots the new F2FS root and uses
   `resize.f2fs` for automatic expansion.
6. **Chroot configuration** – bind-mounts `qemu-aarch64-static`, `/dev`, `/proc`,
   `/sys`, and `/etc/resolv.conf` to run `apt-get` inside the ARM image and
   install `f2fs-tools`.
7. **Cleanup** – unmounts everything, detaches loop devices, removes temporary
   directories, and prints a completion message.

## Tips and troubleshooting

- **Permission denied / loop device errors** – rerun the script with `sudo` or
  as root. Manipulating loop devices and mounts requires elevated privileges.
- **Package installation prompts** – the script uses `apt-get install -y`, so no
  interactive prompts should appear. Ensure your system has network access to
  reach the Debian repositories.
- **Disk space** – the output image temporarily occupies the same size as the
  input image. Make sure you have enough free disk space before running the
  script.
- **Canceling the script** – if you interrupt execution, rerun the script; it
  automatically cleans up orphaned loop devices and temporary mounts on start.

<!-- ## Contributing

Issues and pull requests that improve the documentation or script logic are
welcome. If you add new features, please keep the script self-contained so users
can continue to run it without manual preparation steps.

## License

This project is distributed under the terms specified in the repository. If a
`LICENSE` file is added in the future it will apply to all code and
documentation within this repo. -->
