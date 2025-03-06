# LMKD PSI Activator

Magisk module to fix RAM management by activating PSI mode in LMKD which is more efficient, faster, and more stable than traditional `minfree_levels` most ROMs using.

> ⚠️ **CAUTION**  
> For MIUI users, this module may make your phone more aggressive in killing apps like VPNs. Please install [NoSwipeToKill](https://github.com/dantmnf/NoSwipeToKill) lsposed module by [dantmnf](https://github.com/dantmnf) to prevent this.

## TODO

- [ ] Install the amazing module [NoSwipeToKill](https://github.com/dantmnf/NoSwipeToKill) by [dantmnf](https://github.com/dantmnf) to make this module work as expected on MIUI.

## Overview

The LMKD-PSI-Activator is a Magisk module designed to improve RAM management on Android devices by activating PSI mode in LMKD, offering a more efficient, faster, and stable alternative to the traditional `minfree_levels`.

## Features

- 🌀 **Dynamic ZRAM Management**: Adjusts ZRAM partitions based on system pressure metrics (/proc/pressure/\*).
- 📂 **Swap File Management**: Dynamically manages swap files(/data/adb/fmiop_swap.\*).
- 🔄 **Dynamic Swappiness Adjustment**: Adjusts the system's swappiness based on usage metrics.
- 📝 **LMKD Property Tweaks**: Enhances LMKD by tweaks system properties for better memory management.
- 📈 **Pressure Metrics Reporting**: Monitors and reports memory pressure metrics, observable from magisk app.
- 🗃️ **Archiving Logs**: Archives log files periodically to manage storage(Internal/Android/fmiop/archives.

## Configuration

- Uses a YAML configuration file for thresholds and settings. Located in internal storage at Android/fmiop/config.yaml

### config.yaml Example

```yaml
config_version: 0.3
dynamic_swappiness:
  swappiness_range:
    max: 100
    min: 60
  threshold:
    cpu_pressure: 40
    memory_pressure: 15
    io_pressure: 30
    step: 2
virtual_memory:
  pressure_binding: false
  zram:
    activation_threshold: 70
    deactivation_threshold: 10
  swap:
    activation_threshold: 90
    deactivation_threshold: 25
```

### Explanation

- dynamic_swappiness: This section handles dynamic adjustment of the swappiness value. - swappiness_range: Defines the upper (max) and lower (min) limits for swappiness.
  - threshold: Specifies the pressure thresholds to adjust swappiness.
    - cpu_pressure: CPU pressure threshold.
    - memory_pressure: Memory pressure threshold.
    - io_pressure: I/O pressure threshold.
    - step: The increment step for adjusting swappiness.
- virtual_memory: Settings related to virtual memory management.
  - pressure_binding: only turn on virtual memory when threshold reached. Default to false.
  - zram: Settings for ZRAM (compressed RAM).
    - activation_threshold: Activation threshold of last ZRAM percentage. Priority adjusted dynamically to prevent conflict between partitions.
    - deactivation_threshold: Deactivation threshold of last ZRAM percentage.
  - swap: Settings for swap memory.
    - activation_threshold: Activation threshold percentage.
    - deactivation_threshold: Deactivation threshold percentage.

For more details, view the [script source code](https://github.com/lululoid/LMKD-PSI-Activator/blob/main).
