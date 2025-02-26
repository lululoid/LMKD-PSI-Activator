#!/system/bin/sh
# shellcheck disable=SC3043,SC2034,SC2086,SC3060,SC3010
# save full logging
NVBASE=/data/adb
BIN=/system/bin
MODPATH=$PWD
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

	uprint "
⟩ Please select your option
  Press VOLUME + to use REMOVE
  Press VOLUME - to SELECT 
  DEFAULT is 0 SWAP
  "

	while true; do
		if get_key_event 'KEY_VOLUMEUP *DOWN'; then
			available_swaps=$(find $SWAP_PATTERN 2>/dev/null | sort)

			for swap in $available_swaps; do
				swapoff $swap
				rm -rf $swap && uprint "  Swap file: $swap removed."
			done
			break
		elif get_key_event 'KEY_VOLUMEDOWN *DOWN'; then
			break
		fi
	done
	kill -9 $capture_pid
}

if [ ! -f $SWAP_PATTERN ]; then
	setup_swap
else
	remove_previous_swap
fi
