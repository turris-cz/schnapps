#!/usr/bin/env bats

setup_file() {
    load "common_setup.bash"
    _disk_file_setup
}

setup() {
    load "common_setup.bash"
    _diskless_setup
    _disk_setup
}

teardown() {
    _disk_teardown
}

teardown_file() {
    _disk_file_teardown
}

@test "List works" {
    run $SUDO "${ROOT_DIR}"/schnapps.sh -d "$MAIN_MOUNT" list
    assert_success
    assert_output --regexp "Type.*Size.*Date.*Description"
}

@test "Snapshot creation works" {
    run $SUDO "${ROOT_DIR}"/schnapps.sh -d "$MAIN_MOUNT" create Testing snapshot
    assert_success
    run $SUDO "${ROOT_DIR}"/schnapps.sh -d "$MAIN_MOUNT" list
    assert_output --partial "Testing snapshot"
    assert_dir_exists "$ROOT_MOUNT"/@1
    assert_file_exists "$ROOT_MOUNT"/1.info
}

@test "Snapshot are really snapshots" {
    create_dataset_A "$MAIN_MOUNT"
    check_dataset_A "$MAIN_MOUNT"
    run $SUDO "${ROOT_DIR}"/schnapps.sh -d "$MAIN_MOUNT" create Testing snapshot
    assert_success
    change_dataset_A_to_AB "$MAIN_MOUNT"
    check_dataset_AB "$MAIN_MOUNT"
    check_dataset_A "$ROOT_MOUNT"/@1
}

@test "Rollback works" {
    create_dataset_A "$MAIN_MOUNT"
    check_dataset_A "$MAIN_MOUNT"
    run $SUDO "${ROOT_DIR}"/schnapps.sh -d "$MAIN_MOUNT" create Testing snapshot
    assert_success
    change_dataset_A_to_AB "$MAIN_MOUNT"
    check_dataset_AB "$MAIN_MOUNT"
    run $SUDO "${ROOT_DIR}"/schnapps.sh -d "$MAIN_MOUNT" rollback
    _remount_main
    check_dataset_A "$MAIN_MOUNT"
}

@test "Delete works" {
    create_dataset_A "$MAIN_MOUNT"
    check_dataset_A "$MAIN_MOUNT"
    run $SUDO "${ROOT_DIR}"/schnapps.sh -d "$MAIN_MOUNT" create Testing snapshot
    assert_success
    assert_dir_exists "$ROOT_MOUNT"/@1
    assert_file_exists "$ROOT_MOUNT"/1.info
    run $SUDO "${ROOT_DIR}"/schnapps.sh -d "$MAIN_MOUNT" delete 1
    assert_success
    assert_dir_not_exists "$ROOT_MOUNT"/@1
    assert_file_not_exists "$ROOT_MOUNT"/1.info
}
