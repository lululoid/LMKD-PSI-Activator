#!/system/bin/sh
# shellcheck disable=SC3043,SC2034,SC2086,SC3060,SC3010,SC2046
script_name=$(basename $0)
exec 3>&1 1>>"$LOG_FOLDER/${script_name%.sh}.log" 2>&1
set -x

. $MODPATH/fmiop.sh

for pid in $(ps aux | awk '/fmiop:V/ {print $2}'); do
	kill -9 $pid
done
pkill -9 -f "logcat.*lmkd"
lmkd_loger "$LOG_FOLDER/lmkd.log"

exec 3>&-
set +x

while true; do
	pid=$(pidof dynv)
	if [ -n "$pid" ]; then
		exec 3>&1
		set -x

		logcat -v time fmiop:V '*:S' >>"$LOG_FOLDER/dynv.log" 2>&1

		exec 3>&-
		set +x
	else
		echo "Waiting for dynv to start..." >>"$LOG_FOLDER/fmiop.log"
		sleep 5
	fi
done &
new_pid=$!
save_pid "fmiop.dynamic_swappiness_logger_keeper.pid" "$new_pid"

loger_watcher "$LOG_FOLDER/*.log"
loger "Started loger_watcher with PID $!"
archive_service
loger "Started archive_service with PID $!"
