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
LOG="$LOG_FOLDER/fmiop.log"   # Main log file

### Setup Logging ###
# Redirect stdout and stderr to LOG, keep fd 3 for original stdout
exec 3>&1 1>>"$LOG" 2>&1
set -x # Enable command tracing with PS4 prefix
echo "
⟩ $(date -Is)" >>"$LOG" # Log script start time in ISO format

### System Information ###
# Calculate total memory and ZRAM size (65% of total memory)
TOTALMEM=$("$BIN/free" | awk '/^Mem:/ {print $2}')
zram_size=$(awk -v size="$TOTALMEM" \
	'BEGIN { printf "%.0f\n", size * 0.65 }')
CPU_CORES_COUNT=$(grep -c ^processor /proc/cpuinfo) # Count CPU cores

# Export variables for use in sourced scripts (e.g., fmiop_service.sh)
export MODPATH BIN NVBASE LOG_ENABLED LOG_FOLDER LOG CPU_CORES_COUNT TOTALMEM

### Source fmiop.sh ###
# Load fmiop functions (loger, turnoff_zram, add_zram, etc.)
. "$MODDIR/fmiop.sh"

### ZRAM Initialization ###
# Disable and remove existing ZRAM partition (zram0)
turnoff_zram /dev/block/zram0
remove_zram 0 && loger "Successfully removed /dev/block/zram0"

# Create and resize ZRAM partitions based on CPU core count
for _ in $(seq "$CPU_CORES_COUNT"); do
	zram_id=$(add_zram)
	resize_zram "$((TOTALMEM / CPU_CORES_COUNT))" "$zram_id"
done

### Wait for Boot Completion ###
# Loop until sys.boot_completed is 1, checking every 5 seconds
until [ "$(resetprop sys.boot_completed)" -eq 1 ]; do
	sleep 5
done

### Start Services ###
$MODPATH/log_service.sh
$MODPATH/fmiop_service.sh
loger "fmiop started"
loger "fmiop initialization complete; services started"
