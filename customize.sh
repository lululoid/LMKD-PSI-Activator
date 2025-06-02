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
}

lmkd_apply() {
	# Determine if device is lowram or less than 2GB
	if [ "$totalmem" -lt 2097152 ]; then
		uprint "
- ! Device is low RAM. Applying low RAM tweaks"
		cat <<EOF >$MODPATH/system.prop
ro.config.low_ram=true
ro.lmk.use_psi=true
ro.lmk.use_minfree_levels=false
EOF
	else
		cat <<EOF >$MODPATH/system.prop
ro.config.low_ram=false
ro.lmk.use_psi=true
ro.lmk.use_minfree_levels=false
EOF
		cat <<EOF >>$MODPATH/system.prop
ro.lmk.debug=false
EOF
	fi

	rm_prop sys.lmk.minfree_levels
}

apply_lmkd_tweaks() {
	# Add workaround for MIUI touch issue when LMKD is in PSI mode
	# because despite its beauty MIUI is having weird issues
	local applied=false
	cat <<EOF

- Due to unknown reason. LMKD will thrash so much
  on your device until your phone goes slow. 
  This is simple workaround to make your phone 
  stay as smooth as possible.
EOF

	cat <<EOF >>$MODPATH/system.prop
ro.lmk.kill_heaviest_task=false
ro.lmk.thrashing_limit_decay=80
ro.lmk.thrashing_limit=30
EOF
	applied=true

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
			printf '\n- Missing variable.'
		fi
	}

	local current_config_v last_config_v is_update current_config
	current_config=$MODPATH/config.yaml
	current_config_v=$(yq '.config_version' $current_config)
	last_config_v=$(yq '.config_version' $CONFIG_INTERNAL)
	is_update=$(echo "$current_config_v > $last_config_v" | bc -l)

	if [ ! -f "$CONFIG_FILE" ] || [ ! -f "$CONFIG_INTERNAL" ]; then
		mkdir -p $FMIOP_DIR
		cp $current_config $CONFIG_INTERNAL
		cp $current_config $CONFIG_FILE
		printf '\n- Config is located at'
		printf '  > Internal -> Android/data/%s/config.yaml' "$TAG"
		please_reboot=true
	fi

	if [ "$(echo "$last_config_v 0.9" | awk '{print ($1 < $2) ? 1 : 0}')" -eq 1 ]; then
		mkdir -p $FMIOP_DIR
		cp $CONFIG_INTERNAL $CONFIG_INTERNAL.old
		cp $current_config $CONFIG_INTERNAL
		cp $current_config $CONFIG_FILE
		printf '\n- Config: %s is replaced with newer version' "$CONFIG_INTERNAL"
		config_backed=true
	elif [ "$(echo "$last_config_v 0.7" | awk '{print ($1 <= $2) ? 1 : 0}')" -eq 1 ]; then
		cp $CONFIG_INTERNAL $CONFIG_INTERNAL.old
		rename_key .dynamic_swappiness.threshold_psi .dynamic_swappiness.threshold $CONFIG_INTERNAL
		yq ea -i 'select(fileIndex == 0) * select(fileIndex > 0) | sort_keys(.)' $current_config $CONFIG_INTERNAL
		yq -i ".config_version = $current_config_v" $current_config
		cp $current_config $CONFIG_INTERNAL
		cp $CONFIG_INTERNAL $CONFIG_FILE
		printf '\n\n- Config: %s is updated' "$CONFIG_INTERNAL"
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

	[ $config_backed ] && {
		printf '\n! Backup %s.old created\n' "$CONFIG_INTERNAL"
		printf '  Config is located at %s \n' "$CONFIG_INTERNAL"
	}
}

update_tools() {
	if [ -e "$NVBASE/modules/$TAG" ]; then
		MOD_DIR=$NVBASE/modules/$TAG
		cp $MODPATH/action.sh $MOD_DIR
		cp $MODPATH/fmiop.sh $MOD_DIR
		$BIN/cp -rf $MODPATH/tools $MOD_DIR
		cp $MODPATH/module.prop $LOG_FOLDER
		cp $MODPATH/module.prop $NVBASE/modules/$TAG
	fi
}

remove_fogimp() {
	miui_v=$(resetprop ro.miui.ui.version.code)
	vendor_marketname=$(resetprop ro.product.vendor.marketname)
	product_model=$(resetprop ro.product.model)

	if [ $vendor_marketname != "Redmi 10C" ] || [ $product_model != "220333QAG" ] || [ -z $miui_v ]; then
		touch /data/adb/modules/fogimp/remove
		ui_print ""
		ui_print "- Fogimp marked for removal."
		please_reboot=true
	fi
}

check_files_and_folders() {
	required_folders="
		$LOG_FOLDER
		$MODPATH
		$MODPATH/tools
		$MODPATH/system/bin
		/sdcard/Android/fmiop
	"

	required_files="
		$LOG
		$MODPATH/fmiop.sh
		$MODPATH/fmiop_service.sh
		$MODPATH/log_service.sh
		$MODPATH/system/bin/dynv
		$MODPATH/config.yaml
		/sdcard/Android/fmiop/config.yaml
	"

	for folder in $required_folders; do
		if [ ! -d "$folder" ]; then
			uprint "
- Missing folder: $folder"
			return 1
		fi
	done

	for file in $required_files; do
		if [ ! -f "$file" ]; then
			printf "\n- Missing file: %s" "$file"
			return 1
		fi
	done

	return 0
}

install_dynv() {
	if ! is_arm64; then
		mv $MODPATH/system/bin/dynv-armeabi-v7a $MODPATH/system/bin/dynv
		rm $MODPATH/system/bin/dynv-arm64-v8a
	else
		mv $MODPATH/system/bin/dynv-arm64-v8a $MODPATH/system/bin/dynv
		rm $MODPATH/system/bin/dynv-armeabi-v7a
	fi

	set_perm_recursive $MODPATH/system/bin/dynv 0 2000 0755 0755
}

main() {
	local android_version
	android_version=$(getprop ro.build.version.release)

	local unsupported_msg="
- Your Android version is not supported.
  Performance tweaks won't be applied.
  Please upgrade your phone to Android 10+"

	local mem_total=$(free -h | awk '/^Mem:/ {print $2}')
	local mem_info_msg="
- Total memory = $mem_total"

	local zram_msg="
- ZRAM will be set to $mem_total on boot."

	local tweaks_msg="
  Applying LMKD + smoothie🍹tweaks."

	local psi_started_msg="
- LMKD PSI service keeper started"

	local reboot_msg="
- REBOOT now"

	printenv >"$LOG_FOLDER/env.log"

	if ! [ -f "$LOG_FOLDER/.redempted" ]; then
		fix_mistakes
	fi

	kill_all_pids
	set_permissions
	install_dynv
	update_tools

	if [ "$android_version" -lt 10 ]; then
		uprint "$unsupported_msg"
	else
		uprint "$mem_info_msg"
		ui_print "$zram_msg"

		lmkd_apply
		apply_lmkd_tweaks
		echo "$tweaks_msg"
		approps "$MODPATH/system.prop"
		uprint "- LMKD PSI mode activated."
		setup_swap
		update_config

		"$MODPATH/log_service.sh"
		"$MODPATH/fmiop_service.sh"

		kill -0 "$(read_pid fmiop.lmkd_loger.pid)" && uprint "$psi_started_msg"
		relmkd
	fi

	apply_uffd_gc
	remove_fogimp

	[ "$please_reboot" ] && uprint "$reboot_msg"

	check_files_and_folders
}

main
