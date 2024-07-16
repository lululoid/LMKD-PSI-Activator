#!/system/bin/sh
# shellcheck disable=SC3043,SC2034,SC2086,SC3060,SC3010
SKIPUNZIP=1
exec 3>&1 2>&1
set -x
totalmem=$(free | awk '/^Mem:/ {print $2}')

LOG_ENABLED=false
BIN=/system/bin

export MODPATH BIN NVBASE LOG_ENABLED

unzip -o "$ZIPFILE" -x 'META-INF/*' -d "$MODPATH" 2>&1 >&2
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm_recursive "$MODPATH/sed" 0 2000 0755 0755
set_perm_recursive "$MODPATH/fmiop.sh" 0 2000 0755 0755
set_perm_recursive "$MODPATH/fmiop_service.sh" 0 2000 0755 0755

. $MODPATH/fmiop.sh

lmkd_apply() {
    cat <<EOF

> Totalmem = $(free -h | awk '/^Mem:/ {print $2}')
EOF

    if [ "$totalmem" -lt 2097152 ]; then
        cat <<EOF
  ! Device is low ram. Applying low ram tweaks
EOF

        echo "ro.config.low_ram=true
ro.lmk.use_psi=true
ro.lmk.debug=true
ro.lmk.use_minfree_levels=false" >$MODPATH/system.prop
    else
        echo "ro.config.low_ram=false
ro.lmk.use_psi=true
ro.lmk.debug=true
ro.lmk.use_minfree_levels=false" >$MODPATH/system.prop
    fi

    rm_prop sys.lmk.minfree_levels
    approps $MODPATH/system.prop
    relmkd
    cat <<EOF

> LMKD PSI mode activated
  Give the better of your RAM, RAM is better being 
  filled with something useful than left unused
EOF
}

count_swap() {
    local one_gb=$((1024 * 1024))
    local totalmem_gb=$(((totalmem / 1024 / 1024) + 1))
    local count=0
    local swap_in_gb=0
    swap_size=0

    cat <<EOF
> Please select SWAP size 
  Press VOLUME + to DEFAULT
  Press VOLUME - to SELECT 
  DEFAULT is 0 SWAP
EOF

    set +x
    exec 3>/dev/null 2>&1

    while true; do
        timeout 0.5 /system/bin/getevent -lqc 1 2>&1 >"$TMPDIR"/events &
        sleep 0.5
        if (grep -q 'KEY_VOLUMEDOWN *DOWN' "$TMPDIR"/events); then
            if [ $count -eq 0 ]; then
                swap_size=0
                swap_in_gb=0
                ui_print "  $count. 0 SWAP --> RECOMMENDED"
            elif [ $swap_in_gb -lt $totalmem_gb ]; then
                swap_in_gb=$((swap_in_gb + 1))
                ui_print "  $count. ${swap_in_gb}GB of SWAP"
                swap_size=$((swap_in_gb * one_gb))
            fi

            count=$((count + 1))
        elif [ $swap_in_gb -eq $totalmem_gb ] && [ $count != 0 ]; then
            swap_size=$totalmem
            count=0
        elif (grep -q 'KEY_VOLUMEUP *DOWN' "$TMPDIR"/events); then
            break
        fi
    done

    set -x
    exec 3>&1 2>&1
}

make_swap() {
    dd if=/dev/zero of="$2" bs=1024 count="$1" >/dev/null
    mkswap -L meZram-swap "$2" >/dev/null
}

swap_filename=$NVBASE/fmiop_swap
free_space=$(df /data -P | tail -1 | awk '{print $4}')
swap_message() {
    if [ "$free_space" -lt "$swap_size" ]; then
        cat <<EOF
> Swap file cannot be created because there's no 
  enough storage in your device

  Required space: ${swap_size} KB
  Available space: ${free_space} KB
EOF
    else
        make_swap $swap_size $swap_filename
        cat <<EOF
> Swap file has been created successfully 
  Size: ${swap_size} KB 
EOF
    fi
}

main() {
    if [ "$totalmem" -gt 2097152 ]; then
        cat <<EOF
  ! WARNING
  Your RAM device is more than 2 GB, this
  tweak is not necessary for your device

  If you still want to apply this tweak, 
  please click VOLUME DOWN
  For canceling, click VOLUME UP
EOF

        set +x
        exec 3>/dev/null 2>&1

        while true; do
            timeout 0.5 /system/bin/getevent -lqc 1 2>&1 >"$TMPDIR"/events &
            sleep 0.5
            if (grep -q 'KEY_VOLUMEUP *DOWN' "$TMPDIR"/events); then
                ui_print "  ! Tweak aborted"
                break
            elif (grep -q 'KEY_VOLUMEDOWN *DOWN' "$TMPDIR"/events); then
                lmkd_apply
                count_swap
                if [ $swap_size -gt 0 ]; then
                    swap_message
                fi
                break
            fi
        done
        exec 3>&1 2>&1
    else
        lmkd_apply
        count_swap
        if [ $swap_size -gt 0 ]; then
            swap_message
        fi
    fi
}

main
