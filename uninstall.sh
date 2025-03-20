#!/system/bin/sh
# shellcheck disable=SC3010,SC3060,SC3043,SC2086,SC2046
script_name=$(basename "$0")

until [ "$(resetprop sys.boot_completed)" -eq 1 ] && [ -d /sdcard/Android/fmiop ]; do
	sleep 5
done

exec 3>&1 1>>"/sdcard/fmiop_${script_name%.sh}.log" 2>&1
set -x # Enable debug mode to show commands before execution

# Define target paths correctly
TARGETS="/sdcard/Android/fmiop /data/adb/fmiop*"

# Loop through each path safely
for target in $TARGETS; do
	[ -e "$target" ] && rm -rf "$target" && echo "Deleted: $target" || echo "Not found: $target"
done
