# shellcheck disable=SC3043,SC2034,SC2086,SC3060,SC3010
SKIPUNZIP=1
# exec 3>&1 2>&1
# set -x
totalmem=$(free | awk '/^Mem:/ {print $2}')

unzip -o "$ZIPFILE" -x 'META-INF/*' -d "$MODPATH" >&2
set_perm_recursive "$MODPATH" 0 0 0755 0644

# Setup modules
. "$MODPATH"/modules/lmk.sh

lmkd_apply() {
	# determine if device is lowram?
	log_it "totalmem = $totalmem"
	if [ "$totalmem" -lt 2097152 ]; then
		cat <<EOF
    ⚠️ Device is low ram. Applying low am tweaks"
EOF

		cat <<EOF >$MODPATH/system.prop
ro.config.low_ram=true
ro.lmk.use_psi=true
ro.lmk.use_minfree_levels=false
EOF
	else
		cat <<EOF >$MODPATH/system.prop
ro.config.low_ram=true
ro.lmk.use_psi=true
ro.lmk.use_minfree_levels=false
EOF
	fi

	approps $MODPATH/system.prop

	relmkd
	ui_print "> lmkd multitasking tweak applied."
	ui_print "  Give the better of your RAM."
	ui_print "  RAM better being filled with something"
	ui_print "  useful than left unused"
	rm -rf "$MODPATH/system.props"
}

count_swap() {
	local one_gb=$((1024 * 1024))
	local totalmem_gb=$(((totalmem / 1024 / 1024) + 1))
	count=0
	local swap_in_gb=0
	swap_size=$((totalmem / 2))

	ui_print "> Please select SWAP size"
	ui_print "  Press VOLUME + to DEFAULT"
	ui_print "  Press VOLUME - to SELECT"
	ui_print "  DEFAULT is $((totalmem / 1024 / 2))MB of SWAP"

	while true; do
		# shellcheck disable=SC2069
		timeout 0.5 /system/bin/getevent -lqc 1 2>&1 >"$TMPDIR"/events &
		sleep 0.1
		if (grep -q 'KEY_VOLUMEDOWN *DOWN' "$TMPDIR"/events); then
			if [ $count -eq 0 ]; then
				count=$((count + 1))
				swap_size=$((totalmem / 2))
				swap_in_gb=0
				ui_print "  $count. 50% of RAM ($((swap_size / 1024))MB SWAP) --> RECOMMENDED"
			elif [ $count -eq 2 ]; then
				count=$((count + 1))
				ui_print "  $count. No SWAP"
				swap_size=0
			elif [ $swap_in_gb -lt $totalmem_gb ]; then
				count=$((count + 1))
				swap_in_gb=$((swap_in_gb + 1))
				ui_print "  $count. ${swap_in_gb}GB of SWAP"
				swap_size=$((swap_in_gb * one_gb))
			fi
		elif [ $swap_in_gb -eq $totalmem_gb ] && [ $count != 0 ]; then
			swap_size=$totalmem
			count=0
		elif (grep -q 'KEY_VOLUMEUP *DOWN' "$TMPDIR"/events); then
			break
		fi
	done
}

make_swap() {
	dd if=/dev/zero of="$2" bs=1024 count="$1" >/dev/null
	mkswap -L meZram-swap "$2" >/dev/null
}

config_update() {
	# Updating config
	local LOGDIR=/data/adb/meZram
	local CONFIG=$LOGDIR/meZram-config.json
	local CONFIG_OLD=$LOGDIR/meZram.conf
	local _CONFIG=/sdcard/meZram-config.json
	# shellcheck disable=SC2086,SC2046,SC2155
	local version=$($MODPATH/modules/bin/jq '.config_version' "$MODPATH"/meZram-config.json)
	# shellcheck disable=SC2086,SC2046,SC2155
	local version_prev=$($MODPATH/modules/bin/jq '.config_version' "$CONFIG")
	local loaded=true

	log_it "config version = $version"
	log_it "config version_prev = $version_prev"
	log_it "jq version = $("$MODPATH"/modules/bin/jq --version)"

	if [ -f $CONFIG_OLD ]; then
		mv -f $CONFIG_OLD /sdcard/$CONFIG_OLD.old &&
			ui_print "> Config moved to ${CONFIG_OLD}.old on internal"
	fi

	[ ! -f $CONFIG ] && {
		cp $MODPATH/meZram-config.json $CONFIG
		cp $CONFIG $_CONFIG &&
			ui_print "> Config is in internal root"
	}

	# Update if version is higher than previous version
	[ -n "$version_prev" ] &&
		is_update=$(awk -v version="${version}" \
			-v version_prev="${version_prev}" \
			'BEGIN {
			if (version > version_prev) {
				print "true"
			} else {
				print "false"
			}
		}')

	log_it "is_update = $is_update"

	if [[ "$is_update" = "true" ]]; then
		# Update config version
		ui_print "> Updating configuration"
		ui_print "> Making backup $_CONFIG.bcp"
		today_date=$(date +%R-%a-%d-%m-%Y)
		cp -f $_CONFIG ${_CONFIG}_$today_date.bcp

		# only do this onece for config version 2.0
		"$MODPATH"/modules/bin/jq \
			'{agmode: .agmode, 
        wait_time: .wait_time,
        config_version: .config_version,
        custom_props: .custom_props,
        agmode_per_app_configuration: .agmode_per_app_configuration                                            
          | group_by(.props)  
          | map({
            packages: map(.package),
            props: .[0].props[0],
            wait_time: .[0].wait_time
          })
      }' $CONFIG |
			"$MODPATH"/modules/bin/jq \
				'del(.. | nulls)' >$_CONFIG
		cp -u $_CONFIG $CONFIG

		"$MODPATH"/modules/bin/jq \
			'del(.config_version)' "$CONFIG" |
			/system/bin/awk 'BEGIN{RS="";getline<"-";print>ARGV[1]}' $CONFIG
		# Slurp entire config
		"$MODPATH"/modules/bin/jq \
			-s '.[0] * .[1]' "$MODPATH"/meZram-config.json $CONFIG |
			/system/bin/awk 'BEGIN{RS="";getline<"-";print>ARGV[1]}' $CONFIG &&
			ui_print "> Configuration updated"
		ui_print "  Please reboot"
		cp -f $CONFIG $_CONFIG &&
			ui_print "> Config loaded"
	else
		cp -u $_CONFIG $CONFIG &&
			$loaded ui_print "> Config loaded" && unset loaded
	fi
}

# start installation
swap_filename=/data/swap_file
free_space=$(df /data -P | sed -n '2p' | sed 's/[^0-9 ]*//g' |
	sed ':a;N;$!ba;s/\n/ /g' | awk '{print $3}')
log_it "$(df /data -P | sed -n '2p' | sed 's/[^0-9 ]*//g' |
	sed ':a;N;$!ba;s/\n/ /g')"

# making module directorui_print ""
ui_print " Made with ❤ and 🩸 by "
sleep 0.5
ui_print " █▀▀ █▀▀█ █░░░█ ░▀░ █▀▀▄ ▀▀█ █▀▀ █▀▀█ █▀▀█"
ui_print " █▀▀ █▄▄▀ █▄█▄█ ▀█▀ █░░█ ▄▀░ █▀▀ █▄▄▀ █▄▀█"
ui_print " ▀▀▀ ▀░▀▀ ░▀░▀░ ▀▀▀ ▀░░▀ ▀▀▀ ▀▀▀ ▀░▀▀ █▄▄█"
sleep 0.5

if [ -d "/data/adb/modules/meZram" ]; then
	ui_print "> Thank you so much 😊."
	ui_print "  You've installed this module before"
fi

mkdir -p "$NVBASE/meZram" &&
	ui_print "> Folder $NVBASE/meZram is made"

# setup SWAP
if [ ! -f $swap_filename ]; then
	# Ask user how much SWAP user want
	count_swap
	log_it "free space = $free_space"
	log_it "swap size = $swap_size"
	log_it "count = $count"
	# Making SWAP only if enough free space available
	if [ "$free_space" -ge "$swap_size" ] && [ "$swap_size" != 0 ]; then
		ui_print "> Starting making SWAP. Please wait a moment"
		sleep 0.5
		ui_print "  $((free_space / 1024))MB available. $((swap_size / 1024))MB needed"
		make_swap "$swap_size" $swap_filename &&
			/system/bin/swapon -p 2 $swap_filename
	# Handling bug on some devices
	elif [ -z "$free_space" ]; then
		ui_print "> Make sure you have $((swap_size / 1024))MB space available data partition"
		ui_print "  Make SWAP?"
		ui_print "  Press VOLUME + to NO"
		ui_print "  Press VOLUME - to YES"

		while true; do
			# shellcheck disable=SC2069
			timeout 0.5 /system/bin/getevent -lqc 1 2>&1 >"$TMPDIR"/events &
			sleep 0.1
			if (grep -q 'KEY_VOLUMEDOWN *DOWN' "$TMPDIR"/events); then
				ui_print "> Starting making SWAP. Please wait a moment"
				sleep 0.5
				make_swap $swap_size $swap_filename &&
					/system/bin/swapon -p 5 "$swap_filename" >/dev/null
				ui_print "> SWAP is running"
				break
			elif (grep -q 'KEY_VOLUMEUP *DOWN' "$TMPDIR"/events); then
				cancelled=$(ui_print "> Not making SWAP")
				$cancelled && log_it "$cancelled"
				break
			fi
		done
	# if no SWAP option selected, only pass
	elif [ $count -eq 3 ]; then
		ui_print "> Not making any SWAP. Why bro?"
	else
		ui_print "> Storage full. Please free up your storage"
	fi
fi

android_version=$(getprop ro.build.version.release)
log_it "android_version = $android_version"

if [ $android_version -lt 10 ]; then
	ui_print "> Your android version is not supported. Performance tweaks won't be applied."
	ui_print "  Please upgrade your phone to Android 10+"
else
	lmkd_apply
	config_update
	custom_props_apply &&
		ui_print "> Custom props applied"
fi

ui_print "> Enjoy :)"
ui_print "  Reboot and you're ready"
