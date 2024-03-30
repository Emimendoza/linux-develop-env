#!/bin/bash

# script to make initramfs for the built kernel and run it in qemu

ROOTFS_DIR="$(pwd)/rootfs-mnt"
ROOTFS_IMG="$(pwd)/rootfs.img"

EXTRA_FLAGS=""
EXTRA_FLAGS+="-n" # uncomment to do a dry run of module installation

CCACHE_BIN="$(which ccache)"

set -e -x
cleanup_before_exit() {
  sudo umount "$ROOTFS_DIR" 2>/dev/null || exit 0
  rm -rf "$ROOTFS_DIR"
}

CC="${CCACHE_BIN} gcc"

trap cleanup_before_exit ERR
mkdir -p "$ROOTFS_DIR"
KERNEL_RELEASE="$(make kernelrelease)"
MAKE_FLAGS="-j $(nproc)"
INSTALL_MOD_PATH="$ROOTFS_DIR/lib/modules/$KERNEL_RELEASE"

QEUM_FLAGS=(
"-kernel arch/x86/boot/bzImage"
"-initrd initramfs-linux$KERNEL_RELEASE.img"
"-append 'root=/dev/hda'"
"-hda $ROOTFS_IMG"
"-enable-kvm"
"-m 2048M"
)

make CC="$CC" $MAKE_FLAGS bzImage modules


# Make sure rootfs isnt mounted first
sudo umount "$ROOTFS_DIR" 2>/dev/null
# mount rootfs
sudo mount -o loop "$ROOTFS_IMG" "$ROOTFS_DIR"
# install modules
sudo make CC="$CC" $MAKE_FLAGS "$EXTRA_FLAGS" modules_install INSTALL_MOD_PATH="$INSTALL_MOD_PATH"
# copy kernel image
sudo cp -v arch/x86/boot/bzImage "$ROOTFS_DIR/boot/vmlinuz-linux$KERNEL_RELEASE"
# Call mkinitcpio
sudo chroot "$ROOTFS_DIR" mkinitcpio -k "$KERNEL_RELEASE" -g "/boot/initramfs-linux$KERNEL_RELEASE.img"
# copy initramfs to host
sudo cp -v "$ROOTFS_DIR/boot/initramfs-linux$KERNEL_RELEASE.img" .
# unmount rootfs
sudo umount "$ROOTFS_DIR"
# run qemu
qemu-system-x86-64 "${QEUM_FLAGS[@]}"