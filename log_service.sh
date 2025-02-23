#!/system/bin/sh
# shellcheck disable=SC3043,SC2034,SC2086,SC3060,SC3010,SC2046
script_name=$(basename $0)
exec 3>&1 1>>"$LOG_FOLDER/$script_name.log" 2>&1
set -x # Prints commands, prefixing them with a character stored in an environmental variable ($PS4)

. $MODPATH/fmiop.sh

log="$LOG_FOLDER/fmiop.log"
logrotate ${log%.log}*.log
lmkd_loger $LOG_FOLDER/lmkd.log
loger_watcher "$LOG_FOLDER/*.log" &
save_pid "fmiop.lmkd_loger_watcher.pid" "$!"
