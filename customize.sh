#!/system/bin/sh
# shellcheck disable=SC3043,SC2034,SC2086,SC3060,SC3010
# save full logging
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

set_permissions() {
	set_perm_recursive "$MODPATH" 0 0 0755 0644
	set_perm_recursive "$MODPATH/sed" 0 2000 0755 0755
	set_perm_recursive "$MODPATH/fmiop.sh" 0 2000 0755 0755
	set_perm_recursive "$MODPATH/fmiop_service.sh" 0 2000 0755 0755
	set_perm_recursive "$MODPATH/log_service.sh" 0 2000 0755 0755
}

lmkd_apply() {
	# determine if device is lowram?
	cat <<EOF

⟩ Total memory = $(free -h | awk '/^Mem:/ {print $2}')
EOF

	if [ "$totalmem" -lt 2097152 ]; then
		uprint "
  ! Device is low RAM. Applying low RAM tweaks
"
		cat <<EOF >>$MODPATH/system.prop
ro.config.low_ram=true
ro.lmk.use_psi=true
ro.lmk.debug=true
ro.lmk.use_minfree_levels=false
EOF
	else
		cat <<EOF >>$MODPATH/system.prop
ro.config.low_ram=false
ro.lmk.use_psi=true
ro.lmk.debug=true
ro.lmk.use_minfree_levels=false
EOF
	fi

	rm_prop sys.lmk.minfree_levels
	approps $MODPATH/system.prop
	relmkd
	uprint "⟩ LMKD PSI mode activated
  RAM is better utilized with something useful than left unused
"
}

count_swap() {
	local one_gb=$((1024 * 1024))
	local totalmem_gb=$(((totalmem / 1024 / 1024) + 1))
	local count=0
	local swap_in_gb=0
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
		# shellcheck disable=SC2069
		timeout 0.5 /system/bin/getevent -lqc 1 2>&1 >"$TMPDIR"/events &
		sleep 0.5
		if grep -q 'KEY_VOLUMEDOWN *DOWN' "$TMPDIR"/events; then
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
		elif [ $swap_in_gb -eq $totalmem_gb ] && [ $count != 0 ]; then
			swap_size=$totalmem
			count=0
		elif grep -q 'KEY_VOLUMEUP *DOWN' "$TMPDIR"/events; then
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

	if [ ! -f "$swap_filename" ]; then
		count_swap
		if [ "$free_space" -ge "$swap_size" ] && [ "$swap_size" != 0 ]; then
			uprint "
⟩ Starting making SWAP. Please wait a moment
  $((free_space / 1024))MB available. $((swap_size / 1024))MB needed"
			make_swap "$swap_size" "$swap_filename" &&
				swapon -p 32766 "$swap_filename"
		elif [ $swap_size -eq 0 ]; then
			:
		else
			uprint "
⟩ Storage full. Please free up your storage"
		fi
	fi
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

		if [ -n "$miui_v_code" ]; then
			# Add workaround for MIUI touch issue when LMKD is in PSI mode
			# because despite its beauty MIUI is having weird issues
			uprint "
⟩ Due to MIUI bug, please turn off the screen and turn it on again if
  you experience touch issues, like can't use navigation
  gesture or ghost touch"
			lmkd_apply
			# Add workaround to keep MIUI from re-adding sys.lmk.minfree_levels
			# prop back
			$MODPATH/fmiop_service.sh
			uprint "
⟩ LMKD PSI service keeper started"
		else
			lmkd_apply
		fi
		$MODPATH/log_service.sh
	fi
}

set_permissions
setup_swap
main
