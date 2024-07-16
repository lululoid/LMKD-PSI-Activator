#!/system/bin/sh

getprop() {
    resetprop --no-vendor "$1"
}

setprop() {
    resetprop --no-vendor "$1" "$2"
}

rm_prop() {
    for prop in "$@"; do
        resetprop --delete --no-vendor "$prop"
    done
}

getprops() {
    props="$1"
    for prop in $props; do
        echo "$(getprop $prop)"
    done
}

setprops() {
    props="$1"
    shift
    values="$*"

    for value in $values; do
        for prop in $props; do
            if [ "$(getprop $prop)" = ${value//=/ } ]; then
                setprop "$prop" "$value"
            fi
        done
    done
}

approps() {
    props="$1"
    while IFS='=' read -r prop value; do
        setprop "$prop" "$value"
    done <"$props"
}

relmkd() {
    resetprop --no-vendor "sys.lmk.report_cached_app_kill" "true"
    resetprop --no-vendor "sys.lmk.report_cached_app_kill_notification" "true"
    resetprop --no-vendor "sys.lmk.use_minfree_levels" "false"
}

log() {
    if [ -n "$log" ]; then
        echo "$@" >>"$log"
    fi
}
