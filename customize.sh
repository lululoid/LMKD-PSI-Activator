#!/system/bin/sh
# shellcheck disable=SC3043,SC2034,SC2086,SC3060,SC3010
# save full logging
NVBASE=/data/adb
TAG=fmiop
LOG_FOLDER=$NVBASE/$TAG
LOG="$LOG_FOLDER/installation.log" # Main log file

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
alias swapon='$BIN/swapon'

. $MODPATH/fmiop.sh

fix_mistakes() {
	ten_mb=10485760

	for file in "$LOG_FOLDER/"*.log; do
		file_size=$(check_file_size $file)

		if [ $file_size -gt $ten_mb ]; then
			ui_print "
⟩ $file size: $file_size is emptied."
			echo "" >$file
		fi
	done || return 1

	rm -rf $LOG_FOLDER/lmkd.log.*
	rm -rf "${LOG_FOLDER:?}/${SWAP_FILENAME:?}*"
	touch $LOG_FOLDER/.redempted
}

set_permissions() {
	set_perm_recursive "$MODPATH" 0 0 0755 0644
	set_perm_recursive "$MODPATH/tools" 0 2000 0755 0755
	set_perm_recursive "$MODPATH/fmiop.sh" 0 2000 0755 0755
	set_perm_recursive "$MODPATH/fmiop_service.sh" 0 2000 0755 0755
	set_perm_recursive "$MODPATH/log_service.sh" 0 2000 0755 0755
	set_perm_recursive "$MODPATH/system/bin/dynv" 0 2000 0755 0755
}

lmkd_apply() {
	# Determine if device is lowram or less than 2GB
	if [ "$totalmem" -lt 2097152 ]; then
		uprint "
⟩ ! Device is low RAM. Applying low RAM tweaks"
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
	uprint "
⟩ LMKD PSI mode activated
  RAM is better utilized with something useful than left unused"
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

	exec 3>&-
	set +x

	while true; do
		if get_key_event 'KEY_VOLUMEUP *DOWN'; then
			exec 3>&1
			set -x

			echo "  › Installing fogimp module 🍹
"
			magisk --install-module $MODPATH/packages/fogim*
			echo ""

			exec 3>&-
			set +x
			break
		elif get_key_event 'KEY_VOLUMEDOWN *DOWN'; then
			break
		fi
	done
	kill -9 $capture_pid
}

main() {
	local android_version miui_v_code
	android_version=$(getprop ro.build.version.release)

	kill_all_pids
	if [ "$android_version" -lt 10 ]; then
		uprint "⟩ Your Android version is not supported. Performance
tweaks won't be applied. Please upgrade your phone 
to Android 10+"
	else
		miui_v_code=$(resetprop ro.miui.ui.version.code)
		uprint "
⟩ Total memory = $(free -h | awk '/^Mem:/ {print $2}')
"

		apply_touch_issue_workaround
		echo "
⟩ Applying lowmemorykiller properties"
		lmkd_apply
		$MODPATH/log_service.sh
		$MODPATH/fmiop_service.sh
		kill -0 "$(read_pid fmiop.lmkd_loger.pid)" && uprint "
⟩ LMKD PSI service keeper started"
		relmkd
	fi
}

update_config() {
	local current_config_v last_config_v is_update current_config
	current_config=$MODPATH/config.yaml
	current_config_v=$(yq '.config_version' $current_config)
	last_config_v=$(yq '.config_version' $CONFIG_FILE)
	is_update=$(echo "$current_config_v > $last_config_v" | bc -l)

	if [ ! -f "$CONFIG_FILE" ]; then
		mkdir -p $FMIOP_DIR
		cp $current_config $CONFIG_FILE
		config_ready=true
		please_reboot=true
	elif [ "$(echo "$last_config_v 0.2" | awk '{print ($1 == $2) ? 1 : 0}')" -eq 1 ]; then
		mkdir -p $FMIOP_DIR
		cp $current_config $CONFIG_FILE
		config_ready=true
	elif [ "$(echo "$last_config_v 0.4" | awk '{print ($1 == $2) ? 1 : 0}')" -eq 1 ]; then
		mkdir -p $FMIOP_DIR
		cp $current_config $CONFIG_FILE
	elif [ "$last_config_v" = "null" ] || [ $is_update -eq 1 ]; then
		yq ea -i 'select(fileIndex == 0) * select(fileIndex > 0) | sort_keys(.)' $CONFIG_FILE $current_config
		uprint "
⟩ Config: $CONFIG_FILE is updated"
	fi

	[ $config_ready ] &&
		uprint "
⟩ Config is located in $CONFIG_FILE"
	[ $please_reboot ] &&
		uprint "
⟩ REBOOT now"
}

set_permissions

if ! [ -f $LOG_FOLDER/.redempted ]; then
	fix_mistakes
fi

if [ -e "$NVBASE/modules/$TAG" ]; then
	MOD_DIR=$NVBASE/modules/$TAG
	cp $MODPATH/action.sh $MOD_DIR
	cp $MODPATH/fmiop.sh $MOD_DIR
	$BIN/cp -rf $MODPATH/tools $MOD_DIR
fi

setup_swap
main
update_config
