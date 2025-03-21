# LMKD PSI Activator

Magisk module to fix RAM management by activating PSI mode in LMKD which is more efficient, faster, and more stable than traditional `minfree_levels` most ROMs using.

> ⚠️ **CAUTION**  
> For MIUI users, this module may make your phone more aggressive in killing apps like VPNs. Please install [NoSwipeToKill](https://github.com/dantmnf/NoSwipeToKill) lsposed module by [dantmnf](https://github.com/dantmnf) to prevent this.

## Overview

The LMKD-PSI-Activator is a Magisk module designed to improve RAM management on Android devices by activating PSI mode in LMKD, offering a more efficient, faster, and stable alternative to the traditional `minfree_levels`.

## Features

- **🚀 Multi-ZRAM Support**: Dynamically adjusts multiple ZRAM partitions for improved memory efficiency.
- **📈 Incremental Dynamic Swap**: Swap management adapts progressively based on system load.
- **⚡ Migrated to C++**: Faster execution, lower CPU overhead, and better stability.
- **🔄 Advanced Dynamic Swappiness**: Fine-tuned to respond to system pressure in real time.
- **🛠️ LMKD PSI Optimizations**: Enhanced memory management tweaks for better performance through tested lmkd props.
- **📝 YAML-Based Configuration**: Fully customizable settings via a config file.
- 🌀 **Dynamic ZRAM Management**: Adjusts ZRAM partitions based on system pressure metrics (/proc/pressure/\*).
- 📂 **Swap File Management**: Dynamically manages swap files(/data/adb/fmiop_swap.\*).
- ⚙️ **LMKD Property Tweaks**: Enhances LMKD by tweaks system properties for better memory management.
- ✅ **Pressure Metrics Reporting**: Monitors and reports memory pressure metrics, observable from magisk app.
- 🗃️ **Archiving Logs**: Archives log files periodically to manage storage(Internal/Android/fmiop/archives.

---

## **🔧 Configuration**

- Uses a **YAML configuration file** for flexible tuning.
- Located at:

  ```
  Internal storage → Android/fmiop/config.yaml
  ```

### **config.yaml Example**

```yaml
config_version: 0.5
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
  enable: true
  pressure_binding: false
  zram:
    activation_threshold: 70
    deactivation_threshold: 50
  swap:
    activation_threshold: 90
    deactivation_threshold: 50
```

---

## **📖 Explanation**

### **🌀 Dynamic Swappiness**

- **swappiness_range** – Sets the min/max swappiness levels.
- **threshold** – Adjusts swappiness dynamically based on system pressure:
  - **cpu_pressure** – CPU load threshold.
  - **memory_pressure** – Memory usage threshold.
  - **io_pressure** – I/O operations pressure threshold.
  - **step** – How much swappiness changes per adjustment.

### **🗃️ Virtual Memory**

- **enable** – Enables/disables virtual memory optimizations.
- **pressure_binding** – Only activates ZRAM/swap when pressure crosses a set threshold.
- **zram** – Multi-ZRAM settings:
  - **activation_threshold** – The last partition's ZRAM usage threshold for activation.
  - **deactivation_threshold** – The last partition's ZRAM usage threshold for deactivation.
  - **partitions** – Number of ZRAM partitions enabled.
- **swap** – Incremental swap configuration:
  - **activation_threshold** – System pressure threshold to activate swap.
  - **deactivation_threshold** – System pressure threshold to turn off swap.
  - **incremental** – Gradually increases swap size instead of a fixed allocation.

---

## **📂 Source Code & Contributions**

View the full source code on GitHub:  
🔗 [LMKD-PSI-Activator Repository](https://github.com/lululoid/LMKD-PSI-Activator)

---

## TODO

- [ ] Install the amazing module [NoSwipeToKill](https://github.com/dantmnf/NoSwipeToKill) by [dantmnf](https://github.com/dantmnf) to make this module work as expected on MIUI.
