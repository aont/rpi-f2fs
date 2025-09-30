# How to Create a Raspberry Pi Image with F2FS Root (Quick and Safe)

When building custom Raspberry Pi images, switching the root filesystem from ext4 to F2FS can improve performance on flash storage. This guide provides a **practical, safe method** that incorporates key improvements such as `udisksctl`, reliable `rsync` options, handling of `resolv.conf`, updating `fstab`, and proper unmounting. The steps assume you are working on a Debian/Ubuntu host with root privileges.

---

## Install Required Tools

```bash
sudo apt update
sudo apt install -y partclone f2fs-tools rsync
```

---

## 1. Prepare Source and Target Images

```bash
du -b 2025-05-13-raspios-bookworm-arm64-lite.img   # size check
fallocate -l <IMAGE_SIZE> 2025-05-13-raspios-bookworm-arm64-lite-f2fs.img
```

---

## 2. Attach Loop Devices

```bash
udisksctl loop-setup -r -f 2025-05-13-raspios-bookworm-arm64-lite.img
# Example: /dev/loop13

udisksctl loop-setup -f 2025-05-13-raspios-bookworm-arm64-lite-f2fs.img
# Example: /dev/loop18
```

<!--
```bash
sudo losetup --find --show --partscan 2025-05-13-raspios-bookworm-arm64-lite.img
# Example: /dev/loop13

sudo losetup --find --show --partscan 2025-05-13-raspios-bookworm-arm64-lite-f2fs.img
# Example: /dev/loop18
```
-->

Check created devices:

```bash
lsblk
```

---

## 3. Copy Partition Table

```bash
sudo sfdisk -d /dev/loop13 | sudo sfdisk /dev/loop18
sudo partprobe /dev/loop18
```

---

## 4. Clone the Boot Partition

```bash
sudo partclone.fat -s /dev/loop13p1 -b -o /dev/loop18p1
```

Verify IDs:

```bash
sudo blkid /dev/loop18p1
sudo blkid /dev/loop18p2
```

---

## 5. Format Root Partition as F2FS

```bash
sudo blkid /dev/loop13p2   # get original UUID
sudo mkfs.f2fs -f -l rootfs -U <UUID> /dev/loop18p2
```

---

## 6. Copy Root Filesystem with Rsync

Mount partitions (maybe automatically done already):

```bash
udisksctl mount -b /dev/loop13p2   # -> /media/${USER}/rootfs
udisksctl mount -b /dev/loop18p2   # -> /media/${USER}/rootfs1
```

Rsync with full fidelity:

```bash
sudo rsync -aHAXx --numeric-ids --delete --info=progress2 /media/${USER}/rootfs/ /media/${USER}/rootfs1/
```

---

## 7. Chroot Setup (Optional)

For package installs or config changes, bind mount essentials:

```bash
sudo mount --bind /usr/bin/qemu-aarch64-static /media/${USER}/rootfs1/qemu-aarch64-static
sudo mount --bind /dev  /media/${USER}/rootfs1/dev
sudo mount --bind /proc /media/${USER}/rootfs1/proc
sudo mount --bind /sys  /media/${USER}/rootfs1/sys
sudo mount --bind /etc/resolv.conf /media/${USER}/rootfs1/etc/resolv.conf
```

Then enter:

```bash
sudo unshare --uts chroot /media/${USER}/rootfs1 /qemu-aarch64-static /bin/bash --login -i
```

In the chroot environment:

```bash
hostname "$(cat /etc/hostname)"
apt-get update
apt-get install bcache-tools
apt-get clean
exit
```

Unmount: /dev, etc.
```
sudo umount /media/${USER}/rootfs1/etc/resolv.conf
sudo umount /media/${USER}/rootfs1/{dev/pts,dev,proc,sys}
sudo umount /media/${USER}/rootfs1/qemu-aarch64-static
```

## 8. Update fstab and cmdline.txt

`/etc/fstab` example:

```
UUID=<root-uuid>  /  f2fs  defaults,noatime,background_gc=on,discard  0 0
```

(maybe not necessary) In `/boot/cmdline.txt`, update:

```
root=PARTUUID=<new-partuuid>
```

---

## 9. Cleanup

```bash
udisksctl unmount -b /dev/loop18p1
udisksctl unmount -b /dev/loop18p2
udisksctl loop-delete -b /dev/loop18
udisksctl loop-delete -b /dev/loop13
```

---

## Common Pitfalls

* **PARTUUID mismatch** → Won’t boot. Fix `cmdline.txt`.
* **Kernel without built-in F2FS** → Won’t mount root. Needs rebuild/initramfs.
* **Discard option issues on SD cards** → Remove `discard` if unstable.
* **Wrong rsync options** → Permissions broken. Always use `--numeric-ids`.
* **Forgotten cleanup** → Remove qemu binary and unmount properly.

---

## Checklist Before Flashing

* [ ] Updated `fstab` with correct UUID.
* [ ] Fixed `cmdline.txt` with correct PARTUUID.
* [ ] Verified kernel has `CONFIG_F2FS=y`.
* [ ] Used correct `rsync` options.
* [ ] Installed `f2fs-tools` in chroot.
* [ ] Unmounted all binds and detached loop devices.
* [ ] Tested boot with serial console.

---

✅ With this workflow, you can safely and efficiently convert a Raspberry Pi root filesystem to F2FS while avoiding the most common mistakes.

