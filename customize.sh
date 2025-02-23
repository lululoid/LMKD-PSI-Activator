#!/system/bin/sh
# shellcheck disable=SC3043,SC2034,SC2086,SC3060,SC3010
# save full logging
NVBASE=/data/adb
LOG_FOLDER=$NVBASE/fmiop
LOG=$LOG_FOLDER/fmiop.log
mkdir -p $LOG_FOLDER
exec 3>&1 1>>$LOG 2>&1
# restore stdout for magisk
exec 1>&3
set -x
echo "
⟩ $(date -Is)" >>$LOG

SKIPUNZIP=1
BIN=/system/bin

export MODPATH BIN NVBASE LOG_ENABLED LOG_FOLDER LOG

totalmem=$(free | awk '/^Mem:/ {print $2}')

unzip -o "$ZIPFILE" -x 'META-INF/*' -d "$MODPATH" >&2
alias uprint="ui_print"
alias swapon="$BIN/swapon"

. $MODPATH/fmiop.sh

fix_mistakes() {
	ten_mb=10485760

	for file in "$LOG_FOLDER/"*.log; do
		file_size=$(check_file_size $file)

		if [ $file_size -ge $ten_mb ]; then
			ui_print "
$file size: $file_size is emptied."
			echo "" >$file
		fi
	done || return 1

	rm -rf $LOG_FOLDER/lmkd.log.*
	touch $LOG_FOLDER/.redempted
}

set_permissions() {
	set_perm_recursive "$MODPATH" 0 0 0755 0644
	set_perm_recursive "$MODPATH/sed" 0 2000 0755 0755
	set_perm_recursive "$MODPATH/yq" 0 2000 0755 0755
	set_perm_recursive "$MODPATH/fmiop.sh" 0 2000 0755 0755
	set_perm_recursive "$MODPATH/fmiop_service.sh" 0 2000 0755 0755
	set_perm_recursive "$MODPATH/log_service.sh" 0 2000 0755 0755
	set_perm_recursive "$MODPATH/sqlite3" 0 2000 0755 0755
}

lmkd_apply() {
	# Determine if device is lowram or less than 2GB
	if [ "$totalmem" -lt 2097152 ]; then
		uprint "
  ! Device is low RAM. Applying low RAM tweaks
"
		cat <<EOF >>$MODPATH/system.prop
ro.config.low_ram=true
ro.lmk.use_psi=true
ro.lmk.debug=false
ro.lmk.use_minfree_levels=false
EOF
	else
		cat <<EOF >>$MODPATH/system.prop
ro.config.low_ram=false
ro.lmk.use_psi=true
ro.lmk.debug=false
ro.lmk.use_minfree_levels=false
EOF
	fi

	rm_prop sys.lmk.minfree_levels
	approps $MODPATH/system.prop
	uprint "⟩ LMKD PSI mode activated
  RAM is better utilized with something useful than left unused"
}

# Function to get key events
get_key_event() {
	local event_type="$1"
	local event_file="$TMPDIR/events"

	# Capture events
	/system/bin/getevent -lqc 1 >"$event_file" 2>&1 &

	# Check for the specific event
	grep -q "$event_type" "$event_file"
}

# Function to handle SWAP size logic
handle_swap_size() {
	if [ $count -eq 0 ]; then
		swap_size=0
		swap_in_gb=0
		uprint "  $count. 0 SWAP --⟩ RECOMMENDED"
	elif [ $swap_in_gb -lt $totalmem_gb ]; then
		swap_in_gb=$((swap_in_gb + 1))
		uprint "  $count. ${swap_in_gb}GB of SWAP"
		swap_size=$((swap_in_gb * one_gb))
	fi

	count=$((count + 1))
}

# Main loop to handle user input and adjust SWAP size
setup_swap_size() {
	local one_gb=$((1024 * 1024))
	local totalmem_gb=$(((totalmem / 1024 / 1024) + 1))
	local count=0
	local swap_in_gb=0
	hundred_mb=$((one_gb / 10))
	swap_size=0

	uprint "
⟩ Please select SWAP size 
  Press VOLUME + to use DEFAULT
  Press VOLUME - to SELECT 
  DEFAULT is 0 SWAP
  "

	set +x
	exec 3>&-

	while true; do
		if get_key_event 'KEY_VOLUMEDOWN *DOWN'; then
			handle_swap_size
		elif [ $swap_in_gb -eq $totalmem_gb ] && [ $count != 0 ]; then
			swap_size=$totalmem
			count=0
		elif get_key_event 'KEY_VOLUMEUP *DOWN'; then
			break
		fi
	done

	set -x
	exec 3>&1
}

make_swap() {
	dd if=/dev/zero of="$2" bs=1024 count="$1" >/dev/null
	mkswap -L fmiop_swap "$2" >/dev/null
	chmod 0600 "$2"
}

setup_swap() {
	local swap_filename free_space
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
			swap_count=$((swap_size / hundred_mb))
			for num in $(seq $swap_count); do
				make_swap "$hundred_mb" "$swap_filename.$num"
			done
		elif [ $swap_size -eq 0 ]; then
			:
		else
			uprint "
⟩ Storage full. Please free up your storage"
		fi
	fi
}

apply_touch_issue_workaround() {
	# Add workaround for MIUI touch issue when LMKD is in PSI mode
	# because despite its beauty MIUI is having weird issues
	cat <<EOF
⟩ Do you want some smoothie🍹? Due to unknown
  reason. LMKD will thrash so much on your device 
  until your phone goes slow. This is simple work- 
  around to make your phone stay as smooth as 
  possible.

  Press VOLUME + to apply workaround
  Press VOLUME - to skip

EOF

	while true; do
		if get_key_event 'KEY_VOLUMEUP *DOWN'; then
			echo "  › Installing fogimp module 🍹
"
			magisk --install-module $MODPATH/packages/fogim*
			echo ""
			break
		elif get_key_event 'KEY_VOLUMEDOWN *DOWN'; then
			break
		fi
	done
}

main() {
	local android_version miui_v_code
	android_version=$(getprop ro.build.version.release)

	kill_all_pids
	if [ "$android_version" -lt 10 ]; then
		uprint "
⟩ Your Android version is not supported. Performance
tweaks won't be applied. Please upgrade your phone 
to Android 10+"
	else
		miui_v_code=$(resetprop ro.miui.ui.version.code)
		cat <<EOF
⟩ Total memory = $(free -h | awk '/^Mem:/ {print $2}')

EOF

		apply_touch_issue_workaround
		if [ -n "$miui_v_code" ]; then
			echo "⟩ Applying lowmemorykiller properties
	"
			lmkd_apply

			# Add workaround to keep MIUI from re-adding sys.lmk.minfree_levels property back
			$MODPATH/fmiop_service.sh
			kill -0 "$(read_pid fmiop.lmkd_loger.pid)" && uprint "
⟩ LMKD PSI service keeper started
"
		else
			echo "
⟩ Applying lowmemorykiller properties
	"
			lmkd_props_clean
			lmkd_apply
		fi
		relmkd
		$MODPATH/log_service.sh
	fi
}

if ! [ -f $LOG_FOLDER/.redempted ]; then
	fix_mistakes
fi

set_permissions
setup_swap
main
cp $MODPATH/module.prop $LOG_FOLDER
[ ! -f $LOG_FOLDER/config.yaml ] && cp $MODPATH/config.yaml $LOG_FOLDER
