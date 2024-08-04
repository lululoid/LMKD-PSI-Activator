#!/system/bin/sh
# shellcheck disable=SC3043,SC3060,SC2086,SC2046
TAG=fmiop
LOG_FOLDER=$NVBASE/$TAG
LOGFILE=$LOG_FOLDER/$TAG.log
PID_DB=$LOG_FOLDER/$TAG.pids

[ -z $ZRAM_BLOCK ] && ZRAM_BLOCK=$(awk '/zram/ {print $1}' /proc/swaps)

export TAG LOGFILE
alias uprint="ui_print"

loger() {
	local log=$1
	[ -n "$log" ] && echo "⟩ $log" >>$LOGFILE
}

logrotate() {
	local count=0

	for log in "$@"; do
		count=$((count + 1))

		if [ "$count" -gt 2 ]; then
			# shellcheck disable=SC2012
			oldest_log=$(ls -tr "$1" | head -n 1)
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

	if ! resetprop $pid_name $pid_value; then
		echo "$pid_name=$pid_value" >>$PID_DB
	fi
}

read_pid() {
	local pid_name=$1
	local pid_value

	pid_value=$(resetprop $pid_name 2>/dev/null)
	if [ -z "$pid_value" ]; then
		pid_value=$(awk -F= -v name="$pid_name" '$1 == name {print $2}' $PID_DB)
	fi

	echo $pid_value
}

remove_pid() {
	local pid_name=$1

	if resetprop -d $pid_name; then
		sed -i "/^$pid_name=/d" $PID_DB
	fi
}

lmkd_loger() {
	local log_file
	log_file=$1

	resetprop ro.lmk.debug true
	kill -9 $(read_pid fmiop.lmkd_loger.pid)
	remove_pid "fmiop.lmkd_loger.pid"
	$BIN/logcat -v time --pid=$(pidof lmkd) --file=$log_file &
	local new_pid=$!
	save_pid "fmiop.lmkd_loger.pid" $new_pid
}

lmkd_loger_watcher() {
	local lmkd_log_size today_date lmkd_log_size
	local log="$LOG_FOLDER/lmkd.log"

	exec 3>&-
	set +x
	while true; do

		# check for loggers pid, if it doesn't exist start one
		[ -z $(read_pid fmiop.lmkd_loger.pid) ] && {
			exec 3>&1
			set -x

			lmkd_loger $log

			exec 3>&-
			set +x
		}

		# limit log size to 10MB then restart the service if it exceeds it
		lmkd_log_size=$(check_file_size $log)
		[ $lmkd_log_size -ge 10485760 ] && {
			exec 3>&1
			set -x

			today_date=$(date +%R-%a-%d-%m-%Y)
			new_log_file="${log%.log}_$today_date.log"

			mv "$log" $new_log_file
			lmkd_loger $log
			logrotate $LOG_FOLDER/${log*%.log}

			exec 3>&-
			set +x
		}
		sleep 1
	done &

	local new_pid=$!
	save_pid "fmiop.lmkd_loger_watcher.pid" $new_pid
}

rm_prop() {
	for prop in "$@"; do
		resetprop -d $prop && cat <<EOF

  X $prop deleted

EOF
	done
}

relmkd() {
	resetprop lmkd.reinit 1
}

approps() {
	prop_file=$1

	set -f
	grep -v '^ *#' "$prop_file" |
		while IFS='=' read -r prop value; do
			resetprop -n -p $prop $value
			cat <<EOF
  › $prop 
EOF
			{
				# shellcheck disable=SC3014
				[ "$(getprop $prop)" == ${value//=/ } ] &&
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
			if swapoff $zram; then
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

	turnoff_zram $ZRAM_BLOCK
	echo 0 >/sys/class/zram-control/hot_remove && loger "$ZRAM_BLOCK removed"
	# should be after turning off zram
	zram_id=$(add_zram)
	[ -e $ZRAM_BLOCK ] && loger "$ZRAM_BLOCK added"
	echo 1 >/sys/block/zram${zram_id}/use_dedup &&
		loger "use_dedup to reduce memory usage"
	echo $size >/sys/block/zram${zram_id}/disksize &&
		loger "set ZRAM$zram_id disksize to $size"

	# keep trying until it's succeeded
	until mkswap $ZRAM_BLOCK; do
		sleep 1
	done
}

fmiop() {
	# turn off logging to prevent unnecessary loop logging
	set +x
	exec 3>&-

	while true; do
		rm_prop sys.lmk.minfree_levels && {
			# turn on logging back, can't use function because it doesn't work
			exec 3>&1
			set -x

			relmkd

			set +x
			exec 3>&-
		}
		sleep 5
	done &
	local new_pid=$!
	save_pid "fmiop.pid" $new_pid
}
