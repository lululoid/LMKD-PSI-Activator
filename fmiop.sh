#!/system/bin/sh
# fmiop.sh - Memory Optimization Script for Android
# Purpose: Enhances memory management by dynamically adjusting ZRAM, swap files, and swappiness
#          based on system pressure metrics, and provides LMKD logging and property tweaks.
# Author: lululoid
# Version: v2.4-beta
# Requirements: Root access

# shellcheck disable=SC3043,SC3060,SC2086,SC2046
# Disabled ShellCheck warnings for local vars (3043), string trimming (3060),
# word splitting (2086), and command substitution splitting (2046).

# Need to set MODPATH, NVBASE and BIN in the environtment to use this script

### Configuration ###
TAG="fmiop"                                       # Unique identifier for the script
LOG_FOLDER="$NVBASE/$TAG"                         # Log directory (NVBASE must be set, e.g., /data/adb)
LOGFILE="$LOG_FOLDER/$TAG.log"                    # Main log file for script activity
PID_DB="$LOG_FOLDER/$TAG.pids"                    # File to store process IDs of background tasks
FOGIMP_PROPS="$NVBASE/modules/fogimp/system.prop" # External properties file for LMKD tweaks
SWAP_FILENAME="$NVBASE/fmiop_swap"                # Base name for swap files
ZRAM_PRIORITY=32767                               # Priority for ZRAM swaps (max value)
SWAP_TIME=false                                   # Flag to switch between ZRAM and file-based swap
FMIOP_DIR=/sdcard/Android/fmiop
CONFIG_FILE="$FMIOP_DIR/config.yaml" # YAML config file for thresholds and settings

# Export variables for use in sourced scripts or subprocesses
export TAG LOGFILE LOG_FOLDER

### Aliases ###
alias resetprop="resetprop -v" # Verbose property reset (requires root)
alias sed='$MODPATH/sed'       # Custom sed binary (MODPATH must be set)
alias yq='$MODPATH/yq'         # Custom yq binary for YAML parsing
alias tar='$MODPATH/tar'

### Utility Functions ###

# read_config - Reads a value from the YAML config file with a default fallback
# Usage: read_config <key_path> <default_value>
# Example: read_config ".virtual_memory.zram.activation_threshold" "25"
read_config() {
	local key="$1" default="$2" config_file="$CONFIG_FILE"

	value=$(yq e "$key" "$config_file" 2>/dev/null)
	[ "$value" = "null" ] || if [ -z "$value" ]; then
		loger "Can't read value from $CONFIG_FILE"
		value="$default"
	fi
	echo "$value"
}

### Load Variables ###
. $MODPATH/vars.sh

# Directory patterns for swap and ZRAM management
SWAP_DIR="$NVBASE"             # Directory for swap files
SWAP_PATTERN="$SWAP_FILENAME*" # Pattern to match swap files
ZRAM_DIR="/dev/block"          # Directory for ZRAM devices
ZRAM_PATTERN="$ZRAM_DIR/zram*" # Pattern to match ZRAM devices

# loger - Logs messages to LOGFILE with user-friendly formatting
# Usage: loger "message"
loger() {
	local log="$1"

	[ -n "$log" ] && echo "⟩ $log" >>"$LOGFILE"
}

# check_file_size - Returns the size of a file in bytes
# Usage: check_file_size <file>
check_file_size() {
	stat -c%s "$1" 2>/dev/null || echo 0
}

# save_pid - Saves a PID to PID_DB with a name
# Usage: save_pid <name> <pid>
save_pid() {
	local pid_name="$1" pid_value="$2"

	sed -i "/^$pid_name=/d" "$PID_DB"
	echo "$pid_name=$pid_value" >>"$PID_DB"
	loger "Saved PID $pid_value for $pid_name"
}

# remove_pid - Removes a PID entry from PID_DB
# Usage: remove_pid <name>
remove_pid() {
	local pid_name="$1"

	sed -i "/^$pid_name=/d" "$PID_DB"
	loger "Removed PID entry for $pid_name"
}

# read_pid - Reads a PID from PID_DB by name
# Usage: read_pid <name>
read_pid() {
	grep "$1" "$PID_DB" | cut -d= -f2
}

# kill_all_pids - Terminates all processes listed in PID_DB
kill_all_pids() {
	local pid_name pid_value

	while IFS= read -r line; do
		pid_name=$(echo "$line" | cut -d= -f1)
		pid_value=$(echo "$line" | cut -d= -f2)

		if [ -n "$pid_value" ]; then
			kill -9 "$pid_value" && loger "Killed $pid_name with PID $pid_value"
			remove_pid "$pid_name"
		fi
	done <"$PID_DB"
	loger "All tracked processes terminated"
}

# lmkd_loger - Logs LMKD activity to a file with rotation
# Usage: lmkd_loger <log_file>
lmkd_loger() {
	local log_file="$1" new_pid old_pid

	loger "Starting LMKD logging to $log_file"
	resetprop ro.lmk.debug true || loger "Failed to enable LMKD debug mode"
	old_pid=$(read_pid "fmiop.lmkd_loger.pid")

	if [ -n "$old_pid" ]; then
		kill -9 "$old_pid"
		remove_pid "fmiop.lmkd_loger.pid"
		loger "Stopped previous LMKD logger (PID $old_pid)"
	fi

	$BIN/logcat -v time --pid=$(pidof lmkd) -r "$((5 * 1024))" -n 2 --file="$log_file" &

	if [ $? -ne 0 ]; then
		loger "Failed to start logcat for LMKD"
		return 1
	fi

	new_pid=$!
	save_pid "fmiop.lmkd_loger.pid" "$new_pid"
	loger "LMKD logger started with PID $new_pid"
}

# loger_watcher - Monitors log files and rotates them when they exceed 10MB
# Usage: loger_watcher <log_files>
loger_watcher() {
	logs="$1"
	ten_mb=10485760

	# exec 3>&-
	# set +x

	loger "Starting log watcher for files: $logs"

	while true; do
		for log in $logs; do
			log_size=$(check_file_size "$log")

			if [ "$log_size" -ge "$ten_mb" ]; then
				exec 3>&1
				set -x

				log_count=$(find "${log%.log}"* | wc -l)
				new_log_file="$log.$log_count"
				cp "$log" "$new_log_file"
				echo "" >"$log"
				loger "Rotated $log to $new_log_file (size: $log_size bytes)"

				# limit logs to only 3
				while [ $log_count -ge 3 ]; do
					oldest_log=$(ls -tr "${log%.log}"* | head -n 1)
					log_count=$((log_count - 1))

					rm -rf "$oldest_log"
					loger "Removed oldest log file: $oldest_log to keep only 3 logs"
				done

				exec 3>&-
				set +x
			fi
		done
		sleep 2
	done &

	save_pid "fmiop.lmkd_loger_watcher.pid" "$!"
}

# rm_prop - Deletes specified system properties
# Usage: rm_prop <prop1> <prop2> ...
rm_prop() {
	local prop
	for prop in "$@"; do
		resetprop -d "$prop" && cat <<EOF

  X $prop deleted

EOF
	done
}

# lmkd_props_clean - Removes default LMKD properties to reset configuration
lmkd_props_clean() {
	set --
	set \
		"ro.lmk.low" \
		"ro.lmk.medium" \
		"ro.lmk.critical_upgrade" \
		"ro.lmk.kill_heaviest_task" \
		"ro.lmk.kill_timeout_ms" \
		"ro.lmk.psi_partial_stall_ms" \
		"ro.lmk.psi_complete_stall_ms" \
		"ro.lmk.thrashing_limit_decay" \
		"ro.lmk.swap_util_max" \
		"sys.lmk.minfree_levels" \
		"ro.lmk.upgrade_pressure" \
		"ro.lmk.downgrade_pressure"
	loger "Cleaning default LMKD properties"
	rm_prop "$@"
}

# relmkd - Reinitializes the LMKD daemon
relmkd() {
	resetprop lmkd.reinit 1 && loger "LMKD reinitialized"
}

# approps - Applies properties from a file and verifies them
# Usage: approps <prop_file>
approps() {
	local prop_file="$1" prop value

	set -f
	loger "Applying properties from $prop_file"
	resetprop -f "$prop_file"
	grep -v '^ *#' "$prop_file" | while IFS='=' read -r prop value; do
		cat <<EOF
  › $prop 
EOF
		{
			[ "$(getprop "$prop")" = "${value//=/ }" ] &&
				uprint "  » $value
"
		} || uprint "  ! Failed
"
	done
}

# notif - Sends a notification to the user
# Usage: notif "message"
notif() {
	local body="$1"
	loger "Sending notification: $body"
	su -lp 2000 -c "cmd notification post -S bigtext -t 'fmiop' 'Tag' '$body'"
}

# turnoff_zram - Disables a ZRAM partition
# Usage: turnoff_zram <zram_device>
turnoff_zram() {
	local zram="$1"

	[ -n "$zram" ] && for _ in $(seq 20); do
		if swapoff "$zram"; then
			loger "ZRAM $zram turned off successfully"
			return 0
		fi
		sleep 1
	done

	loger "Failed to turn off ZRAM $zram after 20 attempts"
	return 1
}

# add_zram - Adds a new ZRAM partition
add_zram() {
	zram_id=$(cat /sys/class/zram-control/hot_add 2>/dev/null)

	if [ -n "$zram_id" ]; then
		loger "Created new ZRAM partition: zram$zram_id"
		echo "$zram_id"
		return 0
	fi

	loger "Failed to create new ZRAM partition"
	return 1
}

# remove_zram - Removes a ZRAM partition
# Usage: remove_zram <zram_id>
remove_zram() {
	{
		echo "$1" >/sys/class/zram-control/hot_remove 2>/dev/null && loger "Removed ZRAM partition $1"
	} || loger "Failed to remove ZRAM $1"
}

# resize_zram - Resizes a ZRAM partition and prepares it for swapping
# Usage: resize_zram <size> <zram_id>
resize_zram() {
	local size="$1" zram_id="$2" zram_block
	zram_block="/dev/block/zram$zram_id"

	loger "Resizing ZRAM$zram_id to $size"
	[ -e "$zram_block" ] && loger "ZRAM block device $zram_block exists"
	echo 1 >/sys/block/zram${zram_id}/use_dedup 2>/dev/null && loger "Enabled deduplication for ZRAM$zram_id"
	echo "$size" >/sys/block/zram${zram_id}/disksize 2>/dev/null && loger "Set ZRAM$zram_id size to $size"

	for _ in $(seq 5); do
		if mkswap "$zram_block" 2>/dev/null; then
			loger "Initialized swap on ZRAM$zram_id"
			break
		fi
		sleep 1
	done
}

# get_memory_pressure - Calculates memory pressure as a percentage
get_memory_pressure() {
	local mem_usage memsw_usage memory_pressure
	mem_usage=$(cat /dev/memcg/memory.usage_in_bytes 2>/dev/null || echo 0)
	memsw_usage=$(cat /dev/memcg/memory.memsw.usage_in_bytes 2>/dev/null || echo 1)
	memory_pressure=$(awk -v mem_usage="$mem_usage" -v memsw_usage="$memsw_usage" 'BEGIN {print int(mem_usage * 100 / memsw_usage)}')

	echo "$memory_pressure"
}

# is_device_sleeping - Checks if the device is in sleep mode
is_device_sleeping() {
	dumpsys power | grep 'mWakefulness=' | grep 'Asleep' >/dev/null && loger "Device is sleeping"
}

# is_device_dozing - Checks if the device is in doze mode
is_device_dozing() {
	dumpsys deviceidle get deep | grep IDLE >/dev/null && loger "Device is entering doze mode"
}

# apply_lmkd_props - Applies LMKD properties from files
apply_lmkd_props() {
	loger "Applying LMKD properties from $MODPATH/system.prop and $FOGIMP_PROPS"
	resetprop -f "$MODPATH/system.prop" 2>/dev/null
	resetprop -f "$FOGIMP_PROPS" 2>/dev/null
}

# adjust_minfree_pairs_by_percentage - Adjusts minfree pairs by a percentage
# Usage: adjust_minfree_pairs_by_percentage <percentage> <input_string>
adjust_minfree_pairs_by_percentage() {
	percentage="$1" input="$2"
	loger "Adjusting minfree pairs in '$input' by $percentage%"
	echo "$input" | awk -v perc="$percentage" '{
        n = split($0, pairs, ",");
        for (i = 1; i <= n; i++) {
            split(pairs[i], kv, ":");
            kv[1] = kv[1] * (1 + perc / 100);
            printf "%d:%s", kv[1], kv[2];
            if (i < n) printf ",";
        }
    }'
}

# turnon_zram - Enables a ZRAM partition for swapping
# Usage: turnon_zram <zram_device>
turnon_zram() {
	if $BIN/swapon -p 32767 "$1" 2>/dev/null; then
		loger "ZRAM $1 turned on with priority 32767"
	else
		loger "Failed to turn on ZRAM $1"
		return 1
	fi
}

# update_pressure_report - Updates the module.prop with current memory pressure
last_memory_pressure=$(get_memory_pressure)
update_pressure_report() {
	local current_swappiness current_swappiness
	memory_pressure=$(get_memory_pressure)
	module_prop="$MODPATH/module.prop"
	current_swappiness=$(cat /proc/sys/vm/swappiness)
	prop_bcp="$LOG_FOLDER/module.prop"

	if [ $last_memory_pressure -ne "$memory_pressure" ]; then
		loger "Updating memory pressure report to $memory_pressure"
		last_memory_pressure=$memory_pressure
	fi

	desc=$(sed "s/\(Memory pressure.*= \)-\?[0-9]*,/\1$memory_pressure/;s/\(swappiness.*= \)-\?[0-9]*/\1$current_swappiness/" "$prop_bcp")
	[ -n "$desc" ] && echo "$desc" >$module_prop
}

# save_pressures_to_vars - Stores pressure metrics from /proc/pressure into variables
save_pressures_to_vars() {
	loger "Saving pressure metrics to variables"

	for level in full some; do
		# Loop over each file in /proc/pressure
		for file in /proc/pressure/*; do
			# Remove the prefix (level and a following space) from each line in the file,
			# and reset the positional parameters to the resulting key=value pairs.
			set -- $(sed "s/^$level //" "$file")

			# For each key=value pair, extract key and value
			for pair in "$@"; do
				key=${pair%%=*}
				value=${pair#*=}

				# Get the filename (without directory path) as the hardware identifier.
				key=${pair%%=*} value=${pair#*=}
				hw=$(basename "$file")
				# Create a new variable with the desired prefix and assign it the value.
				# For example, if hw is "memory", level is "full", key is "avg10" and value "3.41",
				# this will execute: full_avg10="3.41" (prefixed with the hardware name, e.g., memory_full_avg10).
				eval "${hw}_${level}_${key}=\"${value}\""
				loger "Set ${hw}_${level}_${key}=$value"
			done
		done
	done
}

# read_pressure - Reads a specific pressure metric from /proc/pressure
# Usage: read_pressure <resource> <level> <key>
read_pressure() {
	resource="$1" level="$2" key="$3" file="/proc/pressure/$resource"

	if [ ! -f "$file" ]; then
		loger "Error: Pressure file $file not found"
		echo "Error: $file not found" >&2
		return 1
	fi

	awk -v lvl="$level" -v k="$key" '
    $1 == lvl {
        for (i = 2; i <= NF; i++) {
            split($i, a, "=")
            if (a[1] == k) { printf "%s", a[2]; exit }
        }
    }' "$file"
}

# get_lst_zpriority - Gets the priority of the last active ZRAM swap
get_lst_zpriority() {
	awk '/zram/ {print $5}' /proc/swaps | tail -n1
}

# get_lst_spriority - Gets the priority of the last active file swap
get_lst_spriority() {
	awk '/file/ {print $5}' /proc/swaps | tail -n1
}

# dynamic_zram - Dynamically activates ZRAM partitions based on usage
dynamic_zram() {
	local idle=false
	available_zrams=$(find $ZRAM_PATTERN 2>/dev/null | sort)

	if [ -z "$available_zrams" ]; then
		loger "No ZRAM partitions available in $ZRAM_DIR"
		return 0
	fi

	active_zrams=$(awk '/zram/ {print $1}' /proc/swaps)
	is_active() { echo "$active_zrams" | grep -q "^$1\$"; }

	active_found=0
	for zram in $available_zrams; do
		if is_active "$zram"; then
			active_found=1
			break
		fi
	done

	if [ "$active_found" -eq 0 ]; then
		first_zram=$(echo "$available_zrams" | head -n 1)
		loger "No active ZRAM found. Activating $first_zram with priority $ZRAM_PRIORITY"
		swapon -p "$ZRAM_PRIORITY" "$first_zram" 2>/dev/null
		return 0
	fi

	last_active_zram=""
	for zram in $available_zrams; do
		if is_active "$zram"; then
			last_active_zram="$zram"
		fi
	done

	if [ -z "$last_active_zram" ]; then
		loger "Unexpected: No active ZRAM partition found"
		return 1
	fi

	zram_line=$(grep "^$last_active_zram " /proc/swaps)
	size=$(echo "$zram_line" | awk '{print $3}')
	used=$(echo "$zram_line" | awk '{print $4}')
	usage_percent=$((used * 100 / size))

	loger "ZRAM $last_active_zram usage: ${usage_percent}% (Threshold: $ZRAM_ACTIVATION_THRESHOLD%)"

	if [ "$usage_percent" -ge "$ZRAM_ACTIVATION_THRESHOLD" ]; then
		next_zram=""
		idle=false

		for zram in $available_zrams; do
			if ! is_active "$zram"; then
				next_zram="$zram"
				break
			fi
		done

		if [ -n "$next_zram" ]; then
			LAST_ZPRIORITY=$(get_lst_zpriority)
			loger "Activating $next_zram at ${usage_percent}% usage with priority $((LAST_ZPRIORITY - 1))"
			swapon -p "$((LAST_ZPRIORITY - 1))" "$next_zram" 2>/dev/null
		else
			loger "No additional ZRAM available; switching to swap mode"
			SWAP_TIME=true
			LAST_ZPRIORITY=$(get_lst_zpriority)
			SWAP_PRIORITY="$LAST_ZPRIORITY"
		fi
	else
		! $idle && loger "ZRAM usage below $ZRAM_ACTIVATION_THRESHOLD%; no action needed"
		idle=true
	fi
}

# deactivate_zram_low_usage - Deactivates ZRAM partitions with low usage
deactivate_zram_low_usage() {
	zram_logging_breaker=true

	awk '/zram/ {print $1}' /proc/swaps | while read -r zram_file; do
		zram_line=$(grep "^$zram_file " /proc/swaps)
		size=$(echo "$zram_line" | awk '{print $3}')
		used=$(echo "$zram_line" | awk '{print $4}')
		usage_percent=$((used * 100 / size))

		if [ "$usage_percent" -lt "$ZRAM_DEACTIVATION_THRESHOLD" ]; then
			loger "ZRAM deactivation threshold reached"
			loger "Deactivating $zram_file (usage: ${usage_percent}% < $ZRAM_DEACTIVATION_THRESHOLD%)"
			swapoff "$zram_file" 2>/dev/null
			zram_logging_breaker=false

		elif ! "$zram_logging_breaker"; then
			loger "$zram_file usage (${usage_percent}%) above $ZRAM_DEACTIVATION_THRESHOLD%; keeping active"
		fi
	done
}

# dynamic_swapon - Dynamically activates swap files based on usage
dynamic_swapon() {
	local idle=false
	available_swaps=$(find $SWAP_PATTERN 2>/dev/null | sort)

	if [ -z "$available_swaps" ]; then
		loger "No swap files available in $SWAP_DIR"
		return 0
	fi

	active_swaps=$(awk '/file/ {print $1}' /proc/swaps)
	is_active() { echo "$active_swaps" | grep -q "^$1\$"; }

	active_found=0
	for swap in $available_swaps; do
		if is_active "$swap"; then
			active_found=1
			break
		fi
	done

	if [ "$active_found" -eq 0 ]; then
		first_swap=$(echo "$available_swaps" | head -n 1)
		loger "No active swap found. Activating $first_swap with priority $SWAP_PRIORITY"
		swapon -p "$SWAP_PRIORITY" "$first_swap" 2>/dev/null
	fi

	last_active_swap=""
	for swap in $available_swaps; do
		if is_active "$swap"; then
			last_active_swap="$swap"
		fi
	done

	if [ -z "$last_active_swap" ]; then
		loger "Unexpected: No active swap file found"
		return 1
	fi

	swap_line=$(grep "^$last_active_swap " /proc/swaps)
	size=$(echo "$swap_line" | awk '{print $3}')
	used=$(echo "$swap_line" | awk '{print $4}')
	usage_percent=$((used * 100 / size))

	loger "Swap file $last_active_swap usage: ${usage_percent}% (Threshold: $SWAP_ACTIVATION_THRESHOLD%)"
	if [ "$usage_percent" -ge "$SWAP_ACTIVATION_THRESHOLD" ]; then
		next_swap=""
		idle=false

		for swap in $available_swaps; do
			if ! is_active "$swap"; then
				next_swap="$swap"
				break
			fi
		done
		if [ -n "$next_swap" ]; then
			LAST_SPRIORITY=$(get_lst_spriority)
			loger "Activating $next_swap at ${usage_percent}% usage with priority $((LAST_SPRIORITY - 1))"
			swapon -p "$((LAST_SPRIORITY - 1))" "$next_swap" 2>/dev/null
		else
			loger "No additional swap files available"
		fi
	else
		! $idle && loger "Swap usage below $SWAP_ACTIVATION_THRESHOLD%; no action needed"
		idle=true
	fi
}

# deactivate_swap_low_usage - Deactivates swap files with low usage
deactivate_swap_low_usage() {
	swap_logging_breaker=true
	active_swaps=$(awk '/file/ {print $1}' /proc/swaps)

	echo "$active_swaps" | while read -r swap_file; do
		swap_line=$(grep "^$swap_file " /proc/swaps)
		size=$(echo "$swap_line" | awk '{print $3}')
		used=$(echo "$swap_line" | awk '{print $4}')
		usage_percent=$((used * 100 / size))

		if [ "$usage_percent" -lt "$SWAP_DEACTIVATION_THRESHOLD" ]; then
			loger "Swap deactivation threshold reached"
			loger "Deactivating $swap_file (usage: ${usage_percent}% < $SWAP_DEACTIVATION_THRESHOLD%)"
			swapoff "$swap_file" 2>/dev/null
			swap_logging_breaker=false

		elif ! "$swap_logging_breaker"; then
			loger "$swap_file usage (${usage_percent}%) above $SWAP_DEACTIVATION_THRESHOLD%; keeping active"
		fi
	done

	[ -z "$active_swaps" ] && SWAP_TIME=false
}

# adjust_swappiness_dynamic - Dynamically adjusts swappiness based on pressure metrics
adjust_swappiness_dynamic() {
	local current_swappiness new_swappiness memory_metric cpu_metric io_metric dyn_sw=true

	loger "Starting dynamic swappiness adjustment (Max: $SWAPPINESS_MAX, Min: $SWAPPINESS_MIN)"
	loger "Thresholds - CPU: $CPU_PRESSURE_THRESHOLD, Memory: $MEMORY_PRESSURE_THRESHOLD, IO: $IO_PRESSURE_THRESHOLD, Step: $SWAPPINESS_STEP"

	while true; do
		exec 3>&1
		set -x

		current_swappiness=$(cat /proc/sys/vm/swappiness)
		new_swappiness="$current_swappiness"
		memory_metric=$(read_pressure memory some avg60)
		cpu_metric=$(read_pressure cpu some avg10)
		io_metric=$(read_pressure io some avg60)

		if [ "$(echo "$io_metric > $IO_PRESSURE_THRESHOLD" | bc -l)" -eq 1 ]; then
			new_swappiness=$((new_swappiness - SWAPPINESS_STEP))
			dyn_sw=true
			[ "$new_swappiness" -lt "$SWAPPINESS_MAX" ] && [ "$new_swappiness" -gt "$SWAPPINESS_MIN" ] &&
				loger "Decreased swappiness by $SWAPPINESS_STEP due to IO pressure ($io_metric > $IO_PRESSURE_THRESHOLD)"
		elif [ "$(echo "$cpu_metric > $CPU_PRESSURE_THRESHOLD" | bc -l)" -eq 1 ]; then
			new_swappiness=$((new_swappiness - SWAPPINESS_STEP))
			dyn_sw=true
			[ "$new_swappiness" -lt "$SWAPPINESS_MAX" ] && [ "$new_swappiness" -gt "$SWAPPINESS_MIN" ] &&
				loger "Decreased swappiness by $SWAPPINESS_STEP due to CPU pressure ($cpu_metric > $CPU_PRESSURE_THRESHOLD)"
		elif [ "$(echo "$memory_metric > $MEMORY_PRESSURE_THRESHOLD" | bc -l)" -eq 1 ]; then
			new_swappiness=$((new_swappiness - SWAPPINESS_STEP))
			dyn_sw=true
			[ "$new_swappiness" -lt "$SWAPPINESS_MAX" ] && [ "$new_swappiness" -gt "$SWAPPINESS_MIN" ] &&
				loger "Decreased swappiness by $SWAPPINESS_STEP due to memory pressure ($memory_metric > $MEMORY_PRESSURE_THRESHOLD)"
		else
			new_swappiness=$((new_swappiness + SWAPPINESS_STEP))
			if "$SWAP_TIME"; then
				deactivate_swap_low_usage
			else
				deactivate_zram_low_usage
			fi
			swap_logging_breaker=true
			[ "$new_swappiness" -lt "$SWAPPINESS_MAX" ] && [ "$new_swappiness" -gt "$SWAPPINESS_MIN" ] &&
				loger "Increased swappiness by $SWAPPINESS_STEP (cpu=$cpu_metric, mem=$memory_metric)"
		fi

		if [ "$new_swappiness" -gt "$SWAPPINESS_MAX" ]; then
			new_swappiness="$SWAPPINESS_MAX"
		elif [ "$new_swappiness" -lt "$SWAPPINESS_MIN" ]; then
			new_swappiness="$SWAPPINESS_MIN"
		fi

		if [ "$new_swappiness" != "$current_swappiness" ]; then
			echo "$new_swappiness" >/proc/sys/vm/swappiness
			loger "Swappiness adjusted from $current_swappiness to $new_swappiness (cpu=$cpu_metric, io=$io_metric, mem=$memory_metric)"
		fi

		if "$dyn_sw"; then
			if "$SWAP_TIME"; then
				dynamic_swapon
			else
				dynamic_zram
			fi
			dyn_sw=false
		fi

		set +x
		exec 3>&-
		sleep 1
	done &
	new_pid=$!
	save_pid "fmiop.dynswap.pid" "$new_pid"
	loger "Dynamic swappiness adjustment running with PID $new_pid"
}

# fmiop - Main function to manage LMKD properties and pressure reporting
fmiop() {
	local new_pid zram_block memory_pressure props
	set +x
	exec 3>&-
	loger "Starting fmiop memory optimization"

	[ -f "$FOGIMP_PROPS" ] && while IFS='=' read -r key value; do
		[ -z "$key" ] || [ -z "$value" ] || [ "${key#'#'}" != "$key" ] && continue
		props="$props $key"
		key=$(echo "$key" | tr '.' '_')
		eval "$key=\"$value\""
		loger "Loaded property $key=$value from $FOGIMP_PROPS"
	done <"$FOGIMP_PROPS"

	while true; do
		rm_prop sys.lmk.minfree_levels && {
			exec 3>&1
			set -x
			relmkd
			set +x
			exec 3>&-
		}

		[ -f "$FOGIMP_PROPS" ] && for prop in $props; do
			if ! resetprop "$prop" >/dev/null 2>&1; then
				exec 3>&1
				set -x
				var=$(echo "$prop" | tr '.' '_')
				eval value="\$$var"
				resetprop "$prop" "$value" && loger "Reapplied $prop=$value"
				relmkd
				set +x
				exec 3>&-
			fi
		done

		update_pressure_report
		sleep 2
	done &
	new_pid=$!
	save_pid "fmiop.pid" "$new_pid"
	loger "fmiop running with PID $new_pid"
}

# archive_service - Starts a background service to archive files every 5 minutes
# Usage: archive_service
# Archives: Files in /data/adb/fmiop/* and /sdcard/Android/fmiop/* into tar.gz
archive_service() {
	local archive_dir="$FMIOP_DIR/archives"                   # Directory for archives
	local source_dirs="/data/adb/fmiop /sdcard/Android/fmiop" # Directories to archive
	local interval=300                                        # 5 minutes in seconds
	local max_archives=5                                      # Maximum number of archives to keep
	local timestamp tar_output archive_file

	# Ensure archive directory exists
	mkdir -p "$archive_dir" || {
		loger "Failed to create archive directory $archive_dir"
		return 1
	}
	loger "Starting archive service for $source_dirs"

	# Background loop to archive files
	(
		while true; do
			# Generate timestamp for unique archive name
			timestamp=$(date +%Y%m%d_%H%M%S)
			archive_file="$archive_dir/fmiop_archive_$timestamp.tar.gz"

			# Archive files from both directories
			tar_output=$(
				tar -czf "$archive_file" \
					-C /data/adb/fmiop . \
					-C /sdcard/Android/fmiop ./config.yaml
			)

			[ -z "$tar_output" ] &&
				loger "Created archive $archive_file from $source_dirs with output: $tar_output"

			# Check and limit the number of archives to max_archives (5)
			local archive_count
			archive_count=$(find "$archive_dir/fmiop_archive_"*.tar.gz 2>/dev/null | wc -l)
			if [ "$archive_count" -gt "$max_archives" ]; then
				# Remove the oldest archives until only 5 remain
				local excess=$((archive_count - max_archives))
				ls -t "$archive_dir/fmiop_archive_"*.tar.gz | tail -n "$excess" | while read -r old_archive; do
					rm -f "$old_archive"
					loger "Removed oldest archive $old_archive to maintain limit of $max_archives"
				done
			fi

			# Wait 5 minutes
			sleep "$interval"
		done
	) &

	# Save PID of the background service
	local pid=$!
	save_pid "fmiop.archive_service.pid" "$pid"
	loger "Archive service started with PID $pid, running every $((interval / 60)) minutes, limiting to $max_archives archives"
}

# Function to get key events
get_key_event() {
	local event_type="$1"
	local event_file="$TMPDIR/events"

	if [ -n "$capture_pid" ] && ! kill -0 $capture_pid; then
		unset capture_pid
	elif [ -z "$capture_pid" ]; then
		getevent -lq >$event_file &
		capture_pid=$!
	fi

	result=$(tail -n2 "$event_file" | grep "$event_type")
	[ -n "$result" ] && sleep 0.25 && return 0 || return 1
}

# Function to handle SWAP size logic
handle_swap_size() {
	if [ $count -eq 0 ]; then
		swap_size=0
		swap_in_gb=0
		uprint "  $count. 0 SWAP --⟩ RECOMMENDED"
		count=$((count + 1))
	elif [ $swap_in_gb -lt $totalmem_gb ]; then
		swap_in_gb=$((swap_in_gb + 1))
		uprint "  $count. ${swap_in_gb}GB of SWAP"
		swap_size=$((swap_in_gb * one_gb))
		count=$((count + 1))
	elif [ $swap_in_gb -ge $totalmem_gb ]; then
		swap_size=$totalmem
		count=0
		swap_in_gb=0
	fi
}

# Main loop to handle user input and adjust SWAP size
setup_swap_size() {
	local one_gb totalmem_gb count swap_in_gb totalmem
	totalmem=$(free | awk '/^Mem:/ {print $2}')
	one_gb=$((1024 * 1024))
	totalmem_gb=$(((totalmem / 1024 / 1024) + 1))
	count=0
	swap_in_gb=0
	hundred_mb=$((one_gb / 10))
	quarter_gb=$((one_gb / 4))
	swap_size=0

	uprint "
⟩ Please select SWAP size 
  Press VOLUME + to use DEFAULT
  Press VOLUME - to SELECT 
  DEFAULT is 0 SWAP
  "

	while true; do
		if get_key_event 'KEY_VOLUMEDOWN *DOWN'; then
			exec 3>&1
			set -x
			handle_swap_size
			exec 3>&-
			set +x
		elif get_key_event 'KEY_VOLUMEUP *DOWN'; then
			break
		fi
	done
	kill -9 $capture_pid
}

make_swap() {
	dd if=/dev/zero of="$2" bs=1024 count="$1" >/dev/null
	mkswap -L fmiop_swap "$2" >/dev/null
	chmod 0600 "$2"
}

setup_swap() {
	local swap_filename free_space swap_size
	swap_filename=$NVBASE/fmiop_swap
	free_space=$(df /data | sed -n '2p' | sed 's/[^0-9 ]*//g' | sed ':a;N;$!ba;s/\n/ /g' | awk '{print $4}')

	if [ ! -f "$swap_filename.1" ]; then
		setup_swap_size
		if [ "$free_space" -ge "$swap_size" ] && [ "$swap_size" != 0 ]; then
			uprint "
⟩ Starting making SWAP. Please wait a moment...
  $((free_space / 1024))MB available. $((swap_size / 1024))MB needed
	"
			zram_priority=$(grep "/dev/block/zram0" /proc/swaps | awk '{print $5}')
			swap_count=$((swap_size / quarter_gb))
			for num in $(seq $swap_count); do
				make_swap "$quarter_gb" "$swap_filename.$num"
			done
		elif [ $swap_size -eq 0 ]; then
			:
		else
			uprint "
⟩ Storage full. Please free up your storage"
		fi
	fi
}
