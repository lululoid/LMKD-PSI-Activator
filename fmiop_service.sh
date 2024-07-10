#!/system/bin/sh
# shellcheck disable=SC3043,SC2034,SC2086,SC3060,SC3010,SC2046

exec 3>&1 1>>"$NVBASE/fmiop.log" 2>&1
set -x # Prints commands, prefixing them with a character stored in an environmental variable ($PS4)

. $MODPATH/fmiop.sh

kill $(resetprop fmiop.pid)
fmiop
