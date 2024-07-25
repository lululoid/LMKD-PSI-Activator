# shellcheck disable=SC3043,SC2034,SC2086,SC3060,SC3010
# save full loging
exec 3>&1 1>>$NVBASE/fmiop.log 2>&1
# restore stdout for magisk
exec 1>&3
set -x
echo "
⟩ $(date -Is)" >>$NVBASE/fmiop.log

SKIPUNZIP=1
BIN=/system/bin

export MODPATH BIN NVBASE LOG_ENABLED

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
}

lmkd_apply() {
	# determine if device is lowram?
	cat <<EOF

⟩ Totalmem = $(free -h | awk '/^Mem:/ {print $2}')
EOF

	if [ "$totalmem" -lt 2097152 ]; then
		uprint "
	! Device is low ram. Applying low ram tweaks"

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
  Give the better of your RAM, RAM is better being 
  filled with something useful than left unused"
}

count_swap() {
	local one_gb=$((1024 * 1024))
	local totalmem_gb=$(((totalmem / 1024 / 1024) + 1))
	local count=0
	local swap_in_gb=0
	swap_size=0

	uprint "
⟩ Please select SWAP size 
  Press VOLUME + to DEFAULT
  Press VOLUME - to SELECT 
  DEFAULT is 0 SWAP"

	set +x
	exec 3>&-

	while true; do
		# shellcheck disable=SC2069
		timeout 0.5 /system/bin/getevent -lqc 1 2>&1 >"$TMPDIR"/events &
		sleep 0.5
		if (grep -q 'KEY_VOLUMEDOWN *DOWN' "$TMPDIR"/events); then
			if [ $count -eq 0 ]; then
				swap_size=0
				swap_in_gb=0
				ui_print "  $count. 0 SWAP --⟩ RECOMMENDED"
			elif [ $swap_in_gb -lt $totalmem_gb ]; then
				swap_in_gb=$((swap_in_gb + 1))
				ui_print "  $count. ${swap_in_gb}GB of SWAP"
				swap_size=$((swap_in_gb * one_gb))
			fi

			count=$((count + 1))
		elif [ $swap_in_gb -eq $totalmem_gb ] && [ $count != 0 ]; then
			swap_size=$totalmem
			count=0
		elif (grep -q 'KEY_VOLUMEUP *DOWN' "$TMPDIR"/events); then
			break
		fi
	done

	set -x
	exec 3>&1
}

make_swap() {
	dd if=/dev/zero of="$2" bs=1024 count="$1" >/dev/null
	mkswap -L fmiop_swap "$2" >/dev/null
}

setup_swap() {
	local swap_filename free_space
	swap_filename=$NVBASE/fmiop_swap
	free_space=$(df /data | sed -n '2p' | sed 's/[^0-9 ]*//g' | sed ':a;N;$!ba;s/\n/ /g' | awk '{print $4}')

	if [ ! -f $swap_filename ]; then
		count_swap
		if [ "$free_space" -ge "$swap_size" ] && [ "$swap_size" != 0 ]; then
			uprint "
⟩ Starting making SWAP. Please wait a moment
  $((free_space / 1024))MB available. $((swap_size / 1024))MB needed"
			make_swap "$swap_size" $swap_filename &&
				swapon $swap_filename
		elif [ $swap_size -eq 0 ]; then
			:
		else
			ui_print "
⟩ Storage full. Please free up your storage"
		fi
	fi
}

main() {
	android_version=$(getprop ro.build.version.release)
	if [ $android_version -lt 10 ]; then
		uprint "
⟩ Your android version is not supported. Performance
tweaks won't be applied. Please upgrade your phone 
to Android 10+"
	else
		miui_v_code=$(resetprop ro.miui.ui.version.code)

		if [ -n "$miui_v_code" ]; then
			# Add workaround for miui touch issue when lmkd is in psi mode
			# because despite it's beauty miui is having weird issues
			cat <<EOF >>$MODPATH/system.prop
ro.lmk.downgrade_pressure=55
ro.lmk.upgrade_pressure=50
EOF
			lmkd_apply
			# Add workaround to keep miui from readd sys.lmk.minfree_levels
			# prop back
			$MODPATH/fmiop_service.sh
			kill -0 "$(resetprop fmiop.pid)" &&
				uprint "
⟩ LMKD psi service keeper started"
		else
			lmkd_apply
		fi
	fi
}

set_permissions
setup_swap
main
