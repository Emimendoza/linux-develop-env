# REQUIREMENTS:
# ARCH LINUX (this script is arch specific)
# The following packages:
# qemu arch-install-scripts pkexec fakeroot fakechroot gcc make qemu-img parted
# Optional but recommended:
# ccache


.ONESHELL:
SHELL := /bin/bash
.SHELLFLAGS := -e -c
# This script helps with building the kernel and testing it on QEMU
# It assumes a host system running arch linux

# User defined variables
# We want to use ccache if it's available
CC := $(shell which ccache 2>/dev/null || true) gcc
MAKE_ARGS=-j10
# The size of the guest disk
DISK_SIZE=10G
# The filesystem to use (useful for testing other filesystems)
# Make sure your kernel supports it
DISK_MKFS=mkfs.ext4
# The nbd device to use MAKE SURE IT'S NOT IN USE
DEFAULT_NBD_DEV=/dev/nbd0
QEMU=qemu-system-x86_64

QEMU_ARGS=-m 4096 \
 -enable-kvm \
 -cpu host \
 -smp cores=1,threads=2 \
 -kernel bzImage \
 -initrd initrd.img \
 -append "root=/dev/sda1 rw" \
 -drive file=./rootfs.qcow2,format=qcow2,if=none,id=d0 \
 -device ahci,id=ahci \
 -device ide-hd,drive=d0,bus=ahci.0

PACSTRAP_MODULES=base \
 linux-firmware \
 mkinitcpio \
 kmod coreutils \
 bash

# Internals
ROOTFS_DIR=$(shell pwd)/rootfs-mnt
MODULES_DIR=$(ROOTFS_DIR)/

# We need to use sudo to mount the filesystem
# Prepare to type your password a million times because pkexec is annoying
SUDO=./pk
# SUDO=sudo # uncomment this line if you don't want to use pkexec
FAKE_SUDO=fakeroot
FAKE_CHROOT=fakechroot fakeroot chroot

KERNEL_NAME=$(shell make -C linux kernelrelease --no-print-directory)

all: rootfs.qcow2 bzImage initrd.img
	touch _all

_all:
	# If the kernel is already built, do nothing
	[ -f _all ] && exit || true
	$(MAKE) modules
	$(MAKE) bzImage
	$(MAKE) initrd.img
	touch _all

initrd.img: bzImage modules rootfs.qcow2-mount
	# If the initrd is already built, do nothing
	[ -f initrd.img ] && exit || true
	# mkinitcpio treats warnings as errors for some reason
	$(FAKE_CHROOT) $(ROOTFS_DIR) mkinitcpio -n -k "$(KERNEL_NAME)" -g /boot/initrd.img || true # ignore errors
	$(FAKE_SUDO) cp $(ROOTFS_DIR)/boot/initrd.img $(shell pwd)/initrd.img
	$(FAKE_SUDO) chown $(USER) "$(pwd)/initrd.img"
modules: bzImage rootfs.qcow2-mount
	# if the modules are already built, do nothing
	[ -f modules ] && exit || true
	$(MAKE) -C linux CC="$(CC)" $(MAKE_ARGS) modules
	$(MAKE) -C linux CC="$(CC)" $(MAKE_ARGS) INSTALL_MOD_PATH="$(ROOTFS_DIR)/" modules_install
	touch modules

bzImage: linux/.config rootfs.qcow2-mount
	# If the kernel is already built, do nothing
	[ -f bzImage ] && exit || true
	$(MAKE) -C linux CC="$(CC)" $(MAKE_ARGS) bzImage
	cp linux/arch/x86/boot/bzImage bzImage
	$(FAKE_SUDO) cp bzImage "$(ROOTFS_DIR)/boot/vmlinuz-linux$(KERNEL_NAME)"

linux/.config: linux
	# Only copy the config if it doesn't exist
	[ -f linux/.config ] || zcat /proc/config.gz > linux/.config
	$(MAKE) -C linux olddefconfig

rebuild: clean all

clean-rootfs:
	# If the rootfs isnt built, do nothing
	[ -f rootfs.qcow2 ] || exit
	if [ -d $(ROOTFS_DIR) ]; then \
  		$(SUDO) umount -l $(ROOTFS_DIR); \
		rm -rf $(ROOTFS_DIR) rootfs.qcow2-mount; \
	fi
	$(MAKE) rootfs.qcow2-unbind
	rm -f rootfs.qcow2


clean: rootfs.qcow2-unmount rootfs.qcow2-unbind
	$(MAKE) -C linux clean || true
	rm -f bzImage initrd.img modules _all

deep-clean: clean-rootfs clean
	$(MAKE) -C linux distclean || true
	$(SUDO) modprobe -r nbd 2> /dev/null || true

rootfs.qcow2: $(ROOTFS_DIR)
	# If the rootfs is already built, do nothing
	[ -f rootfs.qcow2 ] && exit || true
	qemu-img create -f qcow2 rootfs.qcow2 $(DISK_SIZE)
	$(MAKE) rootfs.qcow2-bind
	$(SUDO) parted -s $(DEFAULT_NBD_DEV) mklabel gpt mkpart primary ext4 1MiB 100%
	$(SUDO) $(DISK_MKFS) $(DEFAULT_NBD_DEV)p1
	$(MAKE) rootfs.qcow2-mount
	# pacstrap doesnt work with fakeroot :c
	$(SUDO) pacstrap -c $(ROOTFS_DIR) $(PACSTRAP_MODULES)
	$(SUDO) chown -R $(USER) $(ROOTFS_DIR)
	# Enable autologin
	$(FAKE_SUDO) cp ./autologin@.service $(ROOTFS_DIR)/etc/systemd/system/autologin@.service
	$(FAKE_CHROOT) $(ROOTFS_DIR) systemctl enable autologin@tty1.service

rootfs.qcow2-bind: nbd
	# If the rootfs is bound, do nothing
	[ -f rootfs.qcow2-bind ] && exit || true
	$(SUDO) qemu-nbd -c $(DEFAULT_NBD_DEV) $(shell pwd)/rootfs.qcow2
	touch rootfs.qcow2-bind

rootfs.qcow2-unbind:
	# If the rootfs is bound, unbind it
	[ -f rootfs.qcow2-bind ] && $(SUDO) qemu-nbd -d $(DEFAULT_NBD_DEV) || true
	rm -f rootfs.qcow2-bind

rootfs.qcow2-mount: rootfs.qcow2 $(ROOTFS_DIR) rootfs.qcow2-bind
	# If the rootfs is mounted, do nothing
	[ -f rootfs.qcow2-mount ] && exit || true
	$(SUDO) mount $(DEFAULT_NBD_DEV)p1 $(ROOTFS_DIR)
	$(SUDO) chown -R $(USER) $(ROOTFS_DIR)
	touch rootfs.qcow2-mount

rootfs.qcow2-unmount:
	# If the rootfs is mounted, unmount it
	# Fix permissions
	if df | grep -q "$(ROOTFS_DIR)"; then \
  		$(SUDO) chown -R 0:0 $(ROOTFS_DIR); \
		$(SUDO) umount $(ROOTFS_DIR); \
	fi
	rm -rf $(ROOTFS_DIR)
	rm -f rootfs.qcow2-mount
	$(MAKE) rootfs.qcow2-unbind

$(ROOTFS_DIR):
	mkdir -p $(ROOTFS_DIR)

run: _all rootfs.qcow2-unmount
	$(QEMU) $(QEMU_ARGS)

linux:
	git submodule update --init --recursive

# Loads the nbd module
nbd:
	# Needed for mounting the rootfs
	lsmod | grep -q nbd || $(SUDO) modprobe nbd max_part=8

.PHONY: rootfs.qcow2-unmount clean deep-clean run rebuild all nbd rootfs.qcow2-bind
