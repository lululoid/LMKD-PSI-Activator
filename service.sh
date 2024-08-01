#!/system/bin/sh
# shellcheck disable=SC3010,SC3060,SC3043,SC2086,SC2046
MODDIR=${0%/*}
[ -z $MODPATH ] && MODPATH=$MODDIR
NVBASE=/data/adb
BIN=/system/bin

exec 3>&1 1>>"$NVBASE/fmiop.log" 2>&1
set -x # Prints commands, prefixing them with a character stored in an environmental variable ($PS4)
echo "
⟩ $(date -Is)" >>$NVBASE/fmiop.log

totalmem=$($BIN/free | awk '/^Mem:/ {print $2}')
swap_filename=$NVBASE/fmiop_swap
zram_size=$(awk -v size="$totalmem" \
	'BEGIN { printf "%.0f\n", size * 0.65 }')

# export for fmiop_service.sh
export MODPATH BIN NVBASE LOG_ENABLED

. $MODDIR/fmiop.sh

turnoff_zram
$BIN/swapon -p 32766 $swap_filename && loger "$swap_filename turned on"
until resize_zram $totalmem; do
	sleep 1
done
# idk, the values is just for experimenting
$BIN/swapon -p 32767 $ZRAM

until [ $(resetprop sys.boot_completed) -eq 1 ]; do
	sleep 5
done

# lmkd_loger

miui_v_code=$(resetprop ro.miui.ui.version.code)
if [ -n "$miui_v_code" ]; then
	$MODPATH/fmiop_service.sh
	kill -0 $(resetprop fmiop.pid) &&
		loger "fmiop started"
else
	rm_prop sys.lmk.minfree_levels
	relmkd
fi
