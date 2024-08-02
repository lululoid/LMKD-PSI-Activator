#!/system/bin/sh
# shellcheck disable=SC3043,SC3060,SC2086,SC2046
TAG=fmiop
LOGFILE=$NVBASE/$TAG.log
[ -z $ZRAM_BLOCK ] && ZRAM_BLOCK=$(awk '/zram/ {print $1}' /proc/swaps)

export TAG LOGFILE
alias uprint="ui_print"

watch_log_file_size() {
	local file_size
	local log_file=$1
	local max_size=$((10 * 1024 * 1024)) # 10MB in bytes
	local watch_log_file_size_pids
	watch_log_file_size_pids=$(getprop fmiop.watch_log_file_size.pids)

	if [ ! -f "$log_file" ]; then
		echo "Log file does not exist: $log_file"
		return 1
	fi

	set +x
	exec 3>&-
	while true; do
		# Check if the file size exceeds the max size
		file_size=$(stat -c%s "$log_file" 2>/dev/null)

		if [ -z $file_size ]; then
			exec 3>&1
			set -x

			echo "Error getting file size for $log_file"

			set +x
			exec 3>&-

			return 1
		fi

		if [ $file_size -gt $max_size ]; then
			exec 3>&1
			set -x

			local new_log_file="${log_file%.log}_2.log"

			mv "$log_file" "$new_log_file"
			echo "Renamed $log_file to $new_log_file"

			set +x
			exec 3>&-
		fi
		sleep 1
	done &

	exec 3>&1
	set -x

	local new_pid=$!
	if [ -n "$watch_log_file_size_pids" ]; then
		resetprop fmiop.watch_log_file_size.pids "${watch_log_file_size_pids} ${new_pid}"
	else
		resetprop fmiop.watch_log_file_size.pids "$new_pid"
	fi
}

loger() {
	local log=$1
	true &&
		[ -n "$log" ] && echo "⟩ $log" >>$LOGFILE
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

	[ -n "$zram" ] && for tick in $(seq 60); do
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
	# should be after turning off zram

	turnoff_zram $ZRAM_BLOCK
	echo 0 >/sys/class/zram-control/hot_remove && loger "$ZRAM_BLOCK removed"
	zram_id=$(add_zram)
	[ -e $ZRAM_BLOCK ] && loger "$ZRAM_BLOCK added"
	echo 1 >/sys/block/zram${zram_id}/use_dedup &&
		loger "use_dedup to reduce memory usage"
	echo $size >/sys/block/zram${zram_id}/disksize &&
		loger "set ZRAM$zram_id disksize to $size"

	# keep trying until it's succeded
	until mkswap $ZRAM_BLOCK; do
		sleep 1
	done
}

lmkd_loger() {
	local log_file
	log_file=$NVBASE/lmkd.log

	resetprop ro.lmk.debug true
	kill -9 $(resetprop lmkd_loger.pid)
	resetprop -d lmkd_loger.pid

	while true; do
		! kill -0 $(resetprop lmkd_loger.pid) && {
			$BIN/logcat -v time --pid=$(pidof lmkd) --file=$log_file
			resetprop lmkd_loger.pid $!
		}
		sleep 1
	done &

	watch_log_file_size $log_file
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
	resetprop fmiop.pid $!
}
