#!/system/bin/sh
# shellcheck disable=SC3010,SC3060,SC3043,SC2086,SC2046
# Disabled ShellCheck warnings for [[ tests (3010), string trimming (3060),
# local vars (3043), word splitting (2086), and command substitution splitting (2046).

# Purpose: Initializes fmiop memory optimization by setting up ZRAM partitions,
#          waiting for boot completion, and starting fmiop services.
# Note: This script assumes fmiop.sh and related services are in MODDIR.

### Configuration ###
MODDIR=${0%/*}                # Directory of this script
MODPATH="${MODDIR:-$MODPATH}" # Set MODPATH if not defined externally
NVBASE=/data/adb              # Base directory for logs and data
BIN=/system/bin               # Directory for system binaries
LOG_FOLDER="$NVBASE/fmiop"    # Directory for fmiop logs
script_name=$(basename $0)
LOG="$LOG_FOLDER/${script_name%.sh}.log" # Main log file
SINCE_REBOOT=true

### Setup Logging ###
# Redirect stdout and stderr to LOG, keep fd 3 for original stdout
exec 3>&1 1>>"$LOG" 2>&1
set -x # Enable command tracing with PS4 prefix
echo "
⟩ $(date -Is)" >>"$LOG" # Log script start time in ISO format

### System Information ###
# Calculate total memory and ZRAM size (65% of total memory)
TOTALMEM=$("$BIN/free" | awk '/^Mem:/ {print $2}')
CPU_CORES_COUNT=$(grep -c ^processor /proc/cpuinfo) # Count CPU cores
TOTALMEM_GB=$(awk '/MemTotal/ {print int(($2 / 1024 / 1024) + 1)}' /proc/meminfo)
ONE_GB=1073741824

# Export variables for use in sourced scripts (e.g., fmiop_service.sh)
export MODPATH BIN NVBASE LOG_ENABLED LOG_FOLDER LOG CPU_CORES_COUNT TOTALMEM SINCE_REBOOT

### Source fmiop.sh ###
# Load fmiop functions (loger, turnoff_zram, add_zram, etc.)
. "$MODDIR/fmiop.sh"

loger "===REBOOT START FROM HERE==="

### ZRAM Initialization ###
# Disable and remove existing ZRAM partition (zram0)
turnoff_zram /dev/block/zram0
remove_zram 0 && loger "Successfully removed /dev/block/zram0"

### Wait for Boot Completion ###
# Loop until sys.boot_completed is 1, checking every 5 seconds
until [ "$(resetprop sys.boot_completed)" -eq 1 ]; do
	sleep 5
done

$MODPATH/log_service.sh

VIR_E=$(read_config ".virtual_memory.enable" false)

if [ $VIR_E = "false" ]; then
	zram_id=$(add_zram)
	resize_zram "$TOTALMEM" "$zram_id"
fi

available_space=$TOTALMEM
# Create and resize ZRAM partitions based on CPU core count
[ $VIR_E = "true" ] && for _ in $(seq $TOTALMEM_GB); do
	zram_id=$(add_zram)

	# Handle devices which can't make a new zram
	if [ $available_space -gt $ONE_GB ]; then
		resize_zram "$ONE_GB" "$zram_id"
		available_space=$((available_space - ONE_GB))
	else
		resize_zram "$available_space" "$zram_id"
	fi

	if [ -z "$zram_id" ]; then
		remove_zram 0
		add_zram
	fi

	[ $TOTALMEM_GB -gt 20 ] && break
done

# Give time for lmkd to adjust
rm_prop sys.lmk.minfree_levels
sleep 2m

### Start Services ###
$MODPATH/fmiop_service.sh
loger "fmiop started"
loger "fmiop initialization complete; services started"
apply_uffd_gc
