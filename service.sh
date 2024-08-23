#!/system/bin/sh
# shellcheck disable=SC3010,SC3060,SC3043,SC2086,SC2046
MODDIR=${0%/*}
[ -z $MODPATH ] && MODPATH=$MODDIR
NVBASE=/data/adb
BIN=/system/bin
LOG_FOLDER=$NVBASE/fmiop
LOG=$LOG_FOLDER/fmiop.log

exec 3>&1 1>>"$LOG" 2>&1
set -x # Prints commands, prefixing them with a character stored in an environmental variable ($PS4)
echo "
⟩ $(date -Is)" >>$LOG

totalmem=$($BIN/free | awk '/^Mem:/ {print $2}')
swap_filename=$NVBASE/fmiop_swap
zram_size=$(awk -v size="$totalmem" \
	'BEGIN { printf "%.0f\n", size * 0.65 }')

# export for fmiop_service.sh
export MODPATH BIN NVBASE LOG_ENABLED LOG_FOLDER LOG

. $MODDIR/fmiop.sh

resize_zram $totalmem
# idk, the values is just for experimenting
$BIN/swapon -p 32767 $ZRAM_BLOCK
$BIN/swapon -p 32766 $swap_filename && loger "$swap_filename turned on"

until [ $(resetprop sys.boot_completed) -eq 1 ]; do
	sleep 5
done

kill_all_pids
$MODPATH/log_service.sh

miui_v_code=$(resetprop ro.miui.ui.version.code)
if [ -n "$miui_v_code" ]; then
	$MODPATH/fmiop_service.sh
	loger "fmiop started"
else
	rm_prop sys.lmk.minfree_levels
	relmkd
fi
