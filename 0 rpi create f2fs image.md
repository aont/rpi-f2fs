# rpi create f2fs image

```
$ du -b 2025-05-13-raspios-bookworm-arm64-lite.img
$ fallocate -l 2759852032  2025-05-13-raspios-bookworm-arm64-lite-f2fs.img

$ udisksctl loop-setup -r -f 2025-05-13-raspios-bookworm-arm64-lite.img
$ udisksctl loop-setup -f 2025-05-13-raspios-bookworm-arm64-lite-f2fs.img
$ udisksctl unmount -b /dev/loop13p1

$ sudo sfdisk -d /dev/loop13 | sudo sfdisk /dev/loop18

$ sudo apt install partclone

$ udisksctl unmount -b /dev/loop13p1
$ sudo partclone.fat -s /dev/loop13p1 -b -o /dev/loop18
$ udisksctl unmount -b /dev/loop18p1

$ sudo apt install f2fs-tools

$ sudo blkid /dev/loop13p2
/dev/loop13p2: LABEL="rootfs" UUID="d4cc7d63-da78-48ad-9bdd-64ffbba449a8" BLOCK_SIZE="4096" TYPE="ext4" PARTUUID="d9c86127-02"

$ sudo mkfs.f2fs -f -l rootfs -U d4cc7d63-da78-48ad-9bdd-64ffbba449a8 /dev/loop18p2

$ udisksctl mount -b /dev/loop13p2

$ sudo rsync -AXav /media/aoki/rootfs/ /media/aoki/rootfs1/

$ file /usr/bin/qemu-aarch64-static

$ sudo touch /media/aoki/rootfs1/tmp/qemu-aarch64-static
$ sudo mount --bind /usr/bin/qemu-aarch64-static /media/aoki/rootfs1/host/qemu-aarch64-static

$ cd /media/aoki/rootfs1/
$ sudo mount --bind /dev ./dev
$ sudo mount --bind /dev/pts ./dev/pts
$ sudo mount --bind /proc ./proc
$ sudo mount --bind /sys ./sys

$ sudo unshare --uts chroot . /host/qemu-aarch64-static /bin/bash --login -i

# hostname $(cat /etc/hostname)
# apt update
# apt install f2fs-tools
# apt-get clean
# exit

$ cut -d ' ' -f 2 /proc/mounts
```