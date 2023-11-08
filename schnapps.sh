#!/bin/sh
#
# Btrfs snapshots managing script
# (C) 2016-2021 CZ.NIC, z.s.p.o.
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

# Defaults
TMP_MNT_DIR="/mnt/.snapshots"
TMP_RMT_MNT_DIR="/mnt/.remote-snapshots"
TEMP_DIR=""
ATQ="s" # 'at' queue to use
LOCK="/tmp/schnapps.lock"
SYNC_TYPES="pre,post,time,single,rollback"
DEFAULT_SYNC_TYPES="$SYNC_TYPES"
ERR=0
TMP_DIR=""
KEEP_MAX=""
KEEP_MAX_SINGLE=-1
KEEP_MAX_TIME=-1
KEEP_MAX_UPDATER=-1
KEEP_MAX_ROLLBACK=-1
REMOTE_URL=""
REMOTE_MOUNTED=""
REMOTE_PATH=""
REMOTE_USER=
REMOTE_PASS=
REMOTE_KEEP="0"
GPG_PASS=""
ROOT_DEV="$(btrfs fi show / | sed -n 's|.*\(/dev/[^[:blank:]]*\)$|\1|p' | head -n 1)"
VERSION="@VERSION@"

die() {
    echo "$@" >&2
    ERR="${ERR:-1}"
    exit 1
}

# Read uci configuration if available
if [ -f "/lib/functions.sh" ]; then
    . /lib/functions.sh
    config_load schnapps
    config_get KEEP_MAX_SINGLE keep max_single "$KEEP_MAX_SINGLE"
    config_get KEEP_MAX_TIME keep max_time "$KEEP_MAX_TIME"
    config_get KEEP_MAX_UPDATER keep max_updater "$KEEP_MAX_UPDATER"
    config_get KEEP_MAX_ROLLBACK keep max_rollback "$KEEP_MAX_ROLLBACK"
    config_get REMOTE_URL remote url "$REMOTE_URL"
    config_get REMOTE_PATH remote path "$REMOTE_PATH"
    config_get REMOTE_USER remote user "$REMOTE_USER"
    config_get REMOTE_PASS remote password "$REMOTE_PASS"
    config_get REMOTE_KEEP remote keep_forever "$REMOTE_KEEP"
    config_get SYNC_TYPES remote sync_types "$SYNC_TYPES"
    config_get GPG_PASS encrypt pass "$GPG_PASS"
fi

[ \! -f /etc/schnapps/config ] || . /etc/schnapps/config

if [ "$1" = "-d" ]; then
    ROOT_DEV="$(btrfs fi show $2 | sed -n 's|.*\(/dev/[^[:blank:]]*\)$|\1|p')"
    shift 2
fi

[ -z "$ROOT_DEV" ] || ROOT_LABEL="$(btrfs fi label "$ROOT_DEV")"
[ -z "$ROOT_LABEL" ] || [ \! -f /etc/schnapps/"$ROOT_LABEL" ] || . /etc/schnapps/"$ROOT_LABEL"

# Usage help
USAGE="Usage: $(basename "$0") [-d root] command [options]

Commands:
  create [opts] [desc]    Creates snapshot of current system.
      Options:
          -t type         Type of the snapshot - default 'single'.
                          Other options are 'time', 'pre' and 'post'.

  list [opts]             Show available snapshots.
      Options:
          -j              Output in json format.
          -c              Output in csv format.

  rlist [opts]            Show uploaded snapshots.
      Options:
          -j              Output in json format.
          -c              Output in csv format.

  cleanup [-c]            Deletes old snapshots and keeps only N newest.
                          You can set number of snapshots to keep in /etc/config/schnapps.
                          Current value of N is following for various types (-1 means infinite):
                           * $KEEP_MAX_SINGLE single snapshots
                           * $KEEP_MAX_TIME time based snapshots
                           * $KEEP_MAX_UPDATER updater snapshots
                           * $KEEP_MAX_ROLLBACK rollback backups snapshots
                          With --compare option also deletes snapshots that doesn't differ from
                          the previous one.

  delete <what>...        Deletes corresponding snapshots.
                          Arguments can be either snapshot number or type specification.
                          Numbers can be found via list command.
                          Type can be specified by '-t type' to delete all snapshots of specific
                          type.

  modify <number> [opts]  Modify metadata of snapshot corresponding to the number.
                          Numbers can be found via list command.
      Options:
          -t type         Type of the snapshot - default 'single'
                          Other options are 'time', 'pre' and 'post'.
          -d description  Some note about the snapshot.

  rollback [number]       Make snapshot corresponding to the number default for next boot.
                          If called without any argument, go one step back.
                          Numbers can be found via list command.

  savepoint [minutes]     Create snapshot and rollback to it in specified time unless committed.
                          Default is 10 minutes. Subsequent calls to savepoint function will
                          commit the current state and reschedule the reboot.

  commit                  Abort scheduled rollbacks and delete all savepoints.

  mount <number>...       Mount snapshot corresponding to the number(s).
                          You can then browse it and you have to umount it manually.
                          Numbers can be found via list command.

  cmp [#] [#] [path]      Compare snapshots corresponding to the numbers.
                          Additionally can be limited to specific subdirectory specified as path.
                          Numbers can be found via list command.
                          Shows just which files differs.

  diff [#] [#] [path]     Compare snapshots corresponding to the numbers.
                          Additionally can be limited to specific subdirectory specified as path.
                          Numbers can be found via list command.
                          Shows even diffs of individual files.

  export [-c] [snapshot] (path|-)
                          Export snapshot as a medkit into a directory in the specified path or to
                          stdout if path is equal to '-'. Snapshot argument can be snapshot number
                          or omitted to backup running system.

                          Exports are encrypted with pgp, if password is set. Option '-c' can be used
                          to override this and to export unencrypted medkit.

  upload [snapshot] [[url] [path]]
                          Upload snapshot as a medkit into specified folder on WebDAV, Nextcloud
                          or SSH server.
                          Snapshot argument can be snapshot number or ommited to backup running
                          system.
                          If the URL for SSH contains a relative path (no leading slash) or no
                          path at all then the path specified is treated relatively to the home
                          directory of login user.

  sync [-t type,type]     Make sure that all snapshots of specified type are backed up on the
                          server.
                          Multiple types can be divided by commas.

  import [-f] path        Import exported snapshot; path must point to .info file for the
                          snapshot. Except when importing factory image with -f option, then it
                          has to be a tarball, but it can be an URL as well.

  update-factory          Updates factory image, if the devices is supported.

  factory-version         Display version of the image stored in factory snapshot.

  help                    Display this help

  version                 Display version
"

show_help() {
    echo "$USAGE"
}

die_helping() {
    die "$@" "

`show_help`"
}

DESCRIPTION_LIMIT=1024
filter_description() {
    echo -n "$1" \
        | tr -c 'a-zA-Z0-9 .,?!()/;:<>-' '_' \
        | head -c "$DESCRIPTION_LIMIT"
    echo
}

mount_root() {
    if ! mkdir "$LOCK"; then
        echo "Another instance seems to be running!"
        exit 2
    fi
    mkdir -p "$TMP_MNT_DIR" || die "Can't create a temp directory"
    if [ -n "`ls -A "$TMP_MNT_DIR"`" ]; then
        rmdir "$LOCK"
        echo "ERROR: Something is already in '$TMP_MNT_DIR'"
        exit 2
    fi
    mount "$ROOT_DEV" -o subvol=/ "$TMP_MNT_DIR" || die "Can't mount root partition"
    btrfs qgroup show "$TMP_MNT_DIR" > /dev/null 2>&1 || btrfs quota enable "$TMP_MNT_DIR"
}

mount_snp() {
    if [ $# != 1 ]; then
        die_helping "Wrong number of arguments"
    fi
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

TBL_NUM=4

generic_list() {
    local format="human"
    [ "$1" = '-j' ] && format="json"
    [ "$1" = '-c' ] && format="csv"
    local dir="$2"
    cd "$dir"
    case "$format" in
        human)
            printf " $(printf "%0.s " $(seq 2 $TBL_NUM))# | Type      | Size        | Date                      | Description\n"
            printf "-$(printf "%0.s-" $(seq $TBL_NUM))-+-----------+-------------+---------------------------+------------------------------------\n"
            ;;
        json)
            echo '{ "snapshots": ['
            ;;
        csv)
            echo '#,type,size,date,description'
            ;;
    esac
    local first="y"
    find "$dir" -maxdepth 1 -mindepth 1 | sed -n 's|.*/\([^[:blank:]]*[0-9]\+\)\.info|\1|p' | sort -n \
        | while read -r snapshot; do
            CREATED=""
            DESCRIPTION=""
            TYPE="single"
            SIZE=""
            # TODO: Maybe make sure to read only data we are interested in just in
            #       case somebody was tampering with our data file
            . "$dir/$snapshot.info"
            DESCRIPTION="$(filter_description "$DESCRIPTION")"
            [ ! -d "$dir/@$snapshot" ] \
                || SIZE="$(btrfs qgroup show -f "$dir/@$snapshot" | sed -n 's|.*[[:blank:]]\([0-9.MGKi]*B\)[[:blank:]]*$|\1|p')"
            [ ! -d "$dir/@$snapshot" -a -z "$SIZE" ] \
                || SIZE="$(btrfs qgroup show -f "$dir/@$snapshot" | sed -n 's|.*[[:blank:]]\([0-9.MGKi]*B\)[[:blank:]]*'"@$snapshot"'[[:blank:]]*$|\1|p')"
            [ ! -f "$dir/$snapshot".tar.gz ] \
                || SIZE="$(du -sh "$dir/$snapshot".tar.gz | sed 's|[[:blank:]].*||')"
            [ ! -f "$dir/$snapshot".tar.gz.pgp ] \
                || SIZE="$(du -sh "$dir/$snapshot".tar.gz.pgp | sed 's|[[:blank:]].*||')"
            case "$format" in
                human)
                    printf " %${TBL_NUM}s | %-9s | %11s | %25s | %s\n" "$snapshot" "$TYPE" "$SIZE" "$CREATED" "$DESCRIPTION"
                    ;;
                json)
                    [ "$first" = "y" ] || echo ", "
                    printf '  { "id": "%s", "type": "%s", "size": "%s", "created": "%s", "description": "%s" }' "$snapshot" "$TYPE" "$SIZE" "$CREATED" "$DESCRIPTION"
                    first=""
                    ;;
                csv)
                    [ "${DESCRIPTION%%*,}" = "$DESCRIPTION" ] || DESCRIPTION="\"$DESCRIPTION\""
                    printf '%s,%s,%s,%s,%s\n' "$snapshot" "$TYPE" "$SIZE" "$CREATED" "$DESCRIPTION"
                    ;;
            esac
        done
    [ "$format" = "json" ] && printf "\n] }\n"
}

list() {
    if [ $# -gt 1 ]; then
        die_helping "Wrong number of arguments"
    fi
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
    NUMERIC=""
    while [ -n "$1" ]; do
        if   [ "$1" = "-n" ]; then
            NUMERIC="y"
            shift
        elif   [ "$1" = "-t" ]; then
            shift
            if echo "$1" | grep -vqE '^(pre|post|time|single|save)$'; then
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
    OLD_DESCRIPTION="$DESCRIPTION"
    DESCRIPTION="$(filter_description "$DESCRIPTION")"
    if [ "$DESCRIPTION" != "$OLD_DESCRIPTION" ]; then
        echo "Description modified to '$DESCRIPTION' as it contained unsupported characters or was too long" >&2
    fi

    NUMBER="`get_next_number`"
    if btrfs subvolume snapshot "$TMP_MNT_DIR"/@ "$TMP_MNT_DIR"/@$NUMBER > /dev/null; then
        echo "TYPE=\"$TYPE\"" > "$TMP_MNT_DIR"/$NUMBER.info
        echo "DESCRIPTION=\"$DESCRIPTION\"" >> "$TMP_MNT_DIR"/$NUMBER.info
        echo "CREATED=\"`date "+%Y-%m-%d %H:%M:%S %z"`\"" >> "$TMP_MNT_DIR"/$NUMBER.info
        if [ -n "$NUMERIC" ]; then
            echo "$NUMBER"
        else
            echo "Snapshot number $NUMBER created"
        fi
    else
        die "Error creating new snapshot"
    fi
}

modify() {
    if [ $# = 0 ]; then
        die_helping "Wrong number of arguments"
    fi
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
    if [ $# != 1 ]; then
        die_helping "Wrong number of arguments"
    fi
    NUMBER="$1"
    if [ \! -d "$TMP_MNT_DIR"/@$NUMBER ]; then
        echo "WARNING: Snapshot number $NUMBER does not exists!"
        return 1
    fi
    # Recursively remove all subvolumes to ensure removal of snapshot
    btrfs subvolume list -o "$TMP_MNT_DIR/@$NUMBER" | sed -n "s|^.*path @$NUMBER/||p" | while read subvol; do
        btrfs subvolume delete -c "$TMP_MNT_DIR/@$NUMBER/$subvol"
    done
    if btrfs subvolume delete -c "$TMP_MNT_DIR"/@$NUMBER > /dev/null; then
        rm -f "$TMP_MNT_DIR"/$NUMBER.info
        echo "Snapshot $NUMBER deleted."
    else
        die "Error deleting snapshot $NUMBER"
    fi
}

rollback() {
    if [ $# -gt 1 ]; then
        die_helping "Wrong number of arguments"
    fi
    ROLL_TO="$1"
    if [ -n "$ROLL_TO" ] && [ \! -d "$TMP_MNT_DIR"/@$ROLL_TO ]; then
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
    ( cd "$TMP_MNT_DIR"/@"$1""$3"; find . -type f;
      cd "$TMP_MNT_DIR"/@"$2""$3"; find . -type f ) | \
    sed 's|^\.||' | sort -u | while read fl; do
        my_cmp "$TMP_MNT_DIR"/@"$1"/"$fl" "$TMP_MNT_DIR"/@"$2"/"$fl" "$fl"
    done
}

cleanup() {
    if [ $# -gt 1 ]; then
        die_helping "Wrong number of arguments"
    fi
    for info in "$TMP_MNT_DIR"/*.info; do
        [ -f "$info" ] || continue
        [ -d "$TMP_MNT_DIR/@`basename "$info" .info`" ] || rm "$info"
    done
    # long option --compare for the backward compatibility
    if [ "$1" = "-c" -o "$1" = "--compare" ]; then
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
    elif [ "$1" ]; then
        die_helping "Invalid argument $1"
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
    if [ $# -gt 3 ]; then
        die_helping "Wrong number of arguments"
    fi
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
      diff -Nru @"$1""$3" @"$2""$3" 2> /dev/null )
}

snp_status() {
    if [ $# -gt 3 ]; then
        die_helping "Wrong number of arguments"
    fi
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
    echo "Comparing snapshots $1 and $SNAME within path "$3""
    echo "This can take a while, please be patient."
    echo "Meaning of the lines is following:"
    echo
    echo "   - file    file present in $1 and missing in $SNAME"
    echo "   + file    file not present in $1 but exists in $SNAME"
    echo "   ~ file    file in $1 differs from file in $SNAME"
    echo
    my_status "$1" "$2" "$3"
}

tar_it() {
    local dir="$1"
    local output="$2"
    if [ -d /etc/schnapps/export-exclude.d ] && \
       [ -n "$(ls /etc/schnapps/export-exclude.d/* 2> /dev/null)" ]; then
        mk_tmp_dir
        cat /etc/schnapps/export-exclude.d/* > "$TEMP_DIR/export-exclude"
        EXCLUDE="--exclude-from=$TEMP_DIR/export-exclude"
    fi
    [ ! -d /etc/schnapps/export-overlay ] || OVERLAY="-C /etc/schnapps/export-overlay ."
    if [ -n "$GPG_PASS" ] && [ -n "$(which gpg)" ]; then
        mk_tmp_dir
        mkdir -p "$TEMP_DIR/gpg"
        chmod -R 0700 "$TEMP_DIR/gpg"
        export GNUPGHOME="$TEMP_DIR/gpg"
        echo "$GPG_PASS" > "$TEMP_DIR/gpg/pass"
        [ "$output" = '-' ] || output="$output.gpg"
        tar --numeric-owner $EXCLUDE --one-file-system -cpvf "$output" \
            --use-compress-program="gzip -c - | gpg  --batch --yes \
                --passphrase-file \"$TEMP_DIR/gpg/pass\" --cipher-algo=AES256 -c" \
            -C "$dir" . $OVERLAY
        ret="$?"
        return $ret
    else
        tar --numeric-owner $EXCLUDE --one-file-system -cpzvf "$output" -C "$dir" . $OVERLAY
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

    if [ $# -ne 1 ] || [ ! -d "$TMP_MNT_DIR"/@"$NUMBER" ] || [ ! -d "$TRG_PATH" -a "$TRG_PATH" != '-' ]; then
        die "Export takes target directory or '-' as an argument!"
    fi
    if [ "$TRG_PATH" = '-' ]; then
        TAR="-"
    else
        INFO="$TRG_PATH/$BOARD-medkit-$HOSTNAME-$NAME.info"
        TAR="$TRG_PATH/$BOARD-medkit-$HOSTNAME-$NAME.tar.gz"
    fi
    if [ -z "$REMOTE_PATH" ]; then
        REMOTE_PATH="localhost"
        REMOTE_URL="$TRG_PATH"
    fi
    if tar_it "$TMP_MNT_DIR"/@$NUMBER "$TAR" .; then
        [ ! -f "$TMP_MNT_DIR"/"$NUMBER.info" ] || [ "$TAR" = "-" ] || cp "$TMP_MNT_DIR"/"$NUMBER.info" "$INFO"
        if [ -n "$NUMBER" ]; then
            echo "Snapshot $NUMBER was exported into $REMOTE_PATH as $TAR" >&2
        else
            echo "Current system was exported into $REMOTE_PATH as $TAR" >&2
        fi
    else
        die "Snapshot export failed!"
    fi
}

webdav_mount() {
    FINAL_REMOTE_URL="$(echo "$REMOTE_URL" | sed -e 's|webdav://|https://|')"
    [ -n "`which mount.davfs`" ] || die "davfs is not available"
    mk_tmp_dir
    cat > "$TEMP_DIR"/dav-config << EOF
use_locks 0
secrets "$TEMP_DIR/dav-secret"
EOF
    echo "$TMP_RMT_MNT_DIR \"$REMOTE_USER\" \"$REMOTE_PASS\"" > "$TEMP_DIR"/dav-secret
    chmod 0600 "$TEMP_DIR/dav-secret"
    mount.davfs "$FINAL_REMOTE_URL" "$TMP_RMT_MNT_DIR" -o dir_mode=0700,file_mode=0600,uid=root,gid=root,conf="$TEMP_DIR"/dav-config || die "Can't access remote filesystem"
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
            FINAL_REMOTE_URL="$(echo "$REMOTE_URL" | sed -e 's|ssh://||' | sed -e 's|^\([^:/]*\)/|\1:/|')"
            expr "$FINAL_REMOTE_URL" : '.*:' > /dev/null || FINAL_REMOTE_URL="$FINAL_REMOTE_URL:"
            [ -n "`which sshfs`" ] || die "sshfs is not available"
            sshfs "$FINAL_REMOTE_URL" "$TMP_RMT_MNT_DIR" || die "Can't access remote filesystem"
            ;;
        local://*|file://*)
            FINAL_REMOTE_URL="$(echo "$REMOTE_URL" | sed -e 's|^local://*|/|' -e 's|^file://*|/|')"
            mount -o bind "$FINAL_REMOTE_URL" "$TMP_RMT_MNT_DIR" || die "Can't bind-mount local filesystem"
            ;;
        smb:*|cifs:*)
            local final_remote_url="$(echo "$REMOTE_URL" | sed -n 's|^[a-z:0-9.]*://|//|p')"
            [ -n "$final_remote_url" ] || die "Invalid samba url $REMOTE_URL"
            local domain="$(echo "$REMOTE_URL" | cut -d / -f 3)"
            local vers="$(echo "$REMOTE_URL" | sed -n 's|^[a-z]*:\([0-9.]\+\)://.*|\1|p')"
            local opts
            if [ -n "$REMOTE_USER" ]; then
                mk_tmp_dir
                printf "username=%s\npassword=%s\ndomain=%s\n" \
                    "$REMOTE_USER" "$REMOTE_PASS" "$domain" > "$TEMP_DIR/samba-pass"
                opts="credentials=$TEMP_DIR/samba-pass"
            else
                opts="guest"
            fi
            if [ -n "$vers" ]; then
                opts="$opts,vers=$vers"
            fi
            mount.cifs "$final_remote_url" -o "$opts" "$TMP_RMT_MNT_DIR" || die "Can't access remote filesystem"
            ;;
        *) die "Invalid URL - $REMOTE_URL" ;;
    esac
    REMOTE_MOUNTED="yes"
}

remote_unmount() {
    [ -n "$REMOTE_MOUNTED" ] || return
    case "$REMOTE_URL" in
        ssh://*)
            fusermount -uz "$TMP_RMT_MNT_DIR" 2> /dev/null
            ;;
        *)
            umount -fl "$TMP_RMT_MNT_DIR" 2> /dev/null
            ;;
    esac
}

upload() {
    if [ $# = 0 ]; then
        die_helping "Wrong number of arguments"
    fi
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

info2num() {
    echo "$1" | sed -n 's|.*[/-]\([0-9]*\).info$|\1|p'
}

sync_snps() {
    remote_mount
    if [ "x$1" = "x-t" ]; then
        SYNC_TYPES="$2"
        [ "$2" \!= all ] || SYNC_TYPES="$DEFAULT_SYNC_TYPES"
        if [ "$3" ]; then
            die_helping "Wrong number of arguments"
        fi
    elif [ "$1" ]; then
        die_helping "Invalid argument"
    fi
    get_board
    for info in "$TMP_MNT_DIR"/*.info; do
        [ -f "$info" ] || continue
        . "$info"
        local num="$(info2num "$info")"
        if expr "$SYNC_TYPES" : ".*$TYPE.*" > /dev/null; then
            [ -f "$TMP_RMT_MNT_DIR/$REMOTE_PATH/$BOARD-medkit-$HOSTNAME-$num.info" ] \
                || upload "$num"
        fi
    done
    if [ "$REMOTE_KEEP" != 1 ]; then
        for info in "$TMP_RMT_MNT_DIR/$REMOTE_PATH/$BOARD-medkit-$HOSTNAME-"*.info; do
            [ -f "$info" ] || continue
            local num="$(info2num "$info")"
            [ \! -f "$TMP_MNT_DIR/$num.info" ] || continue
            rm -f "$TMP_RMT_MNT_DIR/$REMOTE_PATH/$BOARD-medkit-$HOSTNAME-$num.info" \
                  "$TMP_RMT_MNT_DIR/$REMOTE_PATH/$BOARD-medkit-$HOSTNAME-$num.tar.gz" \
                  "$TMP_RMT_MNT_DIR/$REMOTE_PATH/$BOARD-medkit-$HOSTNAME-$num.tar.gz.pgp"
        done
    fi
}

remote_list() {
    if [ $# != 1 ]; then
        die_helping "Wrong number of arguments"
    fi
    remote_mount
    TBL_NUM=20
    generic_list "$1" "$TMP_RMT_MNT_DIR"/"$REMOTE_PATH"
}

mk_tmp_dir() {
    [ -z "$TEMP_DIR" ] || return
    TEMP_DIR="$(mktemp -d)"
    chown -R root:root "$TEMP_DIR"
    chmod 0700 "$TEMP_DIR"
    [ -n "$TEMP_DIR" ] || die "Can't create a temp dir"
}

download_tar() {
    mk_tmp_dir
    local tmpdir="$TEMP_DIR/tar_download"
    mkdir -p "$tmpdir"
    [ -d "$tmpdir" ] || die "Can't create a tmp directory"
    local tar="$tmpdir/factory.tar.gz"
    wget -O "$tar" "$1" || die "Can't donwload '$1'"
    for sum in md5 sha256; do
        if wget -O "$tar"."$sum" "$1"."$sum"; then
            sed "s|[^[:blank:]]*\$|$tar|" "$tar.$sum" | ${sum}sum -c - \
                || die "Checksum doesn't match for '$1'"
        else
            rm -f "$tar"."$sum"
        fi
    done >&2
    echo "$tar"
}

import_sn() {
    if [ $# = 0 ] || [ $# -gt 2 ]; then
        die_helping "Wrong number of arguments"
    fi
    if [ "x-f" = "x$1" ]; then
        shift
        case "$1" in
            https://*) TAR="$(download_tar "$1")";;
            http://*)  die "http:// not supported, use https:// instead!";;
            file://*)  TAR="${1#file://}";;
            *://*)     die "Url $1 is not supported!";;
            *)         TAR="$1";;
        esac
        INFO=""
    else
        INFO="$1"
        TAR="$(echo "$INFO" | sed -n 's|.info$|.tar.gz|p')"
        if [ $# -ne 1 ] || [ \! -f "$INFO" ] || [ \! -f "$TAR" ]; then
            echo "Import takes one argument which is snapshot info file!"
            die "Actual tarball has to be next to it!"
        fi
    fi
    [ -r "$TAR" ] || die "No valid tarball found!"

    NUMBER="`get_next_number`"
    if btrfs subvolume create "$TMP_MNT_DIR"/@$NUMBER > /dev/null; then
        if tar -C "$TMP_MNT_DIR"/@$NUMBER --numeric-owner -xpzvf "$TAR"; then
            if [ -n "$INFO" ]; then
                cp "$INFO" "$TMP_MNT_DIR"/$NUMBER.info
                echo "Snapshot imported as number $NUMBER"
                echo "Due to the nature of import, deduplication doesn't work, so it occupies a lot of space."
                echo "You have been warned!"
            else
                if [ -d "$TMP_MNT_DIR"/@factory ]; then
                    mv "$TMP_MNT_DIR"/@factory "$TMP_MNT_DIR"/@factory-old
                else
                    echo "No factory image present, this will be the first one"
                fi
                mv "$TMP_MNT_DIR"/@$NUMBER "$TMP_MNT_DIR"/@factory
                [ \! -d "$TMP_MNT_DIR"/@factory-old ] || btrfs subvolume delete -c "$TMP_MNT_DIR"/@factory-old
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

delete_type() {
    if [ $# != 1 ]; then
        die_helping "Wrong number of arguments"
    fi
    # .info files are named ${SNAPSHOT_NUMBER}.info
    grep -l "TYPE=\"$1\"" "$TMP_MNT_DIR"/*.info | \
      sed -n 's|.*/\([0-9]\+\)\.info$|\1|p' | \
      while read -r snapshot; do
        delete "$snapshot"
    done
}

savepoint() {
    if [ $# -gt 1 ]; then
        die_helping "Wrong number of arguments"
    fi
    local time="$1"
    [ -n "$time" ] || time=10
    commit
    local number="$(create -n -t save "Temporal snapshot used for automatic rollback")"
    local wall_cmd=""
    if which wall >2 /dev/null >&2; then
        wall_cmd="echo \"15 seconds till reboot, commit current changes by calling 'schnapps commit' to avoid that.\" | wall; sleep 15;"
    fi
    echo "$wall_cmd schnapps rollback $number; reboot" | at -q "$ATQ" now + "$time" min
    echo "Do your changes, automatic rollback and reboot is scheduled $time minutes in the future."
}

commit() {
    local job junk
    atq -q "$ATQ" \
        | while read -r job junk; do
            atrm "$job"
        done
    delete_type save
}

trap_cleanup() {
    umount_root
    remote_unmount
    [ -z "$TEMP_DIR" ] || rm -rf "$TEMP_DIR"
    exit "$ERR"
}

command="$1"
shift
case $command in
    help)
        show_help
        exit 0
        ;;
    version)
        echo "Schnapps version $VERSION"
        exit 0
        ;;
esac

[ -n "$ROOT_DEV" ] || die "Can't figure out device to work on"
trap 'trap_cleanup' EXIT INT QUIT TERM ABRT
mount_root

case $command in
    create)
        create "$@"
        ;;
    modify)
        modify "$@"
        ;;
    export)
        if [ "$1" = '-c' ]; then
            GPG_PASS=""
            shift
        fi
        export_sn "$@"
        ;;
    upload)
        upload "$@"
        ;;
    update-factory)
        get_board
        if [ "$BOARD" != schnapps ]; then
            old_hash="$(cat "$TMP_MNT_DIR/@factory/.image_hash" 2> /dev/null)"
            new_hash="$(wget -O - "https://repo.turris.cz/hbs/medkit/$BOARD-medkit-latest.tar.gz.sha256")"
            [ -n "$new_hash" ] || die "Can't get a hash of new factory image!"
            if [ "$old_hash" = "$new_hash" ]; then
                echo "No update available, latest image available is already your factory image."
            else
                import_sn -f "https://repo.turris.cz/hbs/medkit/$BOARD-medkit-latest.tar.gz"
                echo "$new_hash" > "$TMP_MNT_DIR/@factory/.image_hash"
            fi
        else
            die "Don't know what device I am, can't update my factory image"
        fi
        ;;
    factory-version)
        cat "$TMP_MNT_DIR/@factory/etc/turris-version" 2> /dev/null || echo 0
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
    savepoint)
        savepoint "$@"
        ;;
    commit)
        commit
        ;;
    delete)
        while [ -n "$1" ]; do
            if [ "$1" = "-t" ]; then
                [ -n "$2" ] || die_helping "Option -t requires type argument"
                delete_type "$2"
                shift
            else
                delete "$1"
            fi
            shift
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
        if [ $# -gt 3 ]; then
            die_helping "Wrong number of arguments"
        else
            LAST="$1"
            [ $# -gt 0 ]   || LAST="`btrfs subvolume list "$TMP_MNT_DIR" | sed -n 's|ID [0-9]* gen [0-9]* top level [0-9]* path @\([0-9][0-9]*\)$|\1|p' | sort -n | tail -n 1`"
            [ -n "$LAST" ] || LAST="factory"
            snp_status "$LAST" "$2" "${3:-/}"
        fi
        ;;
    diff)
        if ! which diff > /dev/null; then
            echo "Utility diff not found!"
            die "Please install diffutils package"
        fi
        if [ $# -gt 3 ]; then
            die_helping "Wrong number of arguments"
        else
            LAST="$1"
            [ $# -gt 0 ]   || LAST="`btrfs subvolume list "$TMP_MNT_DIR" | sed -n 's|ID [0-9]* gen [0-9]* top level [0-9]* path @\([0-9][0-9]*\)$|\1|p' | sort -n | tail -n 1`"
            [ -n "$LAST" ] || LAST="factory"
            snp_diff "$LAST" "$2" "${3:-/}"
        fi
        ;;
    *)
        die_helping "Unknown command $command!"
        ;;
esac
exit 0
