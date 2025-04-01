# **LMKD PSI Activator** 🚀💾

**A Magisk module to supercharge RAM management** by activating **PSI mode in LMKD**, offering a **faster, more stable, and more efficient** alternative to outdated `minfree_levels`-based memory management.

---

> ⚠️ **CAUTION – MIUI USERS**  
> This module may cause MIUI to aggressively kill apps like **VPNs**.  
> **Fix:** Install the [NoSwipeToKill](https://github.com/dantmnf/NoSwipeToKill) LSPosed module by [dantmnf](https://github.com/dantmnf).

---

## **✨ Features**

- **🗑️ UFFD Garbage Collection** – Activates **Userfaultfd (UFFD) garbage collection**, optimizing memory management and reducing swap-related overhead.
- **🔄 ZRAM Deduplication** – Enables **data deduplication in ZRAM** (if supported by kernel). **Deduplicate** ZRAM data to reduce amount of memory consumption.
- **🚀 Multi-ZRAM Support** – Dynamically manages **multiple ZRAM partitions** for better memory management.
- **📂 Swap Creation & Removal** – Manage swap **on demand** via `action.sh` (max swap = RAM size).
- 📈 **Incremental Dynamic Swap** – Implements adaptive swap expansion, progressively adjusting swap size based on real-time system memory pressure.
- ⚡ **Migrated to C++** – Rewritten in C++ for faster execution, lower CPU utilization, and improved overall system stability compared to older implementations.
- **🔄 Advanced Dynamic Swappiness** – Adjusts `swappiness` **in real-time** depending on memory pressure, ensuring an optimal balance between performance and responsiveness.
- **🛠️ LMKD PSI Optimizations** – Fine-tuned **Low Memory Killer Daemon (LMKD) PSI parameters**, improving low-memory handling and responsiveness based on real-world testing.
- **📝 YAML-Based Configuration** – **Customizable** settings via `config.yaml`.
- **📊 Memory Pressure Monitoring** – **Reports live RAM pressure** through Magisk.

---

## **🔧 Configuration**

- Uses a **YAML config file** for flexible tuning.
- Located at:

  ```
  Internal storage → Android/fmiop/config.yaml
  ```

### **📜 Example config.yaml**

```yaml
config_version: 0.6
dynamic_swappiness:
  swappiness_range:
    max: 100
    min: 80
  threshold:
    cpu_pressure: 40
    memory_pressure: 15
    io_pressure: 30
  step: 2
  apply_step: 20
virtual_memory:
  enable: true
  pressure_binding: false
  deactivate_in_sleep: true
  wait_timeout: 10
  zram:
    activation_threshold: 75
    deactivation_threshold: 55
  swap:
    activation_threshold: 90
    deactivation_threshold: 40
```

---

## **📖 Explanation of Key Settings**

### **🌀 Dynamic Swappiness**

- **swappiness_range** – Controls swap aggressiveness:
  - **Low (e.g., 60)** – Favors RAM, keeps apps in memory.
  - **High (e.g., 100)** – Frees RAM quickly, better for multitasking.
- **threshold** – Adjusts swappiness based on system pressure:
  - **cpu_pressure** – CPU load threshold.
  - **memory_pressure** – Memory usage threshold.
  - **io_pressure** – I/O operations threshold.
- **step** – Swappiness **increment per adjustment** (higher = more aggressive).
- **apply_step** – how many step to when to adjust swappiness.
  Too often swappiness update affect performance.

### **🗃️ Virtual Memory (VM) Optimization**

- **enable** – Enables VM optimizations (**recommended** for multitasking).
- **pressure_binding** – Enables swap **only when system pressure is high** (**EXPERIMENTAL**).
- **deactivate_in_sleep** – Only deactivate in sleep to be more **battery** friendly.
- **zram** – Handles **incremental ZRAM management**:
  - **activation_threshold** – **% usage of last ZRAM partition** before a new one is activated.
  - **deactivation_threshold** – **MB size** where ZRAM is released.
- **swap** – Handles **incremental swap management**:
  - **activation_threshold** – **% system pressure** before swap is enabled.
  - **deactivation_threshold** – **MB size** where swap is released.

---

## **📂 Source Code & Contributions**

💻 **View full source code & contribute:**  
🔗 [**LMKD-PSI-Activator Repository**](https://github.com/lululoid/LMKD-PSI-Activator)

---

## **🛠️ TODO**

- [ ] **MIUI Fix** – Install [NoSwipeToKill](https://github.com/dantmnf/NoSwipeToKill) by [dantmnf](https://github.com/dantmnf) for better compatibility.

---

### **🚀 TL;DR – What This Module Does:**

✔️ **Boosts RAM performance** 🔥  
✔️ **Smarter ZRAM & swap handling** 📈  
✔️ **Dynamic memory tuning** 🧠  
✔️ **C++ powered speed & efficiency** ⚡

This **isn't just a tweak**—it’s a **real optimization for smoother performance**! 🏎️💨
