#!/system/bin/sh
# shellcheck disable=SC3043,SC2034,SC2086,SC3060,SC3010,SC2046
script_name=$(basename $0)
exec 3>&1 1>>"$LOG_FOLDER/${script_name%.sh}.log" 2>&1
set -x

. $MODPATH/fmiop.sh

pkill -9 -f "logcat.*dynv"
pkill -9 -f "logcat.*lmkd"
lmkd_loger "$LOG_FOLDER/lmkd.log"

while true; do
	pid=$(pidof dynv)
	if [ -n "$pid" ]; then
		$BIN/logcat -v time --pid=$pid -r "$((5 * 1024))" -n 2 --file="$LOG_FOLDER/dynv.log"
	else
		echo "Waiting for dynv to start..." >>"$LOG_FOLDER/fmiop.log"
		sleep 5
	fi
done &

loger_watcher "$LOG_FOLDER/*.log"
loger "Started loger_watcher with PID $!"
archive_service
loger "Started archive_service with PID $!"
