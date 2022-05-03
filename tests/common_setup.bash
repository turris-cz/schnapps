#!/usr/bin/env bash

_diskless_setup() {
    ROOT_DIR="$(dirname "$( dirname "$BATS_TEST_FILENAME" )")"
    [ -d "$ROOT_DIR" ]
    bats_load_library 'bats-support'
    bats_load_library 'bats-assert'
}

_disk_setup() {
    sync
    $SUDO btrfs subvol create "$ROOT_MOUNT"/@
    $SUDO btrfs subvol create "$ROOT_MOUNT"/@other
    $SUDO mount -t btrfs "$WD"/disk "$MAIN_MOUNT" -o subvol=@
    $SUDO chmod a+rw "$MAIN_MOUNT"
    $SUDO mount -t btrfs "$WD"/disk "$OTHER_MOUNT" -o subvol=@other
    $SUDO chmod a+rw "$OTHER_MOUNT"
    bats_load_library 'bats-file'
    load "helpers.bash"
}

_remount_main() {
    $SUDO umount "$MAIN_MOUNT"
    $SUDO mount -t btrfs "$WD"/disk "$MAIN_MOUNT" -o subvol=@
}

_disk_teardown() {
    $SUDO umount "$MAIN_MOUNT"
    $SUDO umount "$OTHER_MOUNT"
    for s in "$ROOT_MOUNT"/@*; do
        $SUDO btrfs subvol delete "$s"
    done
    $SUDO rm -f "$ROOT_MOUNT"/*
    sync
}

_disk_file_setup() {
    SUDO=""
    [ "$(id -u)" -eq 0 ] || SUDO=sudo
    WD="$(mktemp -d schnapps-tests-XXXXXXX)"
    dd if=/dev/zero of="$WD"/disk bs=1M count=250
    mkfs.btrfs -L schnapps-test "$WD"/disk
    ROOT_MOUNT="$WD"/mount-root
    MAIN_MOUNT="$WD"/mount-main
    OTHER_MOUNT="$WD"/mount-other
    mkdir "$ROOT_MOUNT"
    $SUDO mount -t btrfs "$WD"/disk "$ROOT_MOUNT"
    mkdir "$MAIN_MOUNT"
    mkdir "$OTHER_MOUNT"
    export BATS_NO_PARALLELIZE_WITHIN_FILE=true
    export SUDO MAIN_MOUNT OTHER_MOUNT ROOT_MOUNT WD
}

_disk_file_teardown() {
    $SUDO umount "$ROOT_MOUNT"
    rm -rf "$WD"
}
