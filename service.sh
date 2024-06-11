#!/system/bin/sh
# shellcheck disable=SC3010,SC3060,SC3043,SC2086,SC2046
MODDIR=${0%/*}
[ -z $MODPATH ] && MODPATH=$MODDIR
NVBASE=/data/adb
LOG_ENABLED=true
export LOG_ENABLED

[[ "$LOG_ENABLED" = "true" ]] && {
	exec 3>&1 1>>"$NVBASE/fmiop.log" 2>&1
	set -x # Prints commands, prefixing them with a character stored in an environmental variable ($PS4)
	date -Is
}

# shellcheck disable=SC2034
BIN=/system/bin
totalmem=$($BIN/free | awk '/^Mem:/ {print $2}')
swap_filename=$NVBASE/fmiop_swap
zram_size=$(awk -v size="$totalmem" \
	'BEGIN { printf "%.0f\n", size * 0.55 }')

export MODPATH
export BIN
export NVBASE

. $MODDIR/fmiop.sh

$BIN/swapon $swap_filename && loger "$swap_filename turned on"
resize_zram $totalmem

until [ $(resetprop sys.boot_completed) -eq 1 ]; do
	sleep 5
done

# lmkd_loger
$MODPATH/fmiop_service.sh
kill -0 $(resetprop fmiop.pid) &&
	loger "fmiop started"
sed -i 's/LOG_ENABLED=true/LOG_ENABLED=false/'
