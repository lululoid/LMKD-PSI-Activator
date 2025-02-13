#!/system/bin/sh
# shellcheck disable=SC3043,SC3060,SC2086,SC2046
TAG=fmiop
LOG_FOLDER=$NVBASE/$TAG
LOGFILE=$LOG_FOLDER/$TAG.log
PID_DB=$LOG_FOLDER/$TAG.pids
FOGIMP_PROPS=$NVBASE/modules/fogimp/system.prop

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
	turnoff_zram $zram_block

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

apply_swappiness() {
	new_swappiness=$1

	# Clamp the new value to the allowed range 0 to 200
	if [ "$new_swappiness" -gt 200 ]; then
		new_swappiness=200
	elif [ "$new_swappiness" -lt 0 ]; then
		new_swappiness=0
	fi

	# Write the new swappiness value
	echo "$new_swappiness" >/proc/sys/vm/swappiness

	# Log the change (corrected the variable name for io_pressure)
	if [ "$new_swappiness" != "$current_swappiness" ]; then
		loger "Swappiness adjusted from $current_swappiness to $new_swappiness (cpu_pressure=$cpu_some_avg10, io_pressure=$io_some_avg10)"
	fi
}

adjust_swappiness_dynamic() {
	local current_swappiness new_swappiness step

	save_pressures_to_vars
	# Read current swappiness (assumed to be an integer)
	current_swappiness=$(cat /proc/sys/vm/swappiness)
	new_swappiness=$current_swappiness
	memory_metric=$memory_some_avg10
	cpu_metric=$cpu_some_avg10
	cpu_low_limit=20
	cpu_high_limit=50
	limit=10
	step=5

	if [ "$(echo "$cpu_metric < $cpu_high_limit" | bc -l)" -eq 1 ] && [ "$(echo "$cpu_metric > $cpu_low_limit" | bc -l)" -eq 1 ]; then
		new_swappiness=$((new_swappiness + step))
		apply_swappiness $new_swappiness
	fi

	if [ "$(echo "$cpu_metric > $cpu_high_limit" | bc -l)" -eq 1 ]; then
		new_swappiness=$((new_swappiness - cpu_high_limit))
		apply_swappiness $new_swappiness
	fi

	if [ "$(echo "$memory_metric > $limit" | bc -l)" -eq 1 ]; then
		new_swappiness=$((new_swappiness - step))
		apply_swappiness $new_swappiness
	fi
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
		exec 3>&1
		set -x
		adjust_swappiness_dynamic
		set +x
		exec 3>&-
		sleep 2
	done &

	new_pid=$!
	save_pid "fmiop.pid" "$new_pid"
}
