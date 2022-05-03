#!/usr/bin/env bash

create_dataset_A() {
    pushd "$1"
    mkdir -p a/aa/aaa
    echo a > a/test
    echo aa > a/aa/test
    echo aaa > a/aa/aaa/test
    echo nothing > test
    popd
}

check_dataset_A() {
    assert_dir_exists "$1"/a
    assert_dir_exists "$1"/a/aa
    assert_dir_exists "$1"/a/aa/aaa
    assert_file_exists "$1"/test
    assert_file_contains "$1"/test '^nothing$'
    assert_file_exists "$1"/a/test
    assert_file_contains "$1"/a/test '^a$'
    assert_file_exists "$1"/a/aa/test
    assert_file_contains "$1"/a/aa/test '^aa$'
    assert_file_exists "$1"/a/aa/aaa/test
    assert_file_contains "$1"/a/aa/aaa/test '^aaa$'
}

change_dataset_A_to_AB() {
    pushd "$1"
    echo ab > a/test
    echo aabb > a/aa/test
    rm -rf a/aa/aaa
    popd
}

check_dataset_AB() {
    assert_dir_exists "$1"/a
    assert_dir_exists "$1"/a/aa
    assert_dir_not_exists "$1"/a/aa/aaa
    assert_file_exists "$1"/test
    assert_file_contains "$1"/test '^nothing$'
    assert_file_exists "$1"/a/test
    assert_file_contains "$1"/a/test '^ab$'
    assert_file_exists "$1"/a/aa/test
    assert_file_contains "$1"/a/aa/test '^aabb$'
    assert_file_not_exists "$1"/a/aaa/test
}
