#!/bin/bash

set -xeu
export LANG=C

# Ensure the script is being run as a file, not interactively from bash
if [[ "$0" = bash ]] || [[ "$0" = -bash ]] ;
then
    set +x
    echo "This script must be put as a file" 1>&2
    exit 1
fi

# Check for exactly two arguments: source image and target image
if [[ "$#" -ne 2 ]]; then
    echo "Illegal number of parameters: $#"
    exit 1
fi

IMAGE_PATH_A="$1"   # Input (original) Raspberry Pi OS image
IMAGE_PATH_B="$2"   # Output (converted) image

# Detect if we're already running in a separate mount namespace
SELF_NS=$(readlink /proc/$$/ns/mnt)
P1_NS=$(readlink /proc/1/ns/mnt)

set +e
systemctl is-active systemd-binfmt
SYSTEMD_BINFMT_FLAG="$?"
set -e

# If not, re-exec under unshare to isolate mount operations
if [[ "${P1_NS}" = "${SELF_NS}" ]]; then

    # Function: detach any loop devices associated with given image(s)
    losetup_d_loop() {
        for image_path in "$@"; do
            while true;
            do
                loop_dev="$(losetup -j "${image_path}" | sed 's/:.*//')"
                if [[ -z "$loop_dev" ]]; then
                    break
                else
                    umount -f "${loop_dev}p1" || true
                    umount -f "${loop_dev}p2" || true
                    losetup -d "$loop_dev"
                fi
            done
        done
    }

    # Cleanup any stale loop devices for the input/output images
    losetup_d_loop "${IMAGE_PATH_A}" "${IMAGE_PATH_B}"

    exec unshare --uts --mount --fork /bin/bash "$0" "$@"
fi

# Make mount points private so they don’t propagate to the host
mount --make-rprivate /

QEMU=
QEMU_BINFMT_NAME=
QEMU_BINFMT_MAGIC=
QEMU_BINFMT_MASK=

# If target image exists, ask user whether to overwrite
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

# Ensure UID/GID are set for ownership handling
if [[ -z "${SUDO_UID+x}" ]]; then
    SUDO_UID=0
fi
if [[ -z "${SUDO_GID+x}" ]]; then
    SUDO_GID=0
fi

# Temporary mount workspace
MOUNT_PATH=$(mktemp --tmpdir="${PWD}" --directory .mountpath-XXXXX)
chown "${SUDO_UID}:${SUDO_GID}" "${MOUNT_PATH}"

# Check for required packages; install any missing
pkgs=(partclone f2fs-tools qemu-user-static jq util-linux rsync coreutils grep parted binutils)
if [[ ! "$SYSTEMD_BINFMT_FLAG" -eq "0" ]]; then
    pkgs+=(binfmt-support)
fi
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

# Allocate target image with the same size as source
IMAGE_SIZE_A="$(du -b "${IMAGE_PATH_A}" | awk '{print $1;}')"

fallocate -l "${IMAGE_SIZE_A}" "${IMAGE_PATH_B}"
chown "${SUDO_UID}:${SUDO_GID}" "${IMAGE_PATH_B}"

# Attach both images to loop devices (source read-only, target read/write)
losetup --find --partscan --read-only "${IMAGE_PATH_A}"
losetup --find --partscan "${IMAGE_PATH_B}"

LOOP_DEV_A="$(losetup -j "${IMAGE_PATH_A}" | sed 's/:.*//')"
LOOP_DEV_B="$(losetup -j "${IMAGE_PATH_B}" | sed 's/:.*//')"

LOOP_DEV_A_BOOT="${LOOP_DEV_A}p1"
LOOP_DEV_A_ROOT="${LOOP_DEV_A}p2"
LOOP_DEV_B_BOOT="${LOOP_DEV_B}p1"
LOOP_DEV_B_ROOT="${LOOP_DEV_B}p2"

# Copy MBR (partition table) from source to target
dd if="${LOOP_DEV_A}" of="${LOOP_DEV_B}" bs=512 count=1 conv=notrunc
partprobe "${LOOP_DEV_B}"

# Clone the boot partition (FAT)
partclone.fat -s "${LOOP_DEV_A_BOOT}" -b -o "${LOOP_DEV_B_BOOT}"

# Extract UUID from source root partition
get_blkid_field() {
    local dev="$1" field="$2"
    local UUID PARTUUID LABEL TYPE
    eval "$(blkid "$dev" | sed -e '1s/^.*:\s*//' -e 's/\s\+/\;/g')"
    eval "echo \$$field"
}

A_ROOT_UUID="$(get_blkid_field "${LOOP_DEV_A_ROOT}" UUID)"
B_BOOT_PARTUUID="$(get_blkid_field "${LOOP_DEV_B_BOOT}" PARTUUID)"
B_ROOT_PARTUUID="$(get_blkid_field "${LOOP_DEV_B_ROOT}" PARTUUID)"

# Format target root partition as F2FS with same UUID
mkfs.f2fs -f -l rootfs -U "${A_ROOT_UUID}" "${LOOP_DEV_B_ROOT}"

losetup -d "${LOOP_DEV_B}"
unset LOOP_DEV_B LOOP_DEV_B_BOOT LOOP_DEV_B_ROOT
losetup -d "${LOOP_DEV_A}"
unset LOOP_DEV_A LOOP_DEV_A_BOOT LOOP_DEV_A_ROOT

# Prepare temporary mount directories
A_ROOT_MOUNT_PATH=$(mktemp --tmpdir="${MOUNT_PATH}" --directory a_root_XXXXX)
chown "${SUDO_UID}:${SUDO_GID}" "${A_ROOT_MOUNT_PATH}"

B_ROOT_MOUNT_PATH=$(mktemp --tmpdir="${MOUNT_PATH}" --directory b_root_XXXXX)
chown "${SUDO_UID}:${SUDO_GID}" "${B_ROOT_MOUNT_PATH}"

B_BOOT_MOUNT_PATH=$(mktemp --tmpdir="${MOUNT_PATH}" --directory b_boot_XXXXX )
chown "${SUDO_UID}:${SUDO_GID}" "${B_BOOT_MOUNT_PATH}"

# Mount source root read-only and target root read-write

# Image A
IMAGE_A_JSON="$(parted --json "$IMAGE_PATH_A" unit B print | jq -c .)"
read IMAGE_A_ROOT_OFFSET IMAGE_A_ROOT_SIZE < <( echo "${IMAGE_A_JSON}" | jq -r '.disk.partitions[1] | [.start, .size] | map(sub("B$";"")) | @tsv') 
mount -o "loop,ro,offset=${IMAGE_A_ROOT_OFFSET},sizelimit=${IMAGE_A_ROOT_SIZE}" "${IMAGE_PATH_A}" "${A_ROOT_MOUNT_PATH}"

# Image B
IMAGE_B_JSON="$(parted --json "$IMAGE_PATH_B" unit B print | jq -c .)"
read IMAGE_B_BOOT_OFFSET IMAGE_B_BOOT_SIZE < <( echo "${IMAGE_B_JSON}" | jq -r '.disk.partitions[0] | [.start, .size] | map(sub("B$";"")) | @tsv') 
read IMAGE_B_ROOT_OFFSET IMAGE_B_ROOT_SIZE < <( echo "${IMAGE_B_JSON}" | jq -r '.disk.partitions[1] | [.start, .size] | map(sub("B$";"")) | @tsv') 
mount -o "loop,offset=${IMAGE_B_BOOT_OFFSET},sizelimit=${IMAGE_B_BOOT_SIZE}" "${IMAGE_PATH_B}" "${B_BOOT_MOUNT_PATH}"
mount -o "loop,offset=${IMAGE_B_ROOT_OFFSET},sizelimit=${IMAGE_B_ROOT_SIZE}" "${IMAGE_PATH_B}" "${B_ROOT_MOUNT_PATH}"

detect_rootfs_qemu() {
    local root="$1"
    local machine=""
    local candidate
    local -a candidates=(
        /bin/bash
        /bin/sh
        /usr/bin/bash
        /usr/bin/env
        /sbin/init
        /usr/lib/systemd/systemd
    )

    for candidate in "${candidates[@]}"; do
        if [[ -f "${root}${candidate}" ]]; then
            machine="$(readelf -h "${root}${candidate}" 2>/dev/null | awk -F: '/Machine:/ {gsub(/^ +/, "", $2); print $2; exit}')"
            if [[ -n "${machine}" ]]; then
                break
            fi
        fi
    done

    case "${machine}" in
        AArch64)
            echo "qemu-aarch64-static qemu-aarch64 \\x7fELF\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\xb7\\x00 \\xff\\xff\\xff\\xff\\xff\\xff\\xff\\x00\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xfe\\xff\\xff\\xff"
            ;;
        ARM)
            echo "qemu-arm-static qemu-arm \\x7fELF\\x01\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\x28\\x00 \\xff\\xff\\xff\\xff\\xff\\xff\\xff\\x00\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xfe\\xff\\xff\\xff"
            ;;
        *)
            echo "Unsupported or undetected rootfs CPU architecture: ${machine:-unknown}" 1>&2
            return 1
            ;;
    esac
}

read QEMU QEMU_BINFMT_NAME QEMU_BINFMT_MAGIC QEMU_BINFMT_MASK < <(detect_rootfs_qemu "${A_ROOT_MOUNT_PATH}")
QEMU_PATH="$(command -v "${QEMU}")"
QEMU_BIND_PATH="${B_ROOT_MOUNT_PATH}/usr/bin/${QEMU}"

# Copy filesystem contents from ext4 root → f2fs root
#
# In CI (especially GitHub Actions), `--info=progress2` can emit extremely long
# logs because the runner is non-interactive. Default to summary stats there,
# while keeping local interactive progress output by default.
RSYNC_INFO_DEFAULT="stats2"
if [[ -t 1 && "${GITHUB_ACTIONS:-}" != "true" ]]; then
    RSYNC_INFO_DEFAULT="progress2,stats2"
fi
RSYNC_INFO="${RSYNC_INFO:-${RSYNC_INFO_DEFAULT}}"

rsync -aHAXx --numeric-ids --delete --info="${RSYNC_INFO}" "${A_ROOT_MOUNT_PATH}/" "${B_ROOT_MOUNT_PATH}/"

# Unmount source root
umount "${A_ROOT_MOUNT_PATH}"

# Bind-mount QEMU binary inside chroot so ARM binaries can run under emulation
touch "${QEMU_BIND_PATH}"
chown "${SUDO_UID}:${SUDO_GID}" "${QEMU_BIND_PATH}"
mount -o ro --bind "${QEMU_PATH}" "${QEMU_BIND_PATH}"
QEMU_PATH_CHROOT="${QEMU_BIND_PATH#"$B_ROOT_MOUNT_PATH"}"

RESOLV_CONF_PATH=/etc/resolv.conf
RESOLV_CONF_BIND_PATH="${B_ROOT_MOUNT_PATH}/etc/resolv.conf"
mount -o ro --bind "${RESOLV_CONF_PATH}" "${RESOLV_CONF_BIND_PATH}"

# Bind boot partition into the chroot’s boot mount path
B_BOOT_CHROOT_MOUNT_PATH="$(awk '$1=="PARTUUID='"${B_BOOT_PARTUUID}"'"{print $2;}' "${B_ROOT_MOUNT_PATH}/etc/fstab")"
mount --bind "${B_BOOT_MOUNT_PATH}" "${B_ROOT_MOUNT_PATH}${B_BOOT_CHROOT_MOUNT_PATH}"

# Update /etc/fstab to mount root as F2FS
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

if [[ -f "$LPF_PATH" ]]; then
    set +x
    echo "---- begin ${LPF_PATH_LOCAL} before ----" 1>&2
    echo "$(< "${LPF_PATH}")" 1>&2
    echo "---- end ${LPF_PATH_LOCAL} before ----" 1>&2
    set -x

    # Replace initramfs scripts to use resize.f2fs instead of resize2fs
    sed -i -e 's/^\([[:space:]]*\)resize2fs[[:space:]]\+.*[[:space:]]\+\"\$DEV\"[[:space:]]*$/\1resize.f2fs "$DEV"/' "${LPF_PATH}"

    set +x
    echo "---- begin ${LPF_PATH_LOCAL} after ----" 1>&2
    echo "$(< "${LPF_PATH}")" 1>&2
    echo "---- end ${LPF_PATH_LOCAL} after ----" 1>&2
    set -x
fi

HF_PATH_LOCAL=/usr/share/initramfs-tools/hooks/firstboot
HF_PATH="${B_ROOT_MOUNT_PATH}${HF_PATH_LOCAL}"

if [[ -f "$HF_PATH" ]]; then
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
fi

CMDLINE_PATH="${B_BOOT_MOUNT_PATH}/cmdline.txt"

set +x
echo ---- begin cmdline before ---- 1>&2
echo "$(< "${CMDLINE_PATH}")" 1>&2
echo ---- end cmdline after ---- 1>&2
set -x

# Update boot parameters: rootfstype=f2fs and fsck.repair=preen
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

hostname "$(< "${B_ROOT_MOUNT_PATH}/etc/hostname")"

# dphys-swapfile resize2fs_once
systemctl --root "${B_ROOT_MOUNT_PATH}" disable e2scrub_reap

set +e
systemctl --root "${B_ROOT_MOUNT_PATH}" disable dphys-swapfile resize2fs_once
set -e

# Enter chroot (ARM environment via QEMU) to install f2fs-tools inside the image
if [[ ! "$SYSTEMD_BINFMT_FLAG" -eq "0" ]]; then
    update-binfmts --package qemu-user --install "${QEMU_BINFMT_NAME}" "$QEMU_PATH" --magic "${QEMU_BINFMT_MAGIC}" --mask "${QEMU_BINFMT_MASK}"
fi

CHROOT_QEMU=(chroot "${B_ROOT_MOUNT_PATH}" "${QEMU_PATH_CHROOT}")
"${CHROOT_QEMU[@]}" /bin/bash -c "echo hello chroot qemu"
"${CHROOT_QEMU[@]}" /usr/bin/apt-get update
"${CHROOT_QEMU[@]}" /usr/bin/apt-get install -y f2fs-tools
"${CHROOT_QEMU[@]}" /usr/bin/apt-get clean

if [[ ! "$SYSTEMD_BINFMT_FLAG" -eq "0" ]]; then
  update-binfmts --package qemu-user --remove "${QEMU_BINFMT_NAME}" "$QEMU_PATH"
fi

# Cleanup mounts
for item in /sys /proc /dev/pts /dev; do
    umount "${B_ROOT_MOUNT_PATH}${item}"
done

umount "${B_ROOT_MOUNT_PATH}${B_BOOT_CHROOT_MOUNT_PATH}"

umount "${RESOLV_CONF_BIND_PATH}"

umount "${QEMU_BIND_PATH}"
rm "${QEMU_BIND_PATH}"

umount "${B_BOOT_MOUNT_PATH}"
umount "${B_ROOT_MOUNT_PATH}"

# Remove temporary mount directories
rmdir "${A_ROOT_MOUNT_PATH}" "${B_ROOT_MOUNT_PATH}" "${B_BOOT_MOUNT_PATH}"
rmdir "${MOUNT_PATH}"

set +x
echo "[info] Completed" 1>&2
set -x
