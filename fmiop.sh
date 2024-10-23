#!/system/bin/sh
# shellcheck disable=SC3043,SC3060,SC2086,SC2046
TAG=fmiop
LOG_FOLDER=$NVBASE/$TAG
LOGFILE=$LOG_FOLDER/$TAG.log
PID_DB=$LOG_FOLDER/$TAG.pids
POWERKEEPER_USER_DB=/data/data/com.miui.powerkeeper/databases/user_configure.db
[ -z "$ZRAM_BLOCK" ] && ZRAM_BLOCK=$(awk '/zram/ {print $1}' /proc/swaps)

export TAG LOGFILE LOG_FOLDER
alias uprint="ui_print"
alias resetprop="resetprop -v"
alias sqlite3="$MODPATH/sqlite3"

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

lmkd_loger_watcher() {
	local lmkd_log_size today_date log new_pid
	log="$LOG_FOLDER/lmkd.log"

	exec 3>&-
	set +x
	while true; do
		if [ -z "$(read_pid fmiop.lmkd_loger.pid)" ]; then
			exec 3>&1
			set -x

			lmkd_loger "$log"

			exec 3>&-
			set +x
		fi

		lmkd_log_size=$(check_file_size "$log")
		if [ "$lmkd_log_size" -ge 10485760 ]; then
			exec 3>&1
			set -x

			today_date=$(date +%R-%a-%d-%m-%Y)
			new_log_file="${log%.log}_$today_date.log"

			mv "$log" "$new_log_file"
			logrotate ${log%.log}*.log
			lmkd_loger "$log"

			exec 3>&-
			set +x
		fi
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

	[ -n "$zram" ] && for _ in $(seq 60); do
		while true; do
			if swapoff "$zram"; then
				loger "$zram turned off"
				return 0
			fi
			sleep 1
		done
	done

	return 1
}

add_zram() {
	cat /sys/class/zram-control/hot_add
}

resize_zram() {
	local size=$1
	local zram_id

	turnoff_zram "$ZRAM_BLOCK"
	echo 0 >/sys/class/zram-control/hot_remove && loger "$ZRAM_BLOCK removed"
	zram_id=$(add_zram)
	[ -e "$ZRAM_BLOCK" ] && loger "$ZRAM_BLOCK added"
	echo 1 >/sys/block/zram${zram_id}/use_dedup &&
		loger "use_dedup to reduce memory usage"
	echo "$size" >/sys/block/zram${zram_id}/disksize &&
		loger "set ZRAM$zram_id disksize to $size"

	until mkswap "$ZRAM_BLOCK"; do
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

apply_lmkd_props() {
	resetprop -f $MODPATH/system.prop
	resetprop -f $MODPATH/../fogimp/system.prop
}

fmiop() {
	local new_pid minfree_levels
	minfree_levels=$(getprop sys.lmk.minfree_levels)

	if [ -n "$minfree_levels" ]; then
		echo "$minfree_levels" >$LOG_FOLDER/minfree_levels
	fi

	minfree_levels=$(cat $LOG_FOLDER/minfree_levels)
	set +x
	exec 3>&-

	while true; do
		rm_prop sys.lmk.minfree_levels && {
			exec 3>&1
			set -x

			relmkd

			set +x
			exec 3>&-
		}

		memory_pressure=$(get_memory_pressure)
		sed -i "s/\(Memory pressure.*= \)[0-9]*/\1$memory_pressure/" $MODPATH/module.prop

		if is_device_sleeping; then
			exec 3>&1
			set -x

			lmkd_props_clean
			resetprop sys.lmk.minfree_levels "$minfree_levels"
			relmkd

			set +x
			exec 3>&-

			until ! is_device_sleeping; do
				sleep 1
			done

			exec 3>&1
			set -x

			lmkd_props_clean
			apply_lmkd_props
			relmkd

			set +x
			exec 3>&-

		fi
		sleep 2
	done &

	new_pid=$!
	save_pid "fmiop.pid" "$new_pid"
}
