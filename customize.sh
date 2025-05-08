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
- $(date -Is)" >>$LOG

SKIPUNZIP=1
BIN=/system/bin

export MODPATH BIN NVBASE LOG_ENABLED LOG_FOLDER LOG

totalmem=$(free | awk '/^Mem:/ {print $2}')

unzip -o "$ZIPFILE" -x 'META-INF/*' -d "$MODPATH" >&2
alias uprint="ui_print"
alias swapon='$BIN/swapon'

# shellcheck disable=SC1091
. $MODPATH/fmiop.sh

fix_mistakes() {
	ten_mb=10485760

	for file in "$LOG_FOLDER/"*.log; do
		file_size=$(check_file_size $file)

		if [ $file_size -gt $ten_mb ]; then
			ui_print "
- $file size: $file_size is emptied."
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
	set_perm_recursive "$MODPATH/system/bin/dynv-arm64-v8a" 0 2000 0755 0755
	set_perm_recursive "$MODPATH/system/bin/dynv-armeabi-v7a" 0 2000 0755 0755
}

lmkd_apply() {
	# Determine if device is lowram or less than 2GB
	if [ "$totalmem" -lt 2097152 ]; then
		uprint "
- ! Device is low RAM. Applying low RAM tweaks"
		cat <<EOF >$MODPATH/system.prop
ro.config.low_ram=true
ro.lmk.use_psi=true
ro.lmk.debug=false
ro.lmk.use_minfree_levels=false
EOF
	else
		cat <<EOF >$MODPATH/system.prop
ro.config.low_ram=false
ro.lmk.use_psi=true
ro.lmk.debug=false
ro.lmk.use_minfree_levels=false
EOF
	fi

	rm_prop sys.lmk.minfree_levels
}

apply_lmkd_tweaks() {
	# Add workaround for MIUI touch issue when LMKD is in PSI mode
	# because despite its beauty MIUI is having weird issues
	local applied=false
	cat <<EOF

- Apply smoothie🍹tweaks for LMKD?
  Due to unknown reason. LMKD will thrash so much
  on your device until your phone goes slow. 
  This is simple workaround to make your phone 
  stay as smooth as possible. RECOMMENDED to apply.

  Press VOLUME + to apply workaround
  Press VOLUME - to skip
EOF

	exec 3>&-
	set +x

	while true; do
		if get_key_event 'KEY_VOLUMEUP *DOWN'; then
			exec 3>&1
			set -x

			cat <<EOF >>$MODPATH/system.prop
ro.lmk.kill_heaviest_task=false
ro.lmk.psi_partial_stall_ms=60
ro.lmk.psi_complete_stall_ms=650
ro.lmk.swap_util_max=75
ro.lmk.thrashing_limit_decay=80
ro.lmk.thrashing_limit=30
EOF
			applied=true

			exec 3>&-
			set +x
			break
		elif get_key_event 'KEY_VOLUMEDOWN *DOWN'; then
			break
		fi
	done
	kill_capture_pid
	exec 3>&1
	set -x
	[ $applied ] || return 1
}

is_arm64() {
	arch=$(uname -m)
	case "$arch" in
	aarch64 | arm64)
		return 0 # true
		;;
	*)
		return 1 # false
		;;
	esac
}

update_config() {
	rename_key() {
		local target=$3
		local old_key=$1
		local new_key=$2

		if [ $target ] || [ $old_key ] || [ $new_key ]; then
			yq -i "$new_key = $old_key | del($old_key)" $target
		else
			ui_print "
- Missing variable."
		fi
	}

	if [ ! -f "$CONFIG_FILE" ] || [ ! -f "$CONFIG_INTERNAL" ]; then
		mkdir -p $FMIOP_DIR
		cp $current_config $CONFIG_INTERNAL
		cp $current_config $CONFIG_FILE
		ui_print "
- Config is located at $CONFIG_INTERNAL"
		please_reboot=true
	fi

	local current_config_v last_config_v is_update current_config
	current_config=$MODPATH/config.yaml
	current_config_v=$(yq '.config_version' $current_config)
	last_config_v=$(yq '.config_version' $CONFIG_INTERNAL)
	is_update=$(echo "$current_config_v > $last_config_v" | bc -l)

	if [ "$(echo "$last_config_v 0.6" | awk '{print ($1 <= $2) ? 1 : 0}')" -eq 1 ]; then
		mkdir -p $FMIOP_DIR
		cp $CONFIG_INTERNAL $CONFIG_INTERNAL.old
		cp $current_config $CONFIG_INTERNAL
		cp $current_config $CONFIG_FILE
		config_backed=true
	elif [ "$(echo "$last_config_v 0.7" | awk '{print ($1 <= $2) ? 1 : 0}')" -eq 1 ]; then
		cp $CONFIG_INTERNAL $CONFIG_INTERNAL.old
		rename_key .dynamic_swappiness.threshold_psi .dynamic_swappiness.threshold $CONFIG_INTERNAL
		yq ea -i 'select(fileIndex == 0) * select(fileIndex > 0) | sort_keys(.)' $current_config $CONFIG_INTERNAL
		yq -i ".config_version = $current_config_v" $current_config
		cp $current_config $CONFIG_INTERNAL
		cp $CONFIG_INTERNAL $CONFIG_FILE
		uprint "
- Config: $CONFIG_INTERNAL is updated"
		config_backed=true
	elif [ "$last_config_v" = "null" ] || [ $is_update -eq 1 ]; then # Adding new values
		cp $CONFIG_INTERNAL $CONFIG_INTERNAL.old
		yq ea -i 'select(fileIndex == 0) * select(fileIndex > 0) | sort_keys(.)' $current_config $CONFIG_INTERNAL
		yq -i ".config_version = $current_config_v" $current_config
		cp $current_config $CONFIG_INTERNAL
		cp $CONFIG_INTERNAL $CONFIG_FILE
		uprint "- Config: $CONFIG_INTERNAL is updated"
		config_backed=true
	fi

	[ $config_backed ] &&
		uprint "
! Backup $CONFIG_INTERNAL.old created
  Config is located at $CONFIG_INTERNAL"
}

update_tools() {
	if [ -e "$NVBASE/modules/$TAG" ]; then
		MOD_DIR=$NVBASE/modules/$TAG
		cp $MODPATH/action.sh $MOD_DIR
		cp $MODPATH/fmiop.sh $MOD_DIR
		$BIN/cp -rf $MODPATH/tools $MOD_DIR
	fi
}

remove_fogimp() {
	miui_v=$(resetprop ro.miui.ui.version.code)
	bootimg_model=$(resetprop ro.product.bootimage.model)
	product_model=$(resetprop ro.product.model)

	if [ $bootimg_model != "Redmi 10C" ] || [ $product_model != "220333QAG" ] || [ -z $miui_v ]; then
		touch /data/adb/modules/fogimp/remove
		ui_print ""
		ui_print "- Fogimp marked for removal."
		please_reboot=true
	fi
}

main() {
	local android_version
	android_version=$(getprop ro.build.version.release)

	if ! is_arm64; then
		ln -sf $MODPATH/system/bin/dynv-armeabi-v7a $MODPATH/system/bin/dynv
	else
		ln -sf $MODPATH/system/bin/dynv-arm64-v8a $MODPATH/system/bin/dynv
	fi

	printenv >$LOG_FOLDER/env.log

	if ! [ -f $LOG_FOLDER/.redempted ]; then
		fix_mistakes
	fi

	kill_all_pids
	set_permissions

	if [ "$android_version" -lt 10 ]; then
		uprint "- Your Android version is not supported. Performance
tweaks won't be applied. Please upgrade your phone 
to Android 10+"
	else
		uprint "
- Total memory = $(free -h | awk '/^Mem:/ {print $2}')"
		ui_print "
- ZRAM will be set to $(free -h | awk '/^Mem:/ {print $2}') on boot."

		lmkd_apply
		apply_lmkd_tweaks && smoothie_text="& smoothie🍹tweaks"
		echo "
- Applying LMKD tweaks properties $smoothie_text
		"
		approps $MODPATH/system.prop
		uprint "- LMKD PSI mode activated."
		setup_swap
		update_config

		$MODPATH/log_service.sh
		$MODPATH/fmiop_service.sh

		kill -0 "$(read_pid fmiop.lmkd_loger.pid)" && uprint "
- LMKD PSI service keeper started"
		relmkd
	fi

	apply_uffd_gc
	update_tools
	remove_fogimp

	[ $please_reboot ] &&
		uprint "
- REBOOT now"
	cp $MODPATH/module.prop $LOG_FOLDER
}

main