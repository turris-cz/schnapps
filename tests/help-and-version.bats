#!/usr/bin/env bats

setup() {
    load "common_setup.bash"
    _diskless_setup
}

@test "Reports version" {
    run "${ROOT_DIR}"/schnapps.sh version
    assert_success
    assert_output --partial '@VERSION@'
}

@test "Displays help" {
    run "${ROOT_DIR}"/schnapps.sh help
    assert_success
    assert_output --partial 'Usage: schnapps'
}

