#!/system/bin/sh
# shellcheck disable=SC3043,SC2034,SC2086,SC3060,SC3010
# save full logging
NVBASE=/data/adb
BIN=/system/bin
[ -e $NVBASE/modules/fmiop ] && MODPATH=$NVBASE/modules/fmiop
[ -e $NVBASE/modules_update/fmiop ] && MODPATH=$NVBASE/modules_update/fmiop
LOG_FOLDER="$NVBASE/fmiop" # Directory for fmiop logs
script_name=$(basename $0)
LOG="$LOG_FOLDER/${script_name%.sh}.log" # Main log file
TMPDIR=/data/local/tmp

exec 3>&1 1>>"$LOG" 2>&1
exec 1>&3
set -x # Prints commands, prefixing them with a character stored in an environmental variable ($PS4)

alias uprint="echo"
alias swapon='$BIN/swapon'

. $MODPATH/fmiop.sh

remove_previous_swap() {
	local available_swaps swap

	uprint "⟩ Please select your option
  Press VOLUME + to use REMOVE existing SWAP
  Press VOLUME - to cancel
  "
	exec 3>&-
	set +x

	if [ -n "$SWAP_FILENAME" ]; then
		while true; do
			if get_key_event 'KEY_VOLUMEUP *DOWN'; then
				exec 3>&1
				set -x

				available_swaps=$(find $SWAP_FILENAME* 2>/dev/null | sort)

				for swap in $available_swaps; do
					swapoff $swap
					rm -rf $swap && uprint "  › Swap file: $swap removed."
				done

				uprint "
⟩ Press action again to remake SWAP."

				exec 3>&-
				set +x
				break
			elif get_key_event 'KEY_VOLUMEDOWN *DOWN'; then
				uprint "  › Action cancelled."
				break
			fi
		done
	else
		uprint "
- Error, SWAP_FILENAME variable is missing"
	fi
	kill_capture_pid
}

restart_dynv() {
	kill_dynv
	$MODPATH/system/bin/dynv &
	loger "Started dyn_swap_service with PID $!"

}

available_swaps=$(find $SWAP_FILENAME*)
if [ -z "$available_swaps" ]; then
	uprint "⟩ Remaking SWAP option"
	setup_swap
	restart_dynv
else
	remove_previous_swap
	restart_dynv
fi
