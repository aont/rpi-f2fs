#!/bin/bash

# sudo unshare --mount --fork /bin/bash
# mount --make-rprivate /

set -xe
export LANG=C

IMAGE_PATH_A=2025-05-13-raspios-bookworm-arm64-lite.img
IMAGE_PATH_B=2025-05-13-raspios-bookworm-arm64-lite-f2fs.img
QEMU=qemu-aarch64-static
QEMU_PATH="$(command -v "${QEMU}")"

pkgs=(partclone f2fs-tools qemu-user-static util-linux rsync udisks2 coreutils grep)
missing=()
for pkg in "${pkgs[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        missing+=("$pkg")
    fi
done

if [ ${#missing[@]} -gt 0 ]; then
    apt-get update
    apt-get install -y "${missing[@]}"
fi

IMAGE_SIZE_A="$(du -b "${IMAGE_PATH_A}" | awk '{print $1;}')"

fallocate -l "${IMAGE_SIZE_A}" "${IMAGE_PATH_B}"

losetup --find --partscan --read-only "${IMAGE_PATH_A}"
losetup --find --partscan "${IMAGE_PATH_B}"

LOOP_DEV_A="$(losetup -j "${IMAGE_PATH_A}" | sed 's/:.*//')"
LOOP_DEV_B="$(losetup -j "${IMAGE_PATH_B}" | sed 's/:.*//')"

LOOP_DEV_A_BOOT="${LOOP_DEV_A}p1"
LOOP_DEV_A_ROOT="${LOOP_DEV_A}p2"
LOOP_DEV_B_BOOT="${LOOP_DEV_B}p1"
LOOP_DEV_B_ROOT="${LOOP_DEV_B}p2"


sfdisk -d "${LOOP_DEV_A}" | sfdisk "${LOOP_DEV_B}"
partprobe "${LOOP_DEV_B}"

partclone.fat -s "${LOOP_DEV_A_BOOT}" -b -o "${LOOP_DEV_B_BOOT}"

A_ROOT_UUID="$(eval "$(blkid "${LOOP_DEV_A_ROOT}" | sed -e '1s/^.*:\s*//' -e 's/\s+/;/g')"; echo $UUID)"

mkfs.f2fs -f -l rootfs -U "${A_ROOT_UUID}" "${LOOP_DEV_B_ROOT}"

MOUNT_PATH="${PWD}/.mountpath"
if [[ -d "${MOUNT_PATH}" ]]; then rmdir "${MOUNT_PATH}"; fi
mkdir "${MOUNT_PATH}"
A_ROOT_MOUNT_PATH=$(mktemp -d a_root_XXXXX -p "${MOUNT_PATH}")
B_ROOT_MOUNT_PATH=$(mktemp -d b_root_XXXXX -p "${MOUNT_PATH}")
mount "${LOOP_DEV_A_ROOT}" "${A_ROOT_MOUNT_PATH}"
mount "${LOOP_DEV_B_ROOT}" "${B_ROOT_MOUNT_PATH}"
# udisksctl mount -b "${LOOP_DEV_A_ROOT}"
# udisksctl mount -b "${LOOP_DEV_B_ROOT}"

# cat /proc/mounts
# A_ROOT_MOUNT_PATH="$(grep "${LOOP_DEV_A_ROOT}" /proc/mounts | cut -d ' ' -f 2)"
# B_ROOT_MOUNT_PATH="$(grep "${LOOP_DEV_B_ROOT}" /proc/mounts | cut -d ' ' -f 2)"

# exit 1

rsync -aHAXx --numeric-ids --delete --info=progress2 ${A_ROOT_MOUNT_PATH}/ ${B_ROOT_MOUNT_PATH}/

# udisksctl unmount -b "${LOOP_DEV_A_ROOT}"
umount "${LOOP_DEV_A_ROOT}"

losetup -d "${LOOP_DEV_B}"

B_BOOT_MOUNT_PATH=$(mktemp -d b_boot_XXXXX -p "${MOUNT_PATH}")
mount "${LOOP_DEV_B_BOOT}" "${B_BOOT_MOUNT_PATH}"
# udisksctl mount -b "${LOOP_DEV_B_BOOT}"
# B_BOOT_MOUNT_PATH="$(grep "${LOOP_DEV_B_BOOT}" /proc/mounts | cut -d ' ' -f 2)"

QEMU_BIND_PATH="${B_ROOT_MOUNT_PATH}/${QEMU}"
touch "${QEMU_BIND_PATH}"
mount --bind "${QEMU_PATH}" "${QEMU_BIND_PATH}"

B_BOOT_PARTUUID="$(eval "$(blkid "${LOOP_DEV_B_BOOT}" | sed -e '1s/^.*:\s*//' -e 's/\s+/;/g')"; echo $PARTUUID)"
B_BOOT_CHROOT_MOUNT_PATH="$(awk '$1=="PARTUUID='"${B_BOOT_PARTUUID}"'"{print $2;}' "${B_ROOT_MOUNT_PATH}/etc/fstab")"
mount --bind "${B_BOOT_MOUNT_PATH}" "${B_ROOT_MOUNT_PATH}${B_BOOT_CHROOT_MOUNT_PATH}"

for item in /dev /dev/pts /proc /sys; do
    mount --bind "${item}" "${B_ROOT_MOUNT_PATH}${item}"
done

cat /proc/mounts

unshare --uts --fork chroot "${B_ROOT_MOUNT_PATH}" "/${QEMU}" /bin/bash << EOS
hostname "$(cat /etc/hostname)"
apt-get update
apt-get install f2fs-tools
apt-get clean
EOS

for item in /sys /proc /dev/pts /dev; do
    umount "${B_ROOT_MOUNT_PATH}${item}"
done

umount "${B_ROOT_MOUNT_PATH}${B_BOOT_CHROOT_MOUNT_PATH}"

umount "${QEMU_BIND_PATH}"
rm "${QEMU_BIND_PATH}"

B_ROOT_PARTUUID="$(eval "$(blkid "${LOOP_DEV_B_ROOT}" | sed -e '1s/^.*:\s*//' -e 's/\s+/;/g')"; echo $PARTUUID)"

awk '$1=="PARTUUID='"${B_ROOT_PARTUUID}"'"{print $1, "f2fs", "defaults,noatime,background_gc=on,discard", 0, 0; next} {print;}' "${B_ROOT_MOUNT_PATH}/etc/fstab" > "${B_ROOT_MOUNT_PATH}/etc/fstab"
sed -i -e 's/\(rootfstype=\)[^[:space:]]\+/\1f2fs/g' "${B_BOOT_MOUNT_PATH}/cmdline.txt"

umount "${LOOP_DEV_B_BOOT}"
umount "${LOOP_DEV_B_ROOT}"
# udisksctl unmount -b "${LOOP_DEV_B_BOOT}"
# udisksctl unmount -b "${LOOP_DEV_B_ROOT}"

losetup -d "${LOOP_DEV_A}"

rmdir "${A_ROOT_MOUNT_PATH}" "${B_ROOT_MOUNT_PATH}" "${B_BOOT_MOUNT_PATH}"
rmdir "${MOUNT_PATH}"

echo "Completed" 1>&2