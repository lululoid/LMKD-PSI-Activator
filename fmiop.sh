#!/system/bin/sh
# fmiop.sh - Memory Optimization Script for Android
# Purpose: Enhances memory management by dynamically adjusting ZRAM, swap files, and swappiness
#          based on system pressure metrics, and provides LMKD logging and property tweaks.
# Author: lululoid
# Version: v2.4-beta
# Requirements: Root access

# shellcheck disable=SC3043,SC3060,SC2086,SC2046
# Disabled ShellCheck warnings for local vars (3043), string trimming (3060),
# word splitting (2086), and command substitution splitting (2046).

# Need to set MODPATH, NVBASE and BIN in the environtment to use this script

### Configuration ###
TAG="fmiop"                                       # Unique identifier for the script
LOG_FOLDER="$NVBASE/$TAG"                         # Log directory (NVBASE must be set, e.g., /data/adb)
LOGFILE="$LOG_FOLDER/$TAG.log"                    # Main log file for script activity
PID_DB="$LOG_FOLDER/$TAG.pids"                    # File to store process IDs of background tasks
FOGIMP_PROPS="$NVBASE/modules/fogimp/system.prop" # External properties file for LMKD tweaks
FMIOP_DIR=/sdcard/Android/fmiop
SWAP_FILENAME="$NVBASE/fmiop_swap"
AVAILABLE_SWAPS=$(find $SWAP_FILENAME*)
CONFIG_FILE="$LOG_FOLDER/config.yaml"    # YAML config file for thresholds and settings
CONFIG_INTERNAL="$FMIOP_DIR/config.yaml" # YAML config file for thresholds and settings
FREE_SPACE=$(df /data | sed -n '2p' | sed 's/[^0-9 ]*//g' | sed ':a;N;$!ba;s/\n/ /g' | awk '{print $4}')

# Export variables for use in sourced scripts or subprocesses
export TAG LOGFILE LOG_FOLDER

### Aliases ###
alias resetprop="resetprop -v"
alias sed='$MODPATH/tools/sed' # Custom sed binary (MODPATH must be set)
alias yq='$MODPATH/tools/yq'
alias swapon='/system/bin/swapon'
alias cmd='$MODPATH/tools/cmd'

### Utility Functions ###

# read_config - Reads a value from the YAML config file with a default fallback
# Usage: read_config <key_path> <default_value>
# Example: read_config ".virtual_memory.zram.activation_threshold" "25"
read_config() {
	local key="$1" default="$2" config_file="$CONFIG_FILE"

	value=$(yq e "$key" "$config_file" 2>/dev/null)
	[ "$value" = "null" ] || if [ -z "$value" ]; then
		loger "Can't read value from $CONFIG_FILE"
		value="$default"
	fi

	loger "Read config: $key=$value"
	echo "$value"
}

# loger - Logs messages to LOGFILE with user-friendly formatting
# Usage: loger "message"
loger() {
	local level="$1" # First argument is the log level
	local temp="$1"
	shift
	local message="$*" # Remaining arguments are the message

	case "$level" in
	d | D) pri="d" ;; # DEBUG
	e | E) pri="e" ;; # ERROR
	f | F) pri="f" ;; # FATAL
	i | I) pri="i" ;; # INFO
	v | V) pri="v" ;; # VERBOSE
	w | W) pri="w" ;; # WARN
	s | S) pri="s" ;; # SILENT
	*) pri="i" ;;     # Default to INFO
	esac

	[ -z "$message" ] && message="$temp"
	[ -n "$message" ] && {
		log -p "$pri" -t "fmiop" "$message"
		echo "[$(date '+%d %m | %H:%M:%S:%N') | $pri] - $message" >>"${LOG%.log}_alt.log"
	}
}

# check_file_size - Returns the size of a file in bytes
# Usage: check_file_size <file>
check_file_size() {
	stat -c%s "$1" 2>/dev/null || echo 0
}

# save_pid - Saves a PID to PID_DB with a name
# Usage: save_pid <name> <pid>
save_pid() {
	local pid_name="$1" pid_value="$2"

	sed -i "/^$pid_name=/d" "$PID_DB"
	echo "$pid_name=$pid_value" >>"$PID_DB"
	loger "Saved PID $pid_value for $pid_name"
}

# remove_pid - Removes a PID entry from PID_DB
# Usage: remove_pid <name>
remove_pid() {
	local pid_name="$1"

	sed -i "/^$pid_name=/d" "$PID_DB"
	loger "Removed PID entry for $pid_name"
}

# read_pid - Reads a PID from PID_DB by name
# Usage: read_pid <name>
read_pid() {
	grep "$1" "$PID_DB" | cut -d= -f2
}

# kill_all_pids - Terminates all processes listed in PID_DB
kill_all_pids() {
	local pid_name pid_value

	while IFS= read -r line; do
		pid_name=$(echo "$line" | cut -d= -f1)
		pid_value=$(echo "$line" | cut -d= -f2)

		if [ -n "$pid_value" ]; then
			kill -9 "$pid_value" && loger "Killed $pid_name with PID $pid_value"
			remove_pid "$pid_name"
		fi
	done <"$PID_DB"
	loger "All tracked processes terminated"
}

# lmkd_loger - Logs LMKD activity to a file with rotation
# Usage: lmkd_loger <log_file>
lmkd_loger() {
	local log_file="$1" new_pid old_pid

	loger "Starting LMKD logging to $log_file"
	resetprop ro.lmk.debug true || loger e "Failed to enable LMKD debug mode"
	old_pid=$(read_pid "fmiop.lmkd_loger.pid")

	if [ -n "$old_pid" ]; then
		kill -9 "$old_pid"
		remove_pid "fmiop.lmkd_loger.pid"
		loger "Stopped previous LMKD logger (PID $old_pid)"
	fi

	$BIN/logcat -v time --pid=$(pidof lmkd) -r "$((5 * 1024))" -n 2 --file="$log_file" &

	if [ $? -ne 0 ]; then
		loger e "Failed to start logcat for LMKD"
		return 1
	fi

	new_pid=$!
	save_pid "fmiop.lmkd_loger.pid" "$new_pid"
	loger "LMKD logger started with PID $new_pid"
}

# loger_watcher - Monitors log files and rotates them when they exceed 10MB
# Usage: loger_watcher <log_files>
loger_watcher() {
	logs="$1"
	ten_mb=10485760

	loger "Starting log watcher for files: $logs"

	exec 3>&-
	set +x

	while true; do
		for log in $logs; do
			log_size=$(check_file_size "$log")

			if [ "$log_size" -ge "$ten_mb" ]; then
				exec 3>&1
				set -x

				log_count=$(find "${log%.log}"* | wc -l)

				if [ $SINCE_REBOOT ]; then
					cp "$log" "$log.boot"
					SINCE_REBOOT=false
				else
					for num in $(find $log.* | sed 's/[^0-9]//g' | sort -r); do
						new_num=$((num + 1))
						mv $log.$num $log.$new_num
					done

					cp "$log" "$log.1"
				fi

				: >"$log"
				loger "Rotated $log to $log.1"

				# limit logs to only 3
				while [ $log_count -ge 3 ]; do
					oldest_log=$(ls -tr "${log%.log}"* | head -n 1)
					log_count=$((log_count - 1))

					rm -rf "$oldest_log"
					loger "Removed: $oldest_log. $log_count left."
				done

				exec 3>&-
				set +x
			fi
		done
		sleep 2
	done &

	save_pid "fmiop.lmkd_loger_watcher.pid" "$!"
}

# rm_prop - Deletes specified system properties
# Usage: rm_prop <prop1> <prop2> ...
rm_prop() {
	local prop
	for prop in "$@"; do
		resetprop -d "$prop" && {
			cat <<EOF

  X $prop deleted

EOF
			loger "$prop deleted"
		}
	done
}

# lmkd_props_clean - Removes default LMKD properties to reset configuration
lmkd_props_clean() {
	set --
	set \
		"ro.lmk.low" \
		"ro.lmk.medium" \
		"ro.lmk.critical_upgrade" \
		"ro.lmk.kill_heaviest_task" \
		"ro.lmk.kill_timeout_ms" \
		"ro.lmk.psi_partial_stall_ms" \
		"ro.lmk.psi_complete_stall_ms" \
		"ro.lmk.thrashing_limit_decay" \
		"ro.lmk.swap_util_max" \
		"sys.lmk.minfree_levels" \
		"ro.lmk.upgrade_pressure" \
		"ro.lmk.downgrade_pressure"
	loger "Cleaning default LMKD properties"
	rm_prop "$@"
}

# relmkd - Reinitializes the LMKD daemon
relmkd() {
	resetprop lmkd.reinit 1 && loger "LMKD reinitialized"
}

# approps - Applies properties from a file and verifies them
# Usage: approps <prop_file>
approps() {
	local prop_file="$1" prop value

	set -f
	loger "Applying properties from $prop_file"
	resetprop -f "$prop_file"
	grep -v '^ *#' "$prop_file" | while IFS='=' read -r prop value; do
		cat <<EOF
  › $prop 
EOF
		if [ "$(getprop "$prop")" = "${value//=/ }" ]; then
			uprint "  » $value
"
		else
			uprint "  ! Failed
"
			loger e "Failed to apply $prop=$value"
		fi
	done
}

# turnoff_zram - Disables a ZRAM partition
# Usage: turnoff_zram <zram_device>
turnoff_zram() {
	local zram="$1"

	[ -n "$zram" ] && for _ in $(seq 20); do
		if swapoff "$zram"; then
			loger "ZRAM $zram turned off successfully"
			return 0
		fi
		sleep 1
	done

	loger e "Failed to turn off ZRAM $zram after 20 attempts"
	return 1
}

# add_zram - Adds a new ZRAM partition
add_zram() {
	zram_id=$(cat /sys/class/zram-control/hot_add 2>/dev/null)

	if [ -n "$zram_id" ]; then
		loger "Created new ZRAM partition: zram$zram_id"
		echo "$zram_id"
		return 0
	fi

	loger e "Failed to create new ZRAM partition"
	return 1
}

# remove_zram - Removes a ZRAM partition
# Usage: remove_zram <zram_id>
remove_zram() {
	{
		echo "$1" >/sys/class/zram-control/hot_remove 2>/dev/null && loger "Removed ZRAM partition $1"
	} || loger e "Failed to remove ZRAM $1"
}

# resize_zram - Resizes a ZRAM partition and prepares it for swapping
# Usage: resize_zram <size> <zram_id>
resize_zram() {
	local size="$1" zram_id="$2" zram_block

	if [ -z "$zram_id" ]; then
		loger e "zram_id is not provided. Aborting"
		return 1
	fi

	zram_block="/dev/block/zram$zram_id"

	loger "Resizing ZRAM$zram_id to $size"
	echo 1 >/sys/block/zram${zram_id}/use_dedup 2>/dev/null && loger "Enabled deduplication for ZRAM$zram_id"
	echo "$size" >/sys/block/zram${zram_id}/disksize 2>/dev/null && loger "Set ZRAM$zram_id size to $size"

	for _ in $(seq 5); do
		if mkswap "$zram_block" 2>/dev/null; then
			loger "Initialized swap on ZRAM$zram_id"
			return 0
		fi
		sleep 1
	done

	loger e "Failed: resize zram to $size"
	return 1
}

# get_memory_pressure - Calculates memory pressure as a percentage
get_memory_pressure() {
	local mem_usage=0 swap_usage=0 memsw_usage=1 memory_pressure=0

	if [ -f /dev/memcg/memory.usage_in_bytes ]; then
		mem_usage=$(cat /dev/memcg/memory.usage_in_bytes)
	else
		mem_usage=$(free -b | awk '/^Mem:/ { print $3 }')
	fi

	swap_usage=$(free -b | awk '/^Swap:/ { print $3 }')

	if [ -f /dev/memcg/memory.memsw.usage_in_bytes ]; then
		memsw_usage=$(cat /dev/memcg/memory.memsw.usage_in_bytes)
	else
		memsw_usage=$((mem_usage + swap_usage))
	fi

	if [ "$memsw_usage" -eq 0 ]; then
		memory_pressure=0
	else
		memory_pressure=$(awk -v m="$mem_usage" -v t="$memsw_usage" \
			'BEGIN { print int(m * 100 / t) }')
	fi

	if [ $memory_pressure -le 100 ] || [ $memory_pressure -ge 0 ]; then
		echo "$memory_pressure"
	else
		echo error
	fi
}

# apply_lmkd_props - Applies LMKD properties from files
apply_lmkd_props() {
	loger "Applying LMKD properties from $MODPATH/system.prop and $FOGIMP_PROPS"
	resetprop -f "$MODPATH/system.prop" 2>/dev/null
	resetprop -f "$FOGIMP_PROPS" 2>/dev/null
}

# turnon_zram - Enables a ZRAM partition for swapping
# Usage: turnon_zram <zram_device>
turnon_zram() {
	if $BIN/swapon -p 32767 "$1" 2>/dev/null; then
		loger "ZRAM $1 turned on with priority 32767"
	else
		loger e "Failed to turn on ZRAM $1"
		return 1
	fi
}

# update_pressure_report - Updates the module.prop with current memory pressure
last_memory_pressure=$(get_memory_pressure)

update_pressure_report() {
	local memory_pressure current_swappiness module_prop pressure_emoji swap_status

	memory_pressure=$(get_memory_pressure)
	module_prop="$MODPATH/module.prop"
	current_swappiness=$(cat /proc/sys/vm/swappiness)
	pressure_emoji="🟩"

	if [ "$memory_pressure" -gt 80 ]; then
		pressure_emoji="⚪"
	elif [ "$memory_pressure" -gt 60 ]; then
		pressure_emoji="🟩"
	elif [ "$memory_pressure" -gt 40 ]; then
		pressure_emoji="🟨"
	else
		pressure_emoji="🟥"
	fi

	# Assign emoji based on memory pressure
	if [ $memory_pressure -ge $((last_memory_pressure + 5)) ] ||
		[ $memory_pressure -le $((last_memory_pressure - 5)) ] && [ $memory_pressure != $last_memory_pressure ]; then
		last_memory_pressure=$memory_pressure
		if [ "$memory_pressure" -gt 80 ]; then
			loger i "Sleek! It's (memory_pressure: $pressure_emoji $memory_pressure), got nothing in RAM huh?"
		elif [ "$memory_pressure" -gt 60 ]; then
			loger i "What expected, just normal usage (memory_pressure: $pressure_emoji $memory_pressure)"
		elif [ "$memory_pressure" -gt 40 ]; then
			loger i "I don't like potato (memory_pressure: $pressure_emoji $memory_pressure)"
		else
			loger i "Call for ambulance (memory_pressure: $pressure_emoji $memory_pressure)"
		fi
	fi

	# Check if swap is active
	if [ "$(wc -l </proc/swaps)" -gt 1 ]; then
		swap_status="✅ Running"
	else
		swap_status="❌ Not Running"
	fi

	# Use sed to replace the values correctly
	sed -i -E \
		-e "s/(Memory pressure[^:]*: )[^,]+,/\1$pressure_emoji$memory_pressure,/" \
		-e "s/(swappiness[^:]*: )[^,]+,/\1$current_swappiness,/" \
		-e "s/(Swap Status[^:]*: )[^.]+/\1$swap_status/" "$module_prop"
}

pressure_reporter_service() {
	set +x
	exec 3>&-

	while true; do
		update_pressure_report
		sleep 1
	done &
	new_pid=$!
	save_pid "pressure_reporter" "$new_pid"
	loger "pressure reporter PID $new_pid"
}

# archive_service - Starts a background service to archive files every 5 minutes
# Usage: archive_service
# Archives: Files in /data/adb/fmiop/* and /sdcard/Android/fmiop/* into tar.gz
archive_service() {
	local archive_dir="$FMIOP_DIR/archives"                   # Directory for archives
	local source_dirs="/data/adb/fmiop /sdcard/Android/fmiop" # Directories to archive
	local interval=300                                        # 5 minutes in seconds
	local max_archives=5                                      # Maximum number of archives to keep
	local timestamp archive_file
	local last_dir
	last_dir=$(pwd)

	# Ensure archive directory exists
	mkdir -p "$archive_dir" || {
		loger e "Failed to create archive directory $archive_dir"
	}
	loger "Starting archive service for $source_dirs"
	exec 3>&-
	set +x

	# Background loop to archive files
	while true; do
		# Generate timestamp for unique archive name
		timestamp=$(date +%Y%m%d_%H%M%S)
		archive_file="$archive_dir/fmiop_archive_$timestamp.tar.gz"

		# Archive files from both directories
		tmp_dir=/data/local/tmp/fmiop
		mkdir -p $tmp_dir

		cp -r /data/adb/fmiop/* "$tmp_dir/"
		cp /sdcard/Android/fmiop/config.yaml "$tmp_dir/"

		cd $last_dir || cd $MODPATH || {
			loger "Failed to open $tmp_dir"
			return
		}
		tar -czf "$archive_file" "$tmp_dir" || loger "Log archiving failed."
		if [ $(check_file_size $archive_file) -eq 0 ]; then
			loger "Log archiving failed. Size is 0."
		fi
		rm -rf "$tmp_dir"

		# Check and limit the number of archives to max_archives (5)
		local archive_count
		archive_count=$(find "$archive_dir/fmiop_archive_"*.tar.gz 2>/dev/null | wc -l)
		if [ "$archive_count" -gt "$max_archives" ]; then
			exec 3>&1
			set -x

			# Remove the oldest archives until only 5 remain
			local excess=$((archive_count - max_archives))
			ls -t "$archive_dir/fmiop_archive_"*.tar.gz | tail -n "$excess" | while read -r old_archive; do
				rm -f "$old_archive"

				exec 3>&-
				set +x
			done
		fi

		# Wait 5 minutes
		sleep "$interval"
	done &

	# Save PID of the background service
	local pid=$!
	save_pid "fmiop.archive_service.pid" "$pid"
	loger "Archive service started with PID $pid, running every $((interval / 60)) minutes, limiting to $max_archives archives"
}

# Function to get key events
get_key_event() {
	local event_type="$1"
	local event_file="$TMPDIR/events"

	if [ -n "$capture_pid" ] && ! kill -0 $capture_pid; then
		unset capture_pid
	elif [ -z "$capture_pid" ]; then
		: >"$event_file"
		getevent -lq >$event_file &
		capture_pid=$!
	fi

	result=$(tail -n2 "$event_file" | grep "$event_type")
	until tail -n2 "$event_file" | awk '/UP/ { print $4 }' >/dev/null; do
		break
	done

	[ -n "$result" ] && sleep 0.25 && return 0 || return 1
}

# Function to handle SWAP size logic
handle_swap_size() {
	if [ $count -eq 0 ]; then
		swap_size=0
		swap_in_gb=0
		uprint "  $count. 0 SWAP --⟩ RECOMMENDED"
		count=$((count + 1))
	elif [ $swap_in_gb -lt $totalmem_gb ]; then
		swap_in_gb=$((swap_in_gb + 1))
		uprint "  $count. ${swap_in_gb}GB of SWAP"
		swap_size=$((swap_in_gb * one_gb))
		count=$((count + 1))
	elif [ $swap_in_gb -ge $totalmem_gb ]; then
		swap_size=$totalmem
		count=0
		swap_in_gb=0
	fi
}

# Main loop to handle user input and adjust SWAP size
setup_swap_size() {
	local one_gb totalmem_gb count swap_in_gb totalmem
	totalmem=$(free | awk '/^Mem:/ {print $2}')
	one_gb=$((1024 * 1024))
	totalmem_gb=$(((totalmem / 1024 / 1024) + 1))
	count=0
	swap_in_gb=0
	quarter_gb=$((one_gb / 4))
	swap_size=0

	exec 3>&-
	set +x

	uprint "
⟩ Please select SWAP size 
  Press VOLUME + to use DEFAULT
  Press VOLUME - to SELECT 
  DEFAULT is 0 SWAP"

	while true; do
		if get_key_event 'KEY_VOLUMEDOWN *DOWN'; then
			exec 3>&1
			set -x
			handle_swap_size
			exec 3>&-
			set +x
		elif get_key_event 'KEY_VOLUMEUP *DOWN'; then
			break
		fi
	done
	kill -9 $capture_pid
}

make_swap() {
	dd if=/dev/zero of="$2" bs=1024 count="$1" >/dev/null
	mkswap -L fmiop_swap "$2" >/dev/null
	chmod 0600 "$2"
	uprint "  › Swap: $2, size: $(($1 / 1024))MB is made"
}

start_services() {
	loger "===Main service started from here==="
	pressure_reporter_service
	su -c $MODPATH/system/bin/dynv &
	loger "Started dyn_swap_service with PID $!"
}

kill_dynv() {
	pid=$(read_pid dyn_swap_service)
	kill -9 $pid && loger "Killed $id with PID $pid"
}

kill_services() {
	services_target="dyn_swap_service pressure_reporter"
	for id in $services_target; do
		pid=$(read_pid $id)
		kill -9 $pid && loger "Killed $id with PID $pid"
	done
}

magisk_ge() {
	local version
	version=$(magisk -v 2>/dev/null | awk -F ':' '{print $1}')
	if [ -z "$version" ]; then
		loger "❌ Failed to get Magisk version"
		uprint "
❌ Failed to get Magisk version"
		return 1
	fi

	awk -v v="$version" -v n="$1" 'BEGIN {
    split(v, ver, ".");
    major = ver[1];
    minor = (ver[2] == "") ? 0 : ver[2];
    if (major > n || major == n ||(minor > 0)) {
      exit 0;  # true
    } else {
      exit 1;  # false
    }
  }'
}

setup_swap() {
	local free_space swap_size available_swaps
	free_space=$FREE_SPACE

	if ! echo "$free_space" | grep -qE '^[0-9]+$' || [ -z "$free_space" ]; then
		uprint "- Error: Failed to retrieve valid free space information."
		uprint "- Skipping free space check, make sure you have enough space available."
		fuck_free_space=true
	fi

	available_swaps=$AVAILABLE_SWAPS

	if [ -z "$available_swaps" ]; then
		# No existing swap files, need to create swap
		setup_swap_size

		if [ "$free_space" -ge "$swap_size" ] && [ "$swap_size" -gt 0 ] || [ $fuck_free_space ]; then
			[ ! $fuck_free_space ] &&
				uprint "
- Starting making SWAP. Please wait a moment...
  $((free_space / 1024))MB available. $((swap_size / 1024))MB needed"

			swap_count=$((swap_size / quarter_gb))

			for num in $(seq $swap_count); do
				if ! make_swap "$quarter_gb" "$SWAP_FILENAME.$num"; then
					uprint "Error: Failed to create swap file $SWAP_FILENAME.$num"
					return 1
				fi
			done

			uprint "  › SWAP creation is done."
			return 0
		elif [ $swap_size -eq 0 ]; then
			:
		else
			uprint "
- Storage full. Please free up your storage."
		fi
	else
		if magisk_ge "28.0"; then
			uprint "
- SWAP already exists. Press action button
  in your root manager app to remake the SWAP."
		else
			uprint "
- SWAP already exists."
		fi
	fi

	return 1
}

apply_uffd_gc() {
	uprint " 
- Apllying UFFD GC tweak
  What are these GCs (garbage collection)? Basically, they are Garbage
  Collectors focused on freeing up memory pages. The focus of these GCs
  is to minimize page faults and leave the memory clean enough to generate
  benefits such as ZRAM compression, preventing it from being overused and
  generating a much more efficient ZRAM by having cleaner memory to compress.

  Thanks to @WeirdMidas in github issue for suggestion
  -> (https://github.com/lululoid/LMKD-PSI-Activator/issues/17)
	"

	resetprop ro.dalvik.vm.enable_uffd_gc true && {
		uprint "  › UFFD GC V1 is activated." || loger "UFFD GC V1 is activated."
	}

	limit=60
	until cmd device_config put runtime_native_boot enable_uffd_gc_2 true && {
		uprint "  › UFFD GC V2 is activated." || loger "UFFD GC V2 is activated."
	}; do
		limit=$((limit - 1))
		[ $limit -eq 0 ] && loger e "Waiting for $limit seconds, failed to apply UFFD GC 2" && break
		sleep 1
	done &
}
