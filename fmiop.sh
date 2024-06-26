#!/system/bin/sh
# shellcheck disable=SC3043,SC3060,SC2086,SC2046
TAG=fmiop
LOGFILE=$NVBASE/$TAG.log

export TAG LOGFILE

loger() {
	local log=$1
	true &&
		[ -n "$log" ] && echo "> $log" >>$LOGFILE
}

rm_prop() {
	for prop in "$@"; do
		resetprop -d $prop && cat <<EOF

  $prop deleted
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

  $prop 
EOF
			{
				[ "$(getprop $prop)" == ${value//=/ } ] &&
					ui_print "  $value"
			} || ui_print "  ! Failed"
		done
}

notif() {
	local body=$1

	su -lp 2000 -c \
		"cmd notification post -S bigtext -t 'fmiop' 'Tag' '$body'"
}

set_mem_limit() {
	totalmem=$($BIN/free | awk '/^Mem:/ {print $2}')
	mem_limit=$1
	[ -z $mem_limit ] &&
		mem_limit=$(awk -v size="$totalmem" \
			'BEGIN { printf "%.0f\n", size * 0.65 }')

	echo $mem_limit >/sys/block/zram0/mem_limit
	uprint "
> set_mem_limit to $mem_limit" || loger "set_mem_limit to $mem_limit"
}

resize_zram() {
	local zram=/dev/block/zram0
	local size=$1

	swapoff $zram && loger "$zram turned off"
	echo 0 >/sys/class/zram-control/hot_remove &&
		loger "zram0 removed"
	cat /sys/class/zram-control/hot_add &&
		loger "zram added"
	echo 1 >/sys/block/zram0/use_dedup &&
		loger "use_dedup activated"
	echo $size >/sys/block/zram0/disksize &&
		loger "set $zram disksize to $size"
	mkswap $zram
	$BIN/swapon "$zram" && loger "$zram turned on" && return 0
}

lmkd_loger() {
	kill -9 $(resetprop lmkd_loger.pid)
	resetprop -d lmkd_loger.pid

	while true; do
		! kill -0 $(resetprop lmkd_loger.pid) && {
			$BIN/logcat -v time --pid=$(pidof lmkd) \
				--file=/data/local/tmp/lmkd.log
		}
	done &

	resetprop lmkd_loger.pid $!
}

save_lmkd_props() {
	local save=$1

	set --
	set \
		ro.lmk.thrashing_limit_decay \
		ro.lmk.swap_free_low_percentage \
		ro.lmk.low \
		ro.lmk.medium \
		ro.lmk.critical \
		ro.lmk.critical_upgrade \
		ro.lmk.upgrade_pressure \
		ro.lmk.downgrade_pressure \
		ro.lmk.psi_partial_stall_ms \
		ro.lmk.psi_complete_stall_ms \
		ro.lmk.kill_heaviest_task \
		ro.lmk.swap_util_max \
		persist.device_config.lmkd_native.thrashing_limit_critical

	rm $save

	for prop in "$@"; do
		prop_val=$(resetprop $prop)

		[ -n $prop_val ] &&
			echo "$prop=$prop_val" >>$save
	done
}

fmiop() {
	local save=/data/local/tmp/lmkd_props

	exec 3>/dev/null 1>>/dev/null 2>&1
	set +x

	while true; do
		rm_prop sys.lmk.minfree_levels && {
			exec 3>&1 1>>"$NVBASE/fmiop.log" 2>&1
			set -x

			save_lmkd_props $save
			rm_prop $(echo $(sed 's/\(.*\)=.*/\1/' $save))
			relmkd
			sleep 5m
			approps $save
			relmkd
		}
		sleep 5
	done &
	resetprop fmiop.pid $!
}
