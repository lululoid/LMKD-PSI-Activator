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

TOTALMEM=$($BIN/free | awk '/^Mem:/ {print $2}')
zram_size=$(awk -v size="$TOTALMEM" \
	'BEGIN { printf "%.0f\n", size * 0.65 }')
CPU_CORES_COUNT=$(grep -c ^processor /proc/cpuinfo)

# export for fmiop_service.sh
export MODPATH BIN NVBASE LOG_ENABLED LOG_FOLDER LOG CPU_CORES_COUNT TOTALMEM

. $MODDIR/fmiop.sh

turnoff_zram /dev/block/zram0
remove_zram 0 && loger "/dev/block/zram0 removed"

for _ in $(seq $CPU_CORES_COUNT); do
	zram_id=$(add_zram)
	resize_zram $((TOTALMEM / CPU_CORES_COUNT)) $zram_id
done

until [ $(resetprop sys.boot_completed) -eq 1 ]; do
	sleep 5
done

$MODPATH/log_service.sh
$MODPATH/fmiop_service.sh
loger "fmiop started"
