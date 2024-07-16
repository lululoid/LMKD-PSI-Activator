#!/system/bin/sh

log="$MODPATH/log.txt"
BIN=/system/bin
totalmem=$(free | awk '/^Mem:/ {print $2}')
low_mem_device=false
swap_enabled=false

swap_filename=$NVBASE/fmiop_swap
swapfile() {
    swapoff -a
    dd if=/dev/zero of="$swap_filename" bs=1024 count=$swap_size
    mkswap -L meZram-swap "$swap_filename"
    swapon -L meZram-swap
    swap_enabled=true
}

ram_swap() {
    if [ "$totalmem" -lt 2097152 ]; then
        swap_size=$(awk -v size="$totalmem" 'BEGIN { printf "%.0f\n", size * 0.55 }')
        swapfile
    fi
}

apply_tweaks() {
    if [ "$totalmem" -lt 2097152 ]; then
        log "Low memory device, applying tweaks"
        low_mem_device=true
    else
        log "High memory device, no tweaks needed"
    fi
}

main() {
    apply_tweaks
    if $low_mem_device && ! $swap_enabled; then
        ram_swap
    fi
}

main
