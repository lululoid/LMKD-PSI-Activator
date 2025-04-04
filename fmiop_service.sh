#!/system/bin/sh
# shellcheck disable=SC3043,SC2034,SC2086,SC3060,SC3010,SC2046
script_name=$(basename $0)
exec 3>&1 1>>"$LOG_FOLDER/${script_name%.sh}.log" 2>&1
set -x # Prints commands, prefixing them with a character stored in an environmental variable ($PS4)

. $MODPATH/fmiop.sh

get_config_checksum() {
	if [ -f "$CONFIG_INTERNAL" ]; then
		md5sum "$CONFIG_INTERNAL" 2>/dev/null | awk '{print $1}' || echo "no_hash"
		return 0
	else
		loger "missing config"
	fi

	return 1
}

# Initial run
start_services
last_checksum=$(get_config_checksum)

# Monitoring loop
monitor_config() {
	exec 3>&-
	set +x

	while true; do
		current_checksum=$(get_config_checksum)
		if [ -n "$last_checksum" ] && [ "$current_checksum" != "$last_checksum" ]; then
			exec 3>&1
			set -x

			loger "Config file $CONFIG_INTERNAL changed (checksum: $last_checksum -> $current_checksum)"
			cp $CONFIG_INTERNAL $CONFIG_FILE
			kill_services
			loger "Killed service PIDs"
			start_services
			last_checksum="$current_checksum"

			exec 3>&-
			set +x
		else
			last_checksum=$(get_config_checksum)
		fi
		sleep 5 # Check every 5 seconds
	done &

	new_pid=$!
	save_pid "fmiop.config_watcher.pid" "$new_pid"
	loger "Started config monitor with PID $new_pid"
}

# Run monitor in background
monitor_config
