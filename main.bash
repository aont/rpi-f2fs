#!/bin/bash

set -xeu
export LANG=C

if [[ "$0" = bash ]] || [[ "$0" = -bash ]] ;
then
    set +x
    echo "This script must be put as a file" 1>&2
    exit 1
fi

if [[ "$#" -ne 2 ]]; then
    echo "Illegal number of parameters: $#"
    exit 1
fi

IMAGE_PATH_A="$1"
IMAGE_PATH_B="$2"

SELF_NS=$(readlink /proc/$$/ns/mnt)
P1_NS=$(readlink /proc/1/ns/mnt)

if [[ "${P1_NS}" = "${SELF_NS}" ]]; then
    exec unshare --mount --fork /bin/bash "$0" "$@"
fi

mount --make-rprivate /

QEMU=qemu-aarch64-static

if [[ -f "${IMAGE_PATH_B}" ]]; then
    while true;
    do
        set +x
        read -p "${IMAGE_PATH_B} exists. overwrite? [yes/no] " ans
        set -x
        if [[ "$ans" = "yes" ]]; then
            break
        elif [[ "$ans" = "no" ]]; then
            exit
        fi
    done
fi

losetup_d_loop() {
    for image_path in "$@"; do
        while true;
        do
            loop_dev="$(losetup -j "${image_path}" | sed 's/:.*//')"
            if [[ -z "$loop_dev" ]]; then
                break
            else
                umount "${loop_dev}p1" || true
                umount "${loop_dev}p2" || true
                losetup -d "$loop_dev"
            fi
        done
    done
}

losetup_d_loop "${IMAGE_PATH_A}"
losetup_d_loop "${IMAGE_PATH_B}"

if [[ -z "$SUDO_UID" ]]; then
    SUDO_UID=0
fi
if [[ -z "$SUDO_GID" ]]; then
    SUDO_GID=0
fi

MOUNT_PATH="${PWD}/.mountpath"
if [[ -d "${MOUNT_PATH}" ]]; then rm -rf "${MOUNT_PATH}"; fi

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
chown "${SUDO_UID}:${SUDO_GID}" "${IMAGE_PATH_B}"

losetup --find --partscan --read-only "${IMAGE_PATH_A}"
losetup --find --partscan "${IMAGE_PATH_B}"

LOOP_DEV_A="$(losetup -j "${IMAGE_PATH_A}" | sed 's/:.*//')"
LOOP_DEV_B="$(losetup -j "${IMAGE_PATH_B}" | sed 's/:.*//')"

LOOP_DEV_A_BOOT="${LOOP_DEV_A}p1"
LOOP_DEV_A_ROOT="${LOOP_DEV_A}p2"
LOOP_DEV_B_BOOT="${LOOP_DEV_B}p1"
LOOP_DEV_B_ROOT="${LOOP_DEV_B}p2"

dd if="${LOOP_DEV_A}" of="${LOOP_DEV_B}" bs=512 count=1 conv=notrunc
partprobe "${LOOP_DEV_B}"

partclone.fat -s "${LOOP_DEV_A_BOOT}" -b -o "${LOOP_DEV_B_BOOT}"

A_ROOT_UUID="$(eval "$(blkid "${LOOP_DEV_A_ROOT}" | sed -e '1s/^.*:\s*//' -e 's/\s+/;/g')"; echo $UUID)"

mkfs.f2fs -f -l rootfs -U "${A_ROOT_UUID}" "${LOOP_DEV_B_ROOT}"

mkdir "${MOUNT_PATH}"
chown "${SUDO_UID}:${SUDO_GID}" "${MOUNT_PATH}"

A_ROOT_MOUNT_PATH=$(mktemp --tmpdir="${MOUNT_PATH}" --directory a_root_XXXXX)
chown "${SUDO_UID}:${SUDO_GID}" "${A_ROOT_MOUNT_PATH}"

B_ROOT_MOUNT_PATH=$(mktemp --tmpdir="${MOUNT_PATH}" --directory b_root_XXXXX)
chown "${SUDO_UID}:${SUDO_GID}" "${B_ROOT_MOUNT_PATH}"

mount -o ro "${LOOP_DEV_A_ROOT}" "${A_ROOT_MOUNT_PATH}"
mount "${LOOP_DEV_B_ROOT}" "${B_ROOT_MOUNT_PATH}"

rsync -aHAXx --numeric-ids --delete --info=progress2 ${A_ROOT_MOUNT_PATH}/ ${B_ROOT_MOUNT_PATH}/

umount "${LOOP_DEV_A_ROOT}"

losetup -d "${LOOP_DEV_B}"

B_BOOT_MOUNT_PATH=$(mktemp --tmpdir="${MOUNT_PATH}" --directory b_boot_XXXXX )
chown "${SUDO_UID}:${SUDO_GID}" "${B_BOOT_MOUNT_PATH}"

mount "${LOOP_DEV_B_BOOT}" "${B_BOOT_MOUNT_PATH}"

QEMU_BIND_PATH=$(mktemp --tmpdir="${B_ROOT_MOUNT_PATH}/tmp" qemu_XXXXX)
chown "${SUDO_UID}:${SUDO_GID}" "${QEMU_BIND_PATH}"
mount --bind "${QEMU_PATH}" "${QEMU_BIND_PATH}"
QEMU_PATH_CHROOT="${QEMU_BIND_PATH#"$B_ROOT_MOUNT_PATH"}"

B_BOOT_PARTUUID="$(eval "$(blkid "${LOOP_DEV_B_BOOT}" | sed -e '1s/^.*:\s*//' -e 's/\s+/;/g')"; echo $PARTUUID)"
B_BOOT_CHROOT_MOUNT_PATH="$(awk '$1=="PARTUUID='"${B_BOOT_PARTUUID}"'"{print $2;}' "${B_ROOT_MOUNT_PATH}/etc/fstab")"
mount --bind "${B_BOOT_MOUNT_PATH}" "${B_ROOT_MOUNT_PATH}${B_BOOT_CHROOT_MOUNT_PATH}"

B_ROOT_PARTUUID="$(eval "$(blkid "${LOOP_DEV_B_ROOT}" | sed -e '1s/^.*:\s*//' -e 's/\s+/;/g')"; echo $PARTUUID)"

FSTAB_PATH="${B_ROOT_MOUNT_PATH}/etc/fstab"

set +x
echo ---- begin fstab before ---- 1>&2
echo "$(< "${FSTAB_PATH}")" 1>&2
echo ---- end fstab before ---- 1>&2
set -x

FSTAB_NEW="$(awk '$1=="PARTUUID='"${B_ROOT_PARTUUID}"'"{print $1, $2, "f2fs", "defaults,noatime,background_gc=on,discard", 0, 0; next} {print;}' "${FSTAB_PATH}")"
echo "${FSTAB_NEW}" > "${FSTAB_PATH}"
unset FSTAB_NEW

set +x
echo ---- begin fstab after ---- 1>&2
echo "$(< "${B_ROOT_MOUNT_PATH}/etc/fstab")" 1>&2
echo ---- end fstab after ---- 1>&2
set -x

LPF_PATH_LOCAL=/usr/share/initramfs-tools/scripts/local-premount/firstboot
LPF_PATH="${B_ROOT_MOUNT_PATH}${LPF_PATH_LOCAL}"

set +x
echo "---- begin ${LPF_PATH_LOCAL} before ----" 1>&2
echo "$(< "${LPF_PATH}")" 1>&2
echo "---- end ${LPF_PATH_LOCAL} before ----" 1>&2
set -x

sed -i -e 's/^\([[:space:]]*\)resize2fs[[:space:]]\+.*[[:space:]]\+\"\$DEV\"[[:space:]]*$/\1resize.f2fs "$DEV"/' "${LPF_PATH}"

set +x
echo "---- begin ${LPF_PATH_LOCAL} after ----" 1>&2
echo "$(< "${LPF_PATH}")" 1>&2
echo "---- end ${LPF_PATH_LOCAL} after ----" 1>&2
set -x

HF_PATH_LOCAL=/usr/share/initramfs-tools/hooks/firstboot
HF_PATH="${B_ROOT_MOUNT_PATH}${HF_PATH_LOCAL}"

set +x
echo "---- begin ${HF_PATH_LOCAL} before ----" 1>&2
echo "$(< "${HF_PATH}")" 1>&2
echo "---- end ${HF_PATH_LOCAL} before ----" 1>&2
set -x

sed -i -e 's/resize2fs/resize.f2fs/g' "${HF_PATH}"

set +x
echo "---- begin ${HF_PATH_LOCAL} after ----" 1>&2
echo "$(< "${HF_PATH}")" 1>&2
echo "---- end ${HF_PATH_LOCAL} after ----" 1>&2
set -x

rm "${B_ROOT_MOUNT_PATH}/etc/init.d/resize2fs_once"

CMDLINE_PATH="${B_BOOT_MOUNT_PATH}/cmdline.txt"

set +x
echo ---- begin cmdline before ---- 1>&2
echo "$(< "${CMDLINE_PATH}")" 1>&2
echo ---- end cmdline after ---- 1>&2
set -x

sed -i -e 's/\(rootfstype=\)[^[:space:]]\+/\1f2fs/g' -e 's/\(fsck[.]repair=\)yes/\1preen/g' "${CMDLINE_PATH}"

set +x
echo ---- begin cmdline after ---- 1>&2
echo "$(< "${CMDLINE_PATH}")" 1>&2
echo ---- end cmdline after ---- 1>&2
set -x

for item in /dev /dev/pts /proc /sys; do
    mount --bind "${item}" "${B_ROOT_MOUNT_PATH}${item}"
done

set +x
echo ---- begin /proc/mounts ---- 1>&2
echo "$(< /proc/mounts)" 1>&2
echo ---- end /proc/mounts ---- 1>&2
set -x

unshare --uts --fork chroot "${B_ROOT_MOUNT_PATH}" "${QEMU_PATH_CHROOT}" /bin/bash << EOS
set -xe
hostname "\$(< /etc/hostname)"
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

umount "${LOOP_DEV_B_BOOT}"
umount "${LOOP_DEV_B_ROOT}"

losetup -d "${LOOP_DEV_A}"

rmdir "${A_ROOT_MOUNT_PATH}" "${B_ROOT_MOUNT_PATH}" "${B_BOOT_MOUNT_PATH}"
rmdir "${MOUNT_PATH}"

set +x
echo "[info] Completed" 1>&2
set -x