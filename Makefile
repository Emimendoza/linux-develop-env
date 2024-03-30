.ONESHELL:
SHELL := /bin/bash
.SHELLFLAGS := -e -c
# This script helps with building the kernel and testing it on QEMU
# It assumes a host system running arch linux

# User defined variables
CC=ccache gcc
QEMU=qemu-system-x86_64
MAKE_ARGS=-j10

# Internals
ROOTFS_DIR=$(shell pwd)/rootfs-mnt
MODULES_DIR=$(ROOTFS_DIR)/
QEMU_ARGS=-m 512 -kernel bzImage -initrd initrd.img -append "root=/dev/hda rw" -hda rootfs.img
SUDO=./pk

all: rootfs.img bzImage initrd.img

initrd.img: bzImage modules rootfs.img-mount
	$(SUDO) arch-chroot $(ROOTFS_DIR) mkinitcpio -k $(LINUX_NAME) -g /boot/initrd.img
	$(SUDO) cp $(ROOTFS_DIR)/boot/initrd.img .
	$(SUDO) chown $(USER) initrd.img

modules: bzImage rootfs.img-mount
	$(MAKE) -C linux CC="$(CC)" $(MAKE_ARGS) modules
	$(MAKE) -C linux CC="$(CC)" $(MAKE_ARGS) INSTALL_MOD_PATH="$(shell cd linux; make kernelrelease)" modules_install
	touch modules

bzImage: linux/.config
	$(MAKE) -C linux CC="$(CC)" $(MAKE_ARGS) bzImage
	cp linux/arch/x86/boot/bzImage bzImage

linux/.config: linux
	zcat /proc/config.gz > linux/.config
	$(MAKE) -C linux olddefconfig clean

clean: rootfs.img-unmount
	$(MAKE) -C linux clean || true
	rm -f rootfs.img bzImage initrd.img modules

rootfs.img: $(ROOTFS_DIR)
	dd if=/dev/zero of=rootfs.img bs=1M count=5000
	mkfs.ext4 rootfs.img
	$(SUDO) mount $(shell pwd)/rootfs.img $(ROOTFS_DIR)
	$(SUDO) pacstrap -c $(ROOTFS_DIR) base coreutils mkinitcpio kmod
	$(SUDO) chown -R $(USER) $(ROOTFS_DIR)
	$(SUDO) umount $(ROOTFS_DIR)

rootfs.img-mount: rootfs.img $(ROOTFS_DIR)
	# If the rootfs is mounted, do nothing
	[ -f rootfs.img-mount ] || $(SUDO) mount $(shell pwd)/rootfs.img $(ROOTFS_DIR)
	touch rootfs.img-mount

rootfs.img-unmount:
	# If the rootfs is mounted, unmount it
	[ -f rootfs.img-mount ] && $(SUDO) umount $(ROOTFS_DIR) || true
	rm -f rootfs.img-mount

$(ROOTFS_DIR):
	mkdir -p $(ROOTFS_DIR)

run: all rootfs.img-unmount
	$(QEMU) $(QEMU_ARGS)

linux:
	git submodule update --init --recursive

.PHONY: rootfs.img-unmount
