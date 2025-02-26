#!/system/bin/sh
# shellcheck disable=SC3043,SC2034,SC2086,SC3060,SC3010,SC2046
script_name=$(basename $0)
exec 3>&1 1>>"$LOG_FOLDER/$script_name.log" 2>&1
set -x # Prints commands, prefixing them with a character stored in an environmental variable ($PS4)

. $MODPATH/fmiop.sh

get_config_checksum() {
	if [ -f "$CONFIG_FILE" ]; then
		md5sum "$CONFIG_FILE" 2>/dev/null | awk '{print $1}' || echo "no_hash"
		return 0
	else
		loger "missing config"
	fi

	return 1
}

start_services() {
	. $MODPATH/vars.sh
	fmiop
	loger "Started fmiop with PID $!"
	adjust_swappiness_dynamic
	loger "Started adjust_swappiness_dynamic with PID $!"
}

# Initial run
start_services
last_checksum=$(get_config_checksum)

kill_services() {
	for id in fmiop.dynswap.pid fmiop.pid; do
		pid=$(read_pid $id)
		kill -9 $pid && loger "Killed $id with PID $pid"
	done
}

# Monitoring loop
monitor_config() {
	while true; do
		current_checksum=$(get_config_checksum)
		if [ "$current_checksum" != "$last_checksum" ]; then
			loger "Config file $CONFIG_FILE changed (checksum: $last_checksum -> $current_checksum)"
			kill_services
			loger "Killed service PIDs"
			start_services
			last_checksum="$current_checksum"
		fi
		sleep 5 # Check every 5 seconds
	done &

	new_pid=$!
	save_pid "fmiop.config_watcher.pid" "$new_pid"
	loger "Started config monitor with PID $new_pid"
}

# Run monitor in background
monitor_config
