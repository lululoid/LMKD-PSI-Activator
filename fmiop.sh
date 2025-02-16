#!/system/bin/sh
# shellcheck disable=SC3043,SC3060,SC2086,SC2046
TAG=fmiop
LOG_FOLDER=$NVBASE/$TAG
LOGFILE=$LOG_FOLDER/$TAG.log
PID_DB=$LOG_FOLDER/$TAG.pids
FOGIMP_PROPS=$NVBASE/modules/fogimp/system.prop
SWAP_FILENAME=$NVBASE/fmiop_swap
ZRAM_PRIORITY=$(tail -n1 /proc/swaps | awk '{print $5}')
CURRENT_ZRAM_PRIORITY=$ZRAM_PRIORITY
SWAP_TIME=false

export TAG LOGFILE LOG_FOLDER
alias uprint="ui_print"
alias resetprop="resetprop -v"
alias sed='$MODPATH/sed'

loger() {
	local log=$1
	[ -n "$log" ] && echo "
⟩ $log" >>"$LOGFILE"
}

logrotate() {
	local count=0
	local log oldest_log
	for log in "$@"; do
		count=$((count + 1))
		# shellcheck disable=SC2012
		if [ "$count" -gt 2 ]; then
			oldest_log=$(ls -tr "$@" | head -n 1)
			rm -rf "$oldest_log"
		fi
	done
}

check_file_size() {
	stat -c%s "$1"
}

save_pid() {
	local pid_name=$1
	local pid_value=$2

	sed -i "/^$pid_name=/d" "$PID_DB"
	echo "$pid_name=$pid_value" >>"$PID_DB"
}

read_pid() {
	local pid_name=$1
	local pid_value
	pid_value=$(awk -F= -v name="$pid_name" '$1 == name {print $2}' "$PID_DB")
	echo "$pid_value"
}

remove_pid() {
	local pid_name=$1
	sed -i "/^$pid_name=/d" "$PID_DB"
}

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
}

lmkd_loger() {
	local log_file=$1
	local new_pid

	resetprop ro.lmk.debug true
	old_pid=$(read_pid fmiop.lmkd_loger.pid)
	if [ -n "$old_pid" ]; then
		kill -9 "$old_pid"
		remove_pid "fmiop.lmkd_loger.pid"
	fi

	$BIN/logcat -v time --pid=$(pidof lmkd) -r "$((5 * 1024))" -n 4 --file=$log_file &
	if [ $? -ne 0 ]; then
		loger "Failed to start logcat"
		return 1
	fi
	new_pid=$!
	save_pid "fmiop.lmkd_loger.pid" "$new_pid"
}

loger_watcher() {
	local log_size today_date log new_pid
	logs="$1"

	exec 3>&-
	set +x

	while true; do
		for log in $logs; do
			log_size=$(check_file_size "$log")
			if [ "$log_size" -ge 10485760 ]; then
				exec 3>&1
				set -x

				today_date=$(date +%R-%a-%d-%m-%Y)
				new_log_file="${log%.log}_$today_date.log"

				cp "$log" "$new_log_file"
				echo "" >$log
				logrotate ${log%.log}*.log

				exec 3>&-
				set +x
			fi
		done
		sleep 2
	done &

	new_pid=$!
	save_pid "fmiop.lmkd_loger_watcher.pid" "$new_pid"
}

rm_prop() {
	local prop
	for prop in "$@"; do
		resetprop -d "$prop" && cat <<EOF

  X $prop deleted

EOF
	done
}

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
	rm_prop "$@"
}

relmkd() {
	resetprop lmkd.reinit 1
}

approps() {
	local prop_file=$1
	local prop value

	set -f
	resetprop -f $prop_file
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

notif() {
	local body=$1

	su -lp 2000 -c \
		"cmd notification post -S bigtext -t 'fmiop' 'Tag' '$body'"
}

turnoff_zram() {
	local zram=$1

	[ -n "$zram" ] && for _ in $(seq 20); do
		if swapoff "$zram"; then
			loger "$zram turned off"
			return 0
		fi
		sleep 1
	done

	loger "Failed to turn off $zram"
	return 1
}

add_zram() {
	zram_id=$(cat /sys/class/zram-control/hot_add)
	if [ -n "$zram_id" ]; then
		loger "zram$zram_id created" && echo "$zram_id"
		return 0
	fi
	return 1
}

remove_zram() {
	echo $1 >/sys/class/zram-control/hot_remove
}

resize_zram() {
	local size=$1
	local zram_id=$2
	local zram_block

	zram_block=/dev/block/zram$zram_id

	[ -e "$zram_block" ] && loger "$zram_block added"
	echo 1 >/sys/block/zram${zram_id}/use_dedup &&
		loger "use_dedup to reduce memory usage"
	echo "$size" >/sys/block/zram${zram_id}/disksize &&
		loger "set ZRAM$zram_id disksize to $size"

	for _ in $(seq 5); do
		if mkswap "$zram_block"; then
			break
		fi
		sleep 1
	done
}

get_memory_pressure() {
	local mem_usage memsw_usage memory_pressure
	mem_usage=$(cat /dev/memcg/memory.usage_in_bytes)
	memsw_usage=$(cat /dev/memcg/memory.memsw.usage_in_bytes)
	memory_pressure=$(awk -v mem_usage="$mem_usage" -v memsw_usage="$memsw_usage" 'BEGIN {print int(mem_usage * 100 / memsw_usage)}')
	echo "$memory_pressure"
}

is_device_sleeping() {
	dumpsys power | grep 'mWakefulness=' | grep 'Asleep'
}

is_device_dozing() {
	dumpsys deviceidle get deep | grep IDLE && loger "Device is entering doze mode"
}

apply_lmkd_props() {
	resetprop -f $MODPATH/system.prop
	resetprop -f $FOGIMP_PROPS
}

adjust_minfree_pairs_by_percentage() {
	percentage="$1"
	input="$2"

	# Loop through each pair separated by comma
	echo "$input" | awk -v perc="$percentage" '{
        n = split($0, pairs, ",");
        for (i = 1; i <= n; i++) {
            split(pairs[i], kv, ":");
            # Adjust the first value by the percentage
            kv[1] = kv[1] * (1 + perc / 100);
            printf "%d:%s", kv[1], kv[2];
            if (i < n) {
                printf ",";
            }
        }
    }'
}

turnon_zram() {
	if $BIN/swapon -p 32767 $1; then
		loger "$1 turned on"
	else
		loger "Failed to turn on $1"
		return 1
	fi
}

update_pressure_report() {
	memory_pressure=$(get_memory_pressure)
	module_prop="$MODPATH/module.prop"
	prop_bcp="$LOG_FOLDER/module.prop"
	tmp_file=$(mktemp -p /data/local/tmp)
	content=$(cat $prop_bcp)

	echo "$content" | sed "s/\(Memory pressure.*= \)-\?[0-9]*/\1$memory_pressure/" >$tmp_file && mv $tmp_file $module_prop
}

save_pressures_to_vars() {
	# Loop over the two pressure levels: "full" and "some"
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
				hw=$(basename "$file")

				# Create a new variable with the desired prefix and assign it the value.
				# For example, if hw is "memory", level is "full", key is "avg10" and value "3.41",
				# this will execute: full_avg10="3.41" (prefixed with the hardware name, e.g., memory_full_avg10).
				eval "${hw}_${level}_${key}=\"${value}\""
			done
		done
	done
}

read_pressure() {
	resource=$1
	level=$2
	key=$3
	file="/proc/pressure/$resource"

	if [ ! -f "$file" ]; then
		echo "Error: $file not found" >&2
		return 1
	fi

	awk -v lvl="$level" -v k="$key" '
    $1 == lvl {
        for (i = 2; i <= NF; i++) {
            split($i, a, "=")
            if (a[1] == k) {
                printf "%s", a[2]
                exit
            }
        }
    }' "$file"
}

dynamic_zram() {
	# POSIX-compliant script for dynamic zram activation
	# Directory where zram partitions are stored
	ZRAM_DIR="/dev/block"
	ZRAM_PATTERN="$ZRAM_DIR/zram*"

	# Get a sorted list of available zram partitions
	available_zrams=$(ls $ZRAM_PATTERN 2>/dev/null | sort)

	if [ -z "$available_zrams" ]; then
		echo "No zram partitions available in $ZRAM_DIR."
		return 0
	fi

	# Get active zram partitions from /proc/swaps (skip header line)
	active_zrams=$(awk '/zram/ {print $1}' /proc/swaps)

	# Function to check if a given file is active
	is_active() {
		file=$1
		echo "$active_zrams" | grep -q "^$file\$"
	}

	# If no zram partition is active, activate the first available zram partition.
	active_found=0
	for zram in $available_zrams; do
		if is_active "$zram"; then
			active_found=1
			break
		fi
	done

	if [ "$active_found" -eq 0 ]; then
		first_zram=$(echo "$available_zrams" | head -n 1)
		loger "No active zram found. Activating zram partition: $first_zram"
		swapon -p $CURRENT_ZRAM_PRIORITY $first_zram && CURRENT_ZRAM_PRIORITY=$((CURRENT_ZRAM_PRIORITY - 1))
		return 0
	fi

	# Identify the last active zram partition (by sorted order) among available zrams.
	last_active_zram=""
	for zram in $available_zrams; do
		if is_active "$zram"; then
			last_active_zram=$zram
		fi
	done

	if [ -z "$last_active_zram" ]; then
		echo "No active zram partition found (unexpected error)."
		return 1
	fi

	# Get the zram partition's size and used values from /proc/swaps.
	zram_line=$(grep "^$last_active_zram " /proc/swaps)
	# The fields in /proc/swaps are: Filename, Type, Size, Used, Priority.
	size=$(echo "$zram_line" | awk '{print $3}')
	used=$(echo "$zram_line" | awk '{print $4}')

	# Calculate the usage percentage.
	usage_percent=$((used * 100 / size))
	loger "zram partition $last_active_zram usage: ${usage_percent}%"

	# If usage is 90% or more, look for the next available (inactive) zram partition and activate it.
	if [ "$usage_percent" -ge 75 ]; then
		next_zram=""
		for zram in $available_zrams; do
			if ! is_active "$zram"; then
				next_zram=$zram
				break
			fi
		done
		if [ -n "$next_zram" ]; then
			loger "Usage is ${usage_percent}%. Activating next zram partition: $next_zram"
			swapon -p $CURRENT_ZRAM_PRIORITY "$next_zram" && CURRENT_ZRAM_PRIORITY=$((CURRENT_ZRAM_PRIORITY - 1))
		else
			loger "No additional zram partition available to activate."
			SWAP_TIME=true
			SWAP_PRIORITY=$CURRENT_ZRAM_PRIORITY
		fi
	else
		loger "zram usage is below threshold. No new zram partition activated."
	fi
}

deactivate_zram_low_usage() {
	zram_logging_breaker=true
	# Loop over active zram files (ignoring the header line in /proc/swaps)
	awk '/zram/ {print $1}' /proc/swaps | while read -r zram_file; do
		# Get the corresponding line from /proc/swaps
		zram_line=$(grep "^$zram_file " /proc/swaps)
		# The fields are: Filename, Type, Size, Used, Priority.
		size=$(echo "$zram_line" | awk '{print $3}')
		used=$(echo "$zram_line" | awk '{print $4}')
		# Calculate usage percentage (using integer arithmetic)
		usage_percent=$((used * 100 / size))
		if [ "$usage_percent" -lt 10 ]; then
			loger "Deactivating zram file $zram_file (usage: ${usage_percent}%)"
			swapoff $zram_file && CURRENT_ZRAM_PRIORITY=$((CURRENT_ZRAM_PRIORITY + 1))
			zram_logging_breaker=false
		elif ! $zram_logging_breaker; then
			loger "zram file $zram_file usage ($usage_percent%) is above threshold; keeping it active."
		fi
	done
}

dynamic_swapon() {
	# POSIX-compliant script for dynamic swap activation
	# Directory where swap files are stored
	SWAP_DIR="$NVBASE"
	SWAP_PATTERN="$SWAP_FILENAME*"

	# Get a sorted list of available swap files
	available_swaps=$(ls $SWAP_PATTERN 2>/dev/null | sort)

	if [ -z "$available_swaps" ]; then
		echo "No swap files available in $SWAP_DIR."
		return 0
	fi

	# Get active swap files from /proc/swaps (skip header line)
	active_swaps=$(awk '/file/ {print $1}' /proc/swaps)

	# Function to check if a given file is active
	is_active() {
		file=$1
		echo "$active_swaps" | grep -q "^$file\$"
	}

	# If no swap file is active, activate the first available swap file.
	active_found=0
	for swap in $available_swaps; do
		if is_active "$swap"; then
			active_found=1
			break
		fi
	done

	if [ "$active_found" -eq 0 ]; then
		first_swap=$(echo "$available_swaps" | head -n 1)
		loger "No active swap found. Activating swap file: $first_swap"
		swapon -p $SWAP_PRIORITY $first_swap && SWAP_PRIORITY=$((SWAP_PRIORITY - 1))
		return 0
	fi

	# Identify the last active swap file (by sorted order) among available swaps.
	last_active_swap=""
	for swap in $available_swaps; do
		if is_active "$swap"; then
			last_active_swap=$swap
		fi
	done

	if [ -z "$last_active_swap" ]; then
		echo "No active swap file found (unexpected error)."
		return 1
	fi

	# Get the swap file's size and used values from /proc/swaps.
	swap_line=$(grep "^$last_active_swap " /proc/swaps)
	# The fields in /proc/swaps are: Filename, Type, Size, Used, Priority.
	size=$(echo "$swap_line" | awk '{print $3}')
	used=$(echo "$swap_line" | awk '{print $4}')

	# Calculate the usage percentage.
	usage_percent=$((used * 100 / size))
	loger "Swap file $last_active_swap usage: ${usage_percent}%"

	# If usage is 90% or more, look for the next available (inactive) swap file and activate it.
	if [ "$usage_percent" -ge 90 ]; then
		next_swap=""
		for swap in $available_swaps; do
			if ! is_active "$swap"; then
				next_swap=$swap
				break
			fi
		done
		if [ -n "$next_swap" ]; then
			loger "Usage is ${usage_percent}%. Activating next swap file: $next_swap"
			swapon -p $SWAP_PRIORITY "$next_swap" && SWAP_PRIORITY=$((SWAP_PRIORITY - 1))
		else
			loger "No additional swap file available to activate."
		fi
	else
		loger "Swap usage is below threshold. No new swap file activated."
	fi
}

deactivate_swap_low_usage() {
	swap_logging_breaker=true
	# Loop over active swap files (ignoring the header line in /proc/swaps)
	awk '/file/ {print $1}' /proc/swaps | while read -r swap_file; do
		# Get the corresponding line from /proc/swaps
		swap_line=$(grep "^$swap_file " /proc/swaps)
		# The fields are: Filename, Type, Size, Used, Priority.
		size=$(echo "$swap_line" | awk '{print $3}')
		used=$(echo "$swap_line" | awk '{print $4}')
		# Calculate usage percentage (using integer arithmetic)
		usage_percent=$((used * 100 / size))
		if [ "$usage_percent" -lt 25 ]; then
			loger "Deactivating swap file $swap_file (usage: ${usage_percent}%)"
			swapoff $swap_file && SWAP_PRIORITY=$((SWAP_PRIORITY + 1))
			swap_logging_breaker=false
		elif ! $swap_logging_breaker; then
			loger "Swap file $swap_file usage ($usage_percent%) is above threshold; keeping it active."
		fi
	done || SWAP_TIME=false
}

adjust_swappiness_dynamic() {
	local current_swappiness new_swappiness step memory_metric cpu_metric io_metric
	local cpu_high_limit mem_high_limit io_limit
	local dyn_sw=true

	# Define thresholds for pressure metrics
	cpu_high_limit=25
	mem_high_limit=15 # Adjusted from 23
	io_limit=30       # Adjusted from 23
	step=2            # Can be increased to 6 for low-RAM devices

	# Swappiness clamp limit
	swap_max_limit=110
	swap_min_limit=75 # Adjusted from 30

	while true; do
		exec 3>&1
		set -x

		# Read current swappiness (assumed to be an integer)
		current_swappiness=$(cat /proc/sys/vm/swappiness)
		new_swappiness=$current_swappiness

		# Dynamically update pressure metrics
		memory_metric=$(read_pressure memory some avg60)
		cpu_metric=$(read_pressure cpu some avg60)
		io_metric=$(read_pressure io some avg60)

		# Check CPU pressure and adjust swappiness
		# Check memory high-pressure and adjust swappiness
		# Check IO pressure and adjust swappiness
		# Check memory pressure and adjust swappiness
		if [ "$(echo "$io_metric > $io_limit" | bc -l)" -eq 1 ]; then
			new_swappiness=$((new_swappiness - step))

			# Initiate swap activation
			dyn_sw=true
			if [ $new_swappiness -lt $swap_max_limit ] && [ $new_swappiness -gt $swap_min_limit ]; then
				loger "Decreased swappiness by $step due to IO pressure (io=$io_metric)"
			fi
		elif [ "$(echo "$cpu_metric > $cpu_high_limit" | bc -l)" -eq 1 ]; then
			new_swappiness=$((new_swappiness - step))

			# Initiate swap activation
			dyn_sw=true
			if [ $new_swappiness -lt $swap_max_limit ] && [ $new_swappiness -gt $swap_min_limit ]; then
				loger "Decreased swappiness by $step due to high CPU pressure (cpu=$cpu_metric)"
			fi
		elif [ "$(echo "$memory_metric > $mem_high_limit" | bc -l)" -eq 1 ]; then
			new_swappiness=$((new_swappiness - step))

			# Initiate swap activation
			dyn_sw=true
			if [ $new_swappiness -lt $swap_max_limit ] && [ $new_swappiness -gt $swap_min_limit ]; then
				loger "Decreased swappiness by $step due to high memory pressure (mem=$memory_metric)"
			fi
		else
			new_swappiness=$((new_swappiness + step))

			if $SWAP_TIME; then
				deactivate_swap_low_usage
			else
				deactivate_zram_low_usage
			fi

			swap_logging_breaker=true
			if [ $new_swappiness -lt $swap_max_limit ] && [ $new_swappiness -gt $swap_min_limit ]; then
				loger "Increased swappiness by $step (cpu=$cpu_metric, mem=$memory_metric)"
			fi
		fi

		# Apply the new swappiness value
		# Clamp the new value to the allowed range 0 to 200
		if [ "$new_swappiness" -gt $swap_max_limit ]; then
			new_swappiness=$swap_max_limit
		elif [ "$new_swappiness" -lt $swap_min_limit ]; then
			new_swappiness=$swap_min_limit
		fi

		# Log the change (only log if there is a change in swappiness)
		if [ "$new_swappiness" != "$current_swappiness" ]; then
			# Write the new swappiness value
			echo "$new_swappiness" >/proc/sys/vm/swappiness
			loger "Swappiness adjusted from $current_swappiness to $new_swappiness (cpu_pressure=$cpu_metric, io_pressure=$io_metric, memory_pressure=$memory_metric)"
		fi

		if $dyn_sw; then
			if $SWAP_TIME; then
				dynamic_swapon
			else
				dynamic_zram
			fi
			dyn_sw=false
		fi

		set +x
		exec 3>&-

		# Sleep for a short duration before checking again
		sleep 0.5
	done &

	# Save the process ID for cleanup if needed
	new_pid=$!
	save_pid "fmiop.dynswap.pid" "$new_pid"
}

fmiop() {
	local new_pid zram_block memory_pressure props

	set +x
	exec 3>&-

	# Saving props as variables
	[ -f $FOGIMP_PROPS ] && while IFS='=' read -r key value; do
		[ -z "$key" ] || [ -z "$value" ] || [ "${key#'#'}" != "$key" ] && continue
		props="$props $key"
		key=$(echo "$key" | tr '.' '_') # Replace dots with underscores to make valid variable names
		eval "$key=\"$value\""
	done <$FOGIMP_PROPS

	while true; do
		rm_prop sys.lmk.minfree_levels && {
			exec 3>&1
			set -x

			relmkd

			set +x
			exec 3>&-
		}

		[ -f $FOGIMP_PROPS ] && for prop in $props; do
			if ! resetprop $prop >/dev/null; then
				exec 3>&1
				set -x

				var=$(echo "$prop" | tr '.' '_')
				eval value="\$$var" # Dynamically get the value of the variable named by $var
				resetprop "$prop" "$value" && loger "$prop=$value reapplied"
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
}
