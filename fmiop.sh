#!/system/bin/sh
# shellcheck disable=SC3043,SC3060,SC2086,SC2046
TAG=fmiop
LOGFILE=$NVBASE/$TAG.log
ZRAM=/dev/block/zram0

export TAG LOGFILE
alias uprint="ui_print"

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
	until
		swapoff $ZRAM
	do
		sleep 1
	done
}

resize_zram() {
	local size=$1

	turnoff_zram && loger "$ZRAM turned off"
	echo 0 >/sys/class/zram-control/hot_remove &&
		loger "$ZRAM removed"
	cat /sys/class/zram-control/hot_add &&
		loger "$ZRAM added"
	echo 1 >/sys/block/zram0/use_dedup &&
		loger "use_dedup to reduce memory usage"
	echo $size >/sys/block/zram0/disksize &&
		loger "set $ZRAM disksize to $size"

	# keep trying until it's succeded
	until mkswap $ZRAM; do
		swapoff $ZRAM
	done
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

fmiop() {
	# turn off logging to prevent unnecessary loop logging
	set +x
	exec 3>&-

	while true; do
		rm_prop sys.lmk.minfree_levels && {
			# turn on logging back, can't use function because it doesn't work
			exec 3>&1
			set -x

			if [ -n "$(resetprop fmiop.pid)" ]; then
				echo "
⟩ sys.lmk.minfree_levels deleted because of your system"
			elif [ -z "$(resetprop fmiop.pid)" ]; then
				echo "
⟩ sys.lmk.minfree_levels deleted"
			fi
			relmkd

			set +x
			exec 3>&-
		}
		sleep 5
	done &
	resetprop fmiop.pid $!
}
