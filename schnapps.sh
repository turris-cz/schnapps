#!/bin/sh
#
# Btrfs snapshots managing script
# (C) 2016-2018 CZ.NIC, z.s.p.o.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

TMP_MNT_DIR="/mnt/.snapshots"
TMP_RMT_MNT_DIR="/mnt/.remote-snapshots"
LOCK="/tmp/schnapps.lock"
SYNC_TYPES="pre,post,timeline,single,rollback"
DEFAULT_SYNC_TYPES="$SYNC_TYPES"
ERR=0
KEEP_MAX=""
REMOTE_URL=""
REMOTE_MOUNTED=""
REMOTE_PATH=""
GPG_PASS=""
ROOT_DEV="$(btrfs fi show / | sed -n 's|.*\(/dev/[^[:blank:]]*\)$|\1|p' | head -n 1)"
if [ -n "`which uci 2> /dev/null`" ]; then
    KEEP_MAX_SINGLE="`  uci get schnapps.keep.max_single   2> /dev/null`"
    KEEP_MAX_TIME="`    uci get schnapps.keep.max_time     2> /dev/null`"
    KEEP_MAX_UPDATER="` uci get schnapps.keep.max_updater  2> /dev/null`"
    KEEP_MAX_ROLLBACK="`uci get schnapps.keep.max_rollback 2> /dev/null`"
    REMOTE_URL="`       uci get schnapps.remote.url        2> /dev/null`"
    REMOTE_PATH="`      uci get schnapps.remote.path       2> /dev/null`"
    REMOTE_USER="`      uci get schnapps.remote.user       2> /dev/null`"
    REMOTE_PASS="`      uci get schnapps.remote.password   2> /dev/null`"
    SYNC_TYPES="`       uci get schnapps.remote.sync_types 2> /dev/null`"
    GPG_PASS="`         uci get schnapps.encrypt.pass      2> /dev/null`"
fi

if [ "x$1" == "x-d" ]; then
    ROOT_DEV="$(btrfs fi show $2 | sed -n 's|.*\(/dev/[^[:blank:]]*\)$|\1|p')"
    shift 2
fi

[ \! -f /etc/schnapps/config ] || . /etc/schnapps/config
ROOT_LABEL="$(btrfs fi label "$ROOT_DEV")"
[ -z "$ROOT_LABEL" ] || [ \! -f /etc/schnapps/"$ROOT_LABEL" ] || . /etc/schnapps/"$ROOT_LABEL"
[ -n "$KEEP_MAX_SINGLE"      ] || KEEP_MAX_SINGLE=-1
[ -n "$KEEP_MAX_TIME"        ] || KEEP_MAX_TIME=-1
[ -n "$KEEP_MAX_UPDATER"     ] || KEEP_MAX_UPDATER=-1
[ -n "$KEEP_MAX_ROLLBACK"    ] || KEEP_MAX_ROLLBACK=-1

die() {
    echo "$@" >&2
    exit 1
}

show_help() {
    echo "Usage: `basename $0` [-d root] command [options]"
    echo ""
    echo "Commands:"
    echo "  create [opts] [desc]    Creates snapshot of current system"
    echo "      Options:"
    echo "          -t type         Type of the snapshot - default 'single'"
    echo "                          Other options are 'time', 'pre' and 'post'"
    echo
    echo "  list [opts]             Show available snapshots"
    echo "      Options:"
    echo "          -j              Output in json format"
    echo
    echo "  rlist [opts]            Show uploaded snapshots"
    echo "      Options:"
    echo "          -j              Output in json format"
    echo
    echo "  cleanup [--compare]     Deletes old snapshots and keeps only N newest"
    echo "                          You can set number of snapshots to keep in /etc/config/schnapps"
    echo "                          Current value of N is following for various types (-1 means infinite):"
    echo "                           * $KEEP_MAX_SINGLE single snapshots"
    echo "                           * $KEEP_MAX_TIME time based snapshots"
    echo "                           * $KEEP_MAX_UPDATER updater snapshots"
    echo "                           * $KEEP_MAX_ROLLBACK rollback backups snapshots"
    echo "                          With --compare option also deletes snapshots that doesn't differ from"
    echo "                          the previous one"
    echo
    echo "  delete <number> [...]   Deletes snapshot corresponding to the number(s)"
    echo "                          Numbers can be found via list command"
    echo
    echo "  modify <number> [opts]  Modify metadata of snapshot corresponding to the number"
    echo "                          Numbers can be found via list command"
    echo "      Options:"
    echo "          -t type         Type of the snapshot - default 'single'"
    echo "                          Other options are 'time', 'pre' and 'post'"
    echo "          -d description  Some note about the snapshot"
    echo
    echo "  rollback [number]       Make snapshot corresponding to the number default for next boot"
    echo "                          If called without any argument, go one step back"
    echo "                          Numbers can be found via list command"
    echo
    echo "  mount <number> [...]    Mount snapshot corresponding to the number(s)"
    echo "                          You can then browse it and you have to umount it manually"
    echo "                          Numbers can be found via list command"
    echo
    echo "  cmp [number] [number]   Compare snapshots corresponding to the numbers"
    echo "                          Numbers can be found via list command"
    echo "                          Shows just which files differs"
    echo
    echo "  diff [number] [number]  Compare snapshots corresponding to the numbers"
    echo "                          Numbers can be found via list command"
    echo "                          Shows even diffs of individual files"
    echo
    echo "  export [snapshot] path  Export snapshot as a medkit into specified directory"
    echo "                          Snapshot argument can be snapshot number or ommited to backup running system"
    echo
    echo "  upload [snapshot] [[url] [path]]"
    echo "                          Upload snapshot as a medkit into specified folder on WebDAV server"
    echo "                          Snapshot argument can be snapshot number or ommited to backup running system"
    echo
    echo "  sync [-t type,type]     Make sure that all snapshots of specified type are backuped on the server."
    echo
    echo "  import path/snpsht.info Import exported snapshot"
    echo
}

die_helping() {
    echo "$@" >&2
    echo
    show_help
    exit 1
}

mount_root() {
    if ! mkdir "$LOCK"; then
        echo "Another instance seems to be running!"
        exit 2
    fi
    mkdir -p "$TMP_MNT_DIR"
    if [ -n "`ls -A "$TMP_MNT_DIR"`" ]; then
        rmdir "$LOCK"
        echo "ERROR: Something is already in '$TMP_MNT_DIR'"
        exit 2
    fi
    mount "$ROOT_DEV" -o subvol=/ "$TMP_MNT_DIR" || die "Can't mount root partition"
    btrfs qgroup show / > /dev/null 2>&1 || btrfs quota enable "$TMP_MNT_DIR"
}

mount_snp() {
    mkdir -p /mnt/snapshot-@$1
    if [ -n "`ls -A "/mnt/snapshot-@$1"`" ]; then
        die "ERROR: Something is already in '/mnt/snapshot-@$1'"
    fi
    if mount "$ROOT_DEV" -o subvol=/@$1 /mnt/snapshot-@$1; then
        echo "Snapshot $1 mounted in /mnt/snapshot-@$1"
    else
        rmdir /mnt/snapshot-@$1
        die "ERROR: Can't mount snapshot $1"
    fi
}

umount_root() {
    umount -fl "$TMP_MNT_DIR" 2> /dev/null
    rmdir "$LOCK" 2> /dev/null
}

# Does pretty output, counts and adds enough spaces to fill desired space, arguments are:
#  $1 - what to print
#  $2 - minimal width -2
#  $3 - alignment - default is left, you can use 'R' to align to right
#  $4 - what to fill with - default is spaces
round_output() {
    WORD="$1"
    ROUND="$2"
    AL="$3"
    FILL="$4"
    OUTPUT=""
    [ -n "$FILL" ] || FILL=" "
    LEN="`echo -n "$WORD" | wc -c`"
    SPACES="`expr $ROUND - $LEN`"
    if [ "$AL" = R ]; then
        for i in `seq 1 $SPACES`; do
            OUTPUT="$OUTPUT$FILL"
        done
        SPACES="1"
    else
        OUTPUT="$OUTPUT$FILL"
    fi
    OUTPUT="$OUTPUT`echo -n "$WORD" | tr '\n\t\r' '   '`"
    for i in `seq 1 $SPACES`; do
        OUTPUT="$OUTPUT$FILL"
    done
    echo -n "$OUTPUT"
}

TBL_NUM=5
TBL_TPE=10
TBL_SIZE=12
TBL_DATE=28
TBL_DESC=35
table_put() {
    round_output "$1" $TBL_NUM R
    echo -n "|"
    round_output "$2" $TBL_TPE
    echo -n "|"
    round_output "$3" $TBL_SIZE $SIZE_AL
    echo -n "|"
    round_output "$4" $TBL_DATE
    echo -n "| "
    echo "$5"
}

table_separator() {
    round_output "-" $TBL_NUM R  "-"
    echo -n "+"
    round_output "-" $TBL_TPE "" "-"
    echo -n "+"
    round_output "-" $TBL_SIZE "" "-"
    echo -n "+"
    round_output "-" $TBL_DATE "" "-"
    echo -n "+"
    round_output "-" $TBL_DESC "" "-"
    echo ""
}

generic_list() {
    JSON=""
    if [ "x$1" = x-j ]; then
        JSON="y"
    fi
    shift
    cd "$1"
    if [ -z "$JSON" ]; then
        table_put "#" Type Size Date Description
        SIZE_AL=R
        table_separator
    else
        echo -n '{ "snapshots": [ '
    fi
    FIRST="YES"
    for i in $(ls -1 "$1"/*.info | sed 's|.*/\([^/]*\).info|\1|' | sort -n); do
        CREATED=""
        DESCRIPTION=""
        TYPE="single"
        NUM="$i"
        SIZE=""
        # TODO: Maybe make sure to read only data we are interested in just in
        #       case somebody was tampering with our data file
        . "$1/$i.info"
        [ \! -d "$1/@$i" ] || SIZE="$(btrfs qgroup show -f "$1/@$i" | sed -n 's|.*[[:blank:]]\([0-9.MGKi]*B\)[[:blank:]]*$|\1|p')"
        [ \! -f "$1/$i".tar.gz ] || SIZE="$(du -sh "$1/$i".tar.gz | sed 's|[[:blank:]].*||')"
        [ \! -f "$1/$i".tar.gz.pgp ] || SIZE="$(du -sh "$1/$i".tar.gz.pgp | sed 's|[[:blank:]].*||')"
        if [ -z "$JSON" ]; then
            table_put "$NUM" "$TYPE" "$SIZE" "$CREATED" "$DESCRIPTION"
        else
            [ -n "$FIRST" ] || echo -n ", "
            echo -n "{ \"number\": $NUM, \"type\": \"$TYPE\", \"size\": \"$SIZE\", \"created\": \"$CREATED\", \"description\": \""
            echo -n "$(echo "$DESCRIPTION" | sed 's|\("\\\)|\\\1|g')"
            echo -n '" }'
            FIRST=""
        fi
    done
    [ "x$1" \!= x-j ] || echo " ] }"
}

list() {
    generic_list "$1" "$TMP_MNT_DIR"
}

get_next_number() {
    NUMBER="`btrfs subvolume list "$TMP_MNT_DIR" | sed -n 's|ID [0-9]* gen [0-9]* top level [0-9]* path @\([0-9][0-9]*\)$|\1|p' | sort -n | tail -n 1`"
    if [ -n "$NUMBER" ]; then
        NUMBER="`expr $NUMBER + 1`"
    else
        NUMBER=1
    fi
    echo $NUMBER
}

create() {
    DESCRIPTION=""
    TYPE="single"
    while [ -n "$1" ]; do
        if   [ "x$1" = "x-t" ]; then
            shift
            if [ "$1" \!= pre ] && [ "$1" \!= post ] && [ "$1" \!= time ] && [ "$1" \!= single ]; then
                die_helping "Incorrect snapshot type - '$1'"
            fi
            TYPE="$1"
            shift
        else
            [ -z "$DESCRIPTION" ] || DESCRIPTION="$DESCRIPTION "
            DESCRIPTION="${DESCRIPTION}${1}"
            shift
        fi
    done
    [ -n "$DESCRIPTION" ] || DESCRIPTION="User created snapshot"
    NUMBER="`get_next_number`"
    if btrfs subvolume snapshot "$TMP_MNT_DIR"/@ "$TMP_MNT_DIR"/@$NUMBER > /dev/null; then
        echo "TYPE=\"$TYPE\"" > "$TMP_MNT_DIR"/$NUMBER.info
        echo "DESCRIPTION=\"$DESCRIPTION\"" >> "$TMP_MNT_DIR"/$NUMBER.info
        echo "CREATED=\"`date "+%Y-%m-%d %H:%M:%S %z"`\"" >> "$TMP_MNT_DIR"/$NUMBER.info
        echo "Snapshot number $NUMBER created"
    else
        die "Error creating new snapshot"
    fi
}

modify() {
    NUMBER="$1"
    shift
    if [ \! -d "$TMP_MNT_DIR"/@$NUMBER ]; then
        die "Snapshot number $NUMBER does not exists!"
    fi
    TYPE="single"
    DESCRIPTION="User created snapshot"
    [ \! -f "$TMP_MNT_DIR"/$NUMBER.info ] || . "$TMP_MNT_DIR"/$NUMBER.info
    while [ -n "$1" ]; do
        if   [ "x$1" = "x-t" ]; then
            shift
            if [ "$1" \!= pre ] && [ "$1" \!= post ] && [ "$1" \!= time ] && [ "$1" \!= single ]; then
                die_helping "Incorrect snapshot type - '$1'"
            fi
            TYPE="$1"
            shift
        elif [ "x$1" = "x-d" ]; then
            shift
            DESCRIPTION="$1"
            shift
        else
            die_helping "Unknown create option '$1'"
        fi
    done
    echo "TYPE=\"$TYPE\"" > "$TMP_MNT_DIR"/$NUMBER.info
    echo "DESCRIPTION=\"$DESCRIPTION\"" >> "$TMP_MNT_DIR"/$NUMBER.info
    echo "CREATED=\"$CREATED\"" >> "$TMP_MNT_DIR"/$NUMBER.info
    echo "Snapshot number $NUMBER modified"
}

delete() {
    NUMBER="$1"
    if [ \! -d "$TMP_MNT_DIR"/@$NUMBER ]; then
        echo "WARNING: Snapshot number $NUMBER does not exists!"
        return 1
    fi
    if btrfs subvolume delete -c "$TMP_MNT_DIR"/@$NUMBER > /dev/null; then
        rm -f "$TMP_MNT_DIR"/$NUMBER.info
        echo "Snapshot $NUMBER deleted."
    else
        die "Error deleting snapshot $NUMBER"
    fi
}

rollback() {
    ROLL_TO="$1"
    if [ -n "$ROLL_TO" ] && [ \! -d "$TMP_MNT_DIR"/@$NUMBER ]; then
        die "Snapshot number $NUMBER does not exists!"
    fi
    if [ -z "$ROLL_TO" ]; then
        SKIP_TO=""
        for i in `btrfs subvolume list "$TMP_MNT_DIR" | sed -n 's|ID [0-9]* gen [0-9]* top level [0-9]* path @\([0-9][0-9]*\)$|\1|p' | sort -n -r` factory; do
            if [ "$i" \!= factory ] && [ -n "$SKIP_TO" ] && [ "$i" -ge "$SKIP_TO" ]; then
                continue
            fi
            TYPE="single"
            [ \! -f "$TMP_MNT_DIR"/$i.info ] || . "$TMP_MNT_DIR"/$i.info
            if [ "$TYPE" = "rollback" ]; then
                SKIP_TO="$ROLL_TO"
                continue
            fi
            ROLL_TO="$i"
            break
        done
    fi
    NUMBER="`get_next_number`"
    if ! mv "$TMP_MNT_DIR"/@ "$TMP_MNT_DIR"/@$NUMBER; then
        die "Can't make snapshot of current state"
    fi
    echo "TYPE=\"rollback\"" > "$TMP_MNT_DIR"/$NUMBER.info
    echo "DESCRIPTION=\"Rollback to snapshot $ROLL_TO\"" >> "$TMP_MNT_DIR"/$NUMBER.info
    echo "ROLL_TO=$ROLL_TO" >> "$TMP_MNT_DIR"/$NUMBER.info
    echo "CREATED=\"`date "+%Y-%m-%d %H:%M:%S %z"`\"" >> "$TMP_MNT_DIR"/$NUMBER.info
    if btrfs subvolume snapshot "$TMP_MNT_DIR"/@$ROLL_TO "$TMP_MNT_DIR"/@ > /dev/null; then
        echo "Current state saved as snapshot number $NUMBER"
        echo "Rolled back to snapshot $ROLL_TO"
        if [ -d /etc/schnapps/rollback.d ]; then
            for i in /etc/schnapps/rollback.d/*; do
                [ \! -x "$i" ] || "$i" "$TMP_MNT_DIR"/@
            done
        fi
        if [ -d "$TMP_MNT_DIR"/certbackup ]; then
            cp -ra "$TMP_MNT_DIR"/certbackup/* "$TMP_MNT_DIR"/@
        fi
    else
        rm -f "$TMP_MNT_DIR"/$NUMBER.info
        mv "$TMP_MNT_DIR"/@$NUMBER "$TMP_MNT_DIR"/@
        die "Rolling back failed!"
    fi
}

my_cmp() {
    if   [    -f "$1" ] && [ \! -f "$2" ]; then
        echo " - $3"
    elif [ \! -f "$1" ] && [    -f "$2" ]; then
        echo " + $3"
    elif ! cmp "$1" "$2" > /dev/null 2>&1; then
        echo " ~ $3"
    fi
}

my_status() {
    ( cd "$TMP_MNT_DIR"/@"$1"; find . -type f;
      cd "$TMP_MNT_DIR"/@"$2"; find . -type f ) | \
    sed 's|^\.||' | sort -u | while read fl; do
        my_cmp "$TMP_MNT_DIR"/@"$1"/"$fl" "$TMP_MNT_DIR"/@"$2"/"$fl" "$fl"
    done
}

cleanup() {
    if [ "x$1" = "x--compare" ]; then
        echo "Searching for snapshots without any change."
        echo "This can take a while, please be patient."
        echo
        LAST=""
        for i in `btrfs subvolume list "$TMP_MNT_DIR" | sed -n 's|ID [0-9]* gen [0-9]* top level [0-9]* path @\([0-9][0-9]*\)$|\1|p' | sort -n`; do
            if [ -z "$LAST" ]; then
                LAST="$i"
                continue
            fi
                echo " * checking snaphot $i..."
            if [ -z "`my_status "$LAST" "$i"`" ]; then
                delete "$LAST" | sed 's|^|   - |'
            fi
            LAST="$i"
        done
    fi
    if [ "$KEEP_MAX_SINGLE" -ge 0 ] || [ "$KEEP_MAX_TIME" -ge 0 ] || [ "$KEEP_MAX_UPDATER" -ge 0 ]; then
        echo "Looking for old snapshots..."
        KEEP_MAX_PRE="$KEEP_MAX_UPDATER"
        KEEP_MAX_POST="$KEEP_MAX_UPDATER"
        for i in `btrfs subvolume list "$TMP_MNT_DIR" | sed -n 's|ID [0-9]* gen [0-9]* top level [0-9]* path @\([0-9][0-9]*\)$|\1|p' | sort -n -r`; do
            TYPE="single"
            [ \! -f "$TMP_MNT_DIR"/$i.info ] || . "$TMP_MNT_DIR"/$i.info
            case $TYPE in
                single)
                    if [ "$KEEP_MAX_SINGLE" -eq 0 ]; then
                        delete "$i" | sed 's|^| - |'
                    else
                        KEEP_MAX_SINGLE="`expr $KEEP_MAX_SINGLE - 1`"
                    fi
                    ;;
                pre)
                    if [ "$KEEP_MAX_PRE" -eq 0 ]; then
                        delete "$i" | sed 's|^| - |'
                    else
                        KEEP_MAX_PRE="`expr $KEEP_MAX_PRE - 1`"
                    fi
                    ;;
                post)
                    if [ "$KEEP_MAX_POST" -eq 0 ]; then
                        delete "$i" | sed 's|^| - |'
                    else
                        KEEP_MAX_POST="`expr $KEEP_MAX_POST - 1`"
                    fi
                    ;;
                time)
                    if [ "$KEEP_MAX_TIME" -eq 0 ]; then
                        delete "$i" | sed 's|^| - |'
                    else
                        KEEP_MAX_TIME="`expr $KEEP_MAX_TIME - 1`"
                    fi
                    ;;
                rollback)
                    if [ "$KEEP_MAX_ROLLBACK" -eq 0 ]; then
                        delete "$i" | sed 's|^| - |'
                    else
                        KEEP_MAX_ROLLBACK="`expr $KEEP_MAX_ROLLBACK - 1`"
                    fi
                    ;;
            esac
        done
    fi
}

snp_diff() {
    if [ \! -d "$TMP_MNT_DIR"/@$1 ]; then
        echo "Snapshot number $1 does not exists!"
        ERR=3
        return
    fi
    if [ \! -d "$TMP_MNT_DIR"/@$2 ]; then
        echo "Snapshot number $2 does not exists!"
        ERR=3
        return
    fi
    ( cd "$TMP_MNT_DIR";
      diff -Nru @"$1" @"$2" 2> /dev/null )
}

snp_status() {
    if [ \! -d "$TMP_MNT_DIR"/@$1 ]; then
        echo "WARNING: Snapshot number $1 does not exists!"
        return
    fi
    if [ \! -d "$TMP_MNT_DIR"/@$2 ]; then
        echo "WARNING: Snapshot number $2 does not exists!"
        return
    fi
    SNAME="$2"
    [ -n "$SNAME" ] || SNAME="current"
    echo "Comparing snapshots $1 and $SNAME"
    echo "This can take a while, please be patient."
    echo "Meaning of the lines is following:"
    echo
    echo "   - file    file present in $1 and missing in $SNAME"
    echo "   + file    file not present in $1 but exists in $SNAME"
    echo "   ~ file    file in $1 differs from file in $SNAME"
    echo
    my_status "$1" "$2"
}

tar_it() {
    if [ -n "$GPG_PASS" ] && [ -n "`which gpg`" ]; then
        rm -rf /tmp/schnapps-gpg
        mkdir -p /tmp/schnapps-gpg/home
        chown -R root:root /tmp/schnapps-gpg
        chmod -R 0700 /tmp/schnapps-gpg
        export GNUPGHOME=/tmp/schnapps-gpg/home
        echo "$GPG_PASS" > /tmp/schnapps-gpg/pass
        tar -C "$1" --numeric-owner --one-file-system -cpvf "$2".gpg . \
        --use-compress-program="gzip -c - | gpg  \
        --batch --yes --passphrase-file /tmp/schnapps-gpg/pass \
        --cipher-algo=AES256 -c"
        ret="$?"
        rm -rf /tmp/schnapps-gpg
        return $ret
    else
        tar -C "$1" --numeric-owner --one-file-system -cpzvf "$2" .
        return $?
    fi
}

get_board() {
    case "$(cat /sys/firmware/devicetree/base/model 2> /dev/null)" in
        *Omnia*)
            BOARD="omnia"
            ;;
        *M[Oo][Xx]*)
            BOARD="mox"
            ;;
        *)
            BOARD="schnapps"
            ;;
    esac
}

export_sn() {
    get_board
    [ "$1" \!= current ] || shift
    if [ $# -eq 2 ]; then
        NAME="$1"
        NUMBER="$1"
        shift
    else
        NUMBER=""
        NAME=""
    fi
    [ -n "$NAME" ] || NAME="$(date +%Y%m%d)"
    TRG_PATH="$1"

    if [ $# -ne 1 ] || [ \! -d "$TMP_MNT_DIR"/@"$NUMBER" ] || [ \! -d "$TRG_PATH" ]; then
        die "Export takes target directory as argument!"
    fi
    INFO="$TRG_PATH/$BOARD-medkit-$HOSTNAME-$NAME.info"
    TAR="$TRG_PATH/$BOARD-medkit-$HOSTNAME-$NAME.tar.gz"
    if tar_it "$TMP_MNT_DIR"/@$NUMBER "$TAR" .; then
        [ \! -f "$TMP_MNT_DIR"/"$NUMBER.info" ] || cp "$TMP_MNT_DIR"/"$NUMBER.info" "$INFO"
        if [ -n "$NUMBER" ]; then
            echo "Snapshot $NUMBER was exported into $TRG_PATH as $BOARD-medkit-$NAME"
        else
            echo "Current system was exported into $TRG_PATH as $BOARD-medkit-$NAME"
        fi
    else
        die "Snapshot export failed!"
    fi
}

webdav_mount() {
    FINAL_REMOTE_URL="$(echo "$REMOTE_URL" | sed -e 's|webdav://|https://|')"
    [ -n "`which mount.davfs`" ] || die "davfs is not available"
    mkdir -p /tmp/.schnapps-dav
    touch /tmp/.schnapps-dav/config
    touch /tmp/.schnapps-dav/secret
    chown -R root:root /tmp/.schnapps-dav
    chmod 0700 /tmp/.schnapps-dav
    chmod 0600 /tmp/.schnapps-dav/*
    cat > /tmp/.schnapps-dav/config << EOF
use_locks 0
secrets /tmp/.schnapps-dav/secret
EOF
    echo "$FINAL_REMOTE_URL $REMOTE_USER $REMOTE_PASS" > /tmp/.schnapps-dav/secret
    mount.davfs "$FINAL_REMOTE_URL" "$TMP_RMT_MNT_DIR" -o dir_mode=0700,file_mode=0600,uid=root,gid=root,conf=/tmp/.schnapps-dav/config || die "Can't access remote filesystem"
}

remote_mount() {
    [ -z "$REMOTE_MOUNTED" ] || return
    mkdir -p "$TMP_RMT_MNT_DIR"
    case "$REMOTE_URL" in
        nextcloud://*)
            REMOTE_URL="$(echo "$REMOTE_URL" | sed -e 's|nextcloud://|webdav://|' -e 's|/*$|/remote.php/webdav/|')"
            webdav_mount
            ;;
        webdav://*)
            webdav_mount
            ;;
        ssh://*)
            FINAL_REMOTE_URL="$(echo "$REMOTE_URL" | sed -e 's|ssh://||')"
            expr "$FINAL_REMOTE_URL" : '.*:"' > /dev/null || FINAL_REMOTE_URL="$FINAL_REMOTE_URL:"
            [ -n "`which sshfs`" ] || die "sshfs is not available"
            sshfs "$FINAL_REMOTE_URL" "$TMP_RMT_MNT_DIR"
            ;;
        *) die "Invalid URL" ;;
    esac
    REMOTE_MOUNTED="yes"
}

remote_unmount() {
    [ -n "$REMOTE_MOUNTED" ] || return
    case "$REMOTE_URL" in
        nextcloud://*)
            umount -fl "$TMP_RMT_MNT_DIR" 2> /dev/null
            rm -rf /tmp/.schnapps-dav
            ;;
        webdav://*)
            umount -fl "$TMP_RMT_MNT_DIR" 2> /dev/null
            rm -rf /tmp/.schnapps-dav
            ;;
        ssh://*)
            fusermount -uz "$TMP_RMT_MNT_DIR" 2> /dev/null
            ;;
        *) die "Invalid URL" ;;
    esac
}

upload() {
    NUM=""
    if expr "$1" : '[0-9]*$' > /dev/null; then
        NUM="$1"
        shift
    fi
    [ -z "$1" ] || { REMOTE_URL="$1"; shift; }
    [ -z "$1" ] || { REMOTE_PATH="$1"; shift; }
    expr "$REMOTE_PATH" : '/' > /dev/null || REMOTE_PATH="/$REMOTE_PATH"
    remote_mount
    export_sn "$NUM" "$TMP_RMT_MNT_DIR""$REMOTE_PATH" | sed "s|^\\([^.].*exported.*\\)$TMP_RMT_MNT_DIR|\\1$REMOTE_URL|"
}

sync_snps() {
    remote_mount
    if [ "x$1" = "x-t" ]; then
        SYNC_TYPES="$2"
        [ "$2" \!= all ] || SYNC_TYPES="$DEFAULT_SYNC_TYPES"
    fi
    get_board
    NUMS="$(ls -1 "$TMP_MNT_DIR"/*.info | sed 's|.*/\([0-9]*\).info$|\1|')"
    RM_NUMS="$(ls -1 "$TMP_RMT_MNT_DIR"/"$REMOTE_PATH"/*-medkit-$HOSTNAME-*.info 2> /dev/null | sed 's|.*/.*-\([0-9]*\).info$|\1|')"
    for i in $NUMS; do
        . "$TMP_MNT_DIR"/"$i".info
        if expr "$SYNC_TYPES" : ".*$TYPE.*" > /dev/null; then
            [ -f "$TMP_RMT_MNT_DIR"/"$REMOTE_PATH"/"$BOARD-medkit-$HOSTNAME-$i.info" ] || upload "$i"
        fi
        RM_NUMS="$(echo "$RM_NUMS" | grep -v "^$i\$")"
    done
    for i in $RM_NUMS; do
        rm -f "$TMP_RMT_MNT_DIR"/"$REMOTE_PATH"/"$BOARD-medkit-$HOSTNAME-$i.info" \
              "$TMP_RMT_MNT_DIR"/"$REMOTE_PATH"/"$BOARD-medkit-$HOSTNAME-$i.tar.gz" \
              "$TMP_RMT_MNT_DIR"/"$REMOTE_PATH"/"$BOARD-medkit-$HOSTNAME-$i.tar.gz.pgp"
    done
}

remote_list() {
    remote_mount
    TBL_NUM=20
    generic_list "$1" "$TMP_RMT_MNT_DIR"/"$REMOTE_PATH"
}


import_sn() {
    if [ "x-f" = "x$1" ]; then
        shift
        TAR="$1"
        INFO=""
    else
        INFO="$1"
        TAR="$(echo "$INFO" | sed -n 's|.info$|.tar.gz|p')"
        if [ $# -ne 1 ] || [ \! -f "$INFO" ] || [ \! -f "$TAR" ]; then
            echo "Import takes one argument which is snapshot info file!"
            die "Actual tarball has to be next to it!"
        fi
    fi
        
    NUMBER="`get_next_number`"
    if btrfs subvolume create "$TMP_MNT_DIR"/@$NUMBER > /dev/null; then
        if tar -C "$TMP_MNT_DIR"/@$NUMBER --numeric-owner -xpzvf "$TAR"; then
            if [ -n "$INFO" ]; then
                cp "$INFO" "$TMP_MNT_DIR"/@$NUMBER.info
                echo "Snapshot imported as number $NUMBER"
                echo "Due to the nature of import, deduplication doesn't work, so it occupies a lot of space."
                echo "You have been warned!"
            else
                mv "$TMP_MNT_DIR"/@factory "$TMP_MNT_DIR"/@factory-old
                mv "$TMP_MNT_DIR"/@$NUMBER "$TMP_MNT_DIR"/@factory
                btrfs subvolume delete -c "$TMP_MNT_DIR"/@factory-old
                echo "Your factory image was updated!"
            fi
        else
            btrfs subvolume delete "$TMP_MNT_DIR"/@$NUMBER
            die "Tarball seems to be corrupted"
        fi
    else
        die "Error creating new snapshot"
    fi
}

mount_root
trap 'umount_root; remote_unmount; exit "$ERR"' EXIT INT QUIT TERM ABRT
command="$1"
shift
case $command in
    create)
        create "$@"
        ;;
    modify)
        modify "$@"
        ;;
    export)
        export_sn "$@"
        ;;
    upload)
        upload "$@"
        ;;
    import)
        import_sn "$@"
        ;;
    list)
        list "$@"
        ;;
    rlist)
        remote_list "$@"
        ;;
    cleanup)
        cleanup "$@"
        ;;
    sync)
        sync_snps "$@"
        ;;
    delete)
        for i in "$@"; do
            delete "$i"
        done
        ;;
    rollback)
        rollback "$1"
        ;;
    mount)
        for i in "$@"; do
            mount_snp "$i"
        done
        ;;
    cmp)
        if [ $# -gt 2 ]; then
            die_helping "Wrong number of arguments"
        else
            LAST="$1"
            [ $# -gt 0 ]   || LAST="`btrfs subvolume list "$TMP_MNT_DIR" | sed -n 's|ID [0-9]* gen [0-9]* top level [0-9]* path @\([0-9][0-9]*\)$|\1|p' | sort -n | tail -n 1`"
            [ -n "$LAST" ] || LAST="factory"
            snp_status "$LAST" "$2"
        fi
        ;;
    diff)
        if ! which diff > /dev/null; then
            echo "Utility diff not found!"
            die "Please install diffutils package"
        fi
        if [ $# -gt 2 ]; then
            die_helping "Wrong number of arguments"
        else
            LAST="$1"
            [ $# -gt 0 ]   || LAST="`btrfs subvolume list "$TMP_MNT_DIR" | sed -n 's|ID [0-9]* gen [0-9]* top level [0-9]* path @\([0-9][0-9]*\)$|\1|p' | sort -n | tail -n 1`"
            [ -n "$LAST" ] || LAST="factory"
            snp_diff "$LAST" "$2"
        fi
        ;;
    help)
        show_help
        ;;
    *)
        die_helping "Unknown command $command!"
        ;;
esac
exit 0
