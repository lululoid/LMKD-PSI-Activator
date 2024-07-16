#!/system/bin/sh
log="$MODPATH/log.txt"

totalmem=$(free | awk '/^Mem:/ {print $2}')
zram_size=$(awk -v size="$totalmem" 'BEGIN { printf "%.0f\n", size * 0.55 }')

if [ "$totalmem" -le 2097152 ]; then
    cat <<EOF
  ! Device is low RAM. Applying low RAM tweaks
EOF
    echo "ro.config.low_ram=true
ro.lmk.use_psi=true
ro.lmk.debug=true
ro.lmk.use_minfree_levels=false" >"$MODPATH"/system.prop
else
    echo "ro.config.low_ram=false
ro.lmk.use_psi=true
ro.lmk.debug=true
ro.lmk.use_minfree_levels=false" >"$MODPATH"/system.prop
fi

rm_prop sys.lmk.minfree_levels
approps "$MODPATH"/system.prop
relmkd
cat <<EOF

> LMKD PSI mode activated
  Give the better of your RAM, RAM is better being 
  filled with something useful than left unused
EOF

swap_size=0
one_gb=$((1024 * 1024))
totalmem_gb=$(((totalmem / 1024 / 1024) + 1))
count=0
swap_in_gb=0

cat <<EOF
> Please select SWAP size 
  Press VOLUME + to DEFAULT
  Press VOLUME - to SELECT 
  DEFAULT is 0 SWAP
EOF

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

if [ "$swap_size" -gt 0 ]; then
    swap_filename=$NVBASE/fmiop_swap
    free_space=$(df /data -P | tail -1 | awk '{print $4}')
    if [ "$free_space" -lt "$swap_size" ]; then
        cat <<EOF
> Swap file cannot be created because there's no 
  enough storage in your device

  Required space: ${swap_size} KB
  Available space: ${free_space} KB
EOF
    else
        dd if=/dev/zero of="$swap_filename" bs=1024 count="$swap_size"
        mkswap -L meZram-swap "$swap_filename"
        swapon -L meZram-swap
        cat <<EOF
> Swap file has been created successfully 
  Size: ${swap_size} KB 
EOF
    fi
fi
