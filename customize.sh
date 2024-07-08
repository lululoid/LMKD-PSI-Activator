# shellcheck disable=SC3043,SC2034,SC2086,SC3060,SC3010
SKIPUNZIP=1
# exec 3>&1 2>&1
# set -x

totalmem=$(free | awk '/^Mem:/ {print $2}')

LOG_ENABLED=true
BIN=/system/bin

export MODPATH BIN NVBASE LOG_ENABLED

unzip -o "$ZIPFILE" -x 'META-INF/*' -d "$MODPATH" >&2
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm_recursive "$MODPATH/sed" 0 2000 0755 0755
set_perm_recursive "$MODPATH/fmiop.sh" 0 2000 0755 0755
set_perm_recursive "$MODPATH/fmiop_service.sh" 0 2000 0755 0755

. $MODPATH/fmiop.sh

echo "> $(date -Is)" >>$LOGFILE

lmkd_apply() {
  # determine if device is lowram?
  cat <<EOF

> Totalmem = $(free -h | awk '/^Mem:/ {print $2}')
EOF

  if [ "$totalmem" -lt 2097152 ]; then
    cat <<EOF
  ! Device is low ram. Applying low ram tweaks
EOF

    echo "ro.config.low_ram=true
ro.lmk.use_psi=true
ro.lmk.debug=true
ro.lmk.use_minfree_levels=false" >$MODPATH/system.prop
  else
    echo "ro.config.low_ram=false
ro.lmk.use_psi=true
ro.lmk.debug=true
ro.lmk.use_minfree_levels=false" >$MODPATH/system.prop
  fi

  rm_prop sys.lmk.minfree_levels
  approps $MODPATH/system.prop
  relmkd
  cat <<EOF

> LMKD PSI mode activated
  Give the better of your RAM, RAM is better being 
  filled with something useful than left unused
EOF
}

count_swap() {
  local one_gb=$((1024 * 1024))
  local totalmem_gb=$(((totalmem / 1024 / 1024) + 1))
  local count=0
  local swap_in_gb=0
  swap_size=0

  cat <<EOF
> Please select SWAP size 
  Press VOLUME + to DEFAULT
  Press VOLUME - to SELECT 
  DEFAULT is 0 SWAP
EOF

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
        ui_print "  $count. 0 SWAP --> RECOMMENDED"
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

  # set -x
  # exec 3>&1
}

make_swap() {
  dd if=/dev/zero of="$2" bs=1024 count="$1" >/dev/null
  mkswap -L fmiop_swap "$2" >/dev/null
}

swap_filename=$NVBASE/fmiop_swap
free_space=$(df /data -P | sed -n '2p' | sed 's/[^0-9 ]*//g' | sed ':a;N;$!ba;s/\n/ /g' | awk '{print $3}')

# setup SWAP
if [ ! -f $swap_filename ]; then
  count_swap
  if [ "$free_space" -ge "$swap_size" ] && [ "$swap_size" != 0 ]; then
    cat <<EOF

> Starting making SWAP. Please wait a moment
  $((free_space / 1024))MB available. $((swap_size / 1024))MB needed
EOF
    make_swap "$swap_size" $swap_filename &&
      /system/bin/swapon $swap_filename
    # Handling bug on some devices
  elif [ $swap_size -eq 0 ]; then
    :
  elif [ -z "$free_space" ]; then
    ui_print "> Make sure you have $((swap_size / 1024))MB space available data partition"
    ui_print "  Make SWAP?"
    ui_print "  Press VOLUME + to NO"
    ui_print "  Press VOLUME - to YES"

    while true; do
      # shellcheck disable=SC2069
      timeout 0.5 /system/bin/getevent -lqc 1 2>&1 >"$TMPDIR"/events &
      sleep 0.5
      if (grep -q 'KEY_VOLUMEDOWN *DOWN' "$TMPDIR"/events); then
        ui_print "> Starting making SWAP. Please wait a moment"
        sleep 0.5
        make_swap $swap_size $swap_filename &&
          /system/bin/swapon -p 5 "$swap_filename" >/dev/null
        ui_print "> SWAP is running"
        break
      elif (grep -q 'KEY_VOLUMEUP *DOWN' "$TMPDIR"/events); then
        cancelled=$(ui_print "> Not making SWAP")
        $cancelled && cat <<EOF

> $cancelled"
EOF
        break
      fi
    done
  else
    ui_print "
> Storage full. Please free up your storage"
  fi
fi

if [ $android_version -lt 10 ]; then
  cat <<EOF

> Your android version is not supported. Performance
tweaks won't be applied. Please upgrade your phone 
to Android 10+
EOF
else
  lmkd_apply

  miui_v_code=$(resetprop ro.miui.ui.version.code)
  if [ -n "$miui_v_code" ]; then
    $MODPATH/fmiop_service.sh
    kill -0 $(resetprop fmiop.pid) &&
      cat <<EOF

> LMKD psi service keeper started
EOF
  else
    rm_prop sys.lmk.minfree_levels
    relmkd
  fi
fi
