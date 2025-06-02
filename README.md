# **LMKD PSI Activator** 🚀💾

**A Magisk module to supercharge RAM management** by activating **PSI mode in LMKD**, offering a **faster, more stable, and more efficient** alternative to outdated `minfree_levels`-based memory management.

---

> [!CAUTION]
> **MIUI USER**. This module may cause MIUI to aggressively kill apps like **VPNs**.  
> **Fix:** Install the [NoSwipeToKill](https://github.com/dantmnf/NoSwipeToKill) LSPosed module by [dantmnf](https://github.com/dantmnf).

---

>[!NOTE]
>I use SWAP and ZRAM term interchangeably in this module.

---

## **✨ Features**

### **🧬 Kernel Support Required**

- **🗑️ UFFD Garbage Collection** – Activates **Userfaultfd (UFFD) garbage collection**, optimizing memory management and reducing swap-related overhead.
- **🔄 ZRAM Deduplication** – Enables **data deduplication in ZRAM** (if supported by kernel). **Deduplicate** ZRAM data to reduce amount of memory consumption.

###

- **🚀 Multi-ZRAM Support** – Dynamically manages **multiple ZRAM partitions** for better memory management.
- **📂 Swap Creation & Removal** – Manage swap **on demand** via `action.sh` (max swap = RAM size).
- 📈 **Incremental Dynamic Swap** – Expands swap space progressively based on real-time system pressure.
- ⚡ **Migrated to C++** – Rewritten in C++ for faster execution, lower CPU utilization, and improved overall system stability compared to older implementations.
- **🔄 Advanced Dynamic Swappiness** – Adjusts `swappiness` **in real-time** depending on memory pressure, ensuring an optimal balance between performance and multitask.
- **🛠️ LMKD PSI Optimizations** – Fine-tuned **Low Memory Killer Daemon (LMKD) PSI parameters**, improving low-memory handling and responsiveness based on real-world testing.
- **📝 YAML-Based Configuration** – **Customizable** settings via `config.yaml`.
- **📊 Memory Pressure Monitoring** – **Reports live RAM pressure** through Magisk.

---

## **🔧 Configuration**

- Configurable via a **YAML file**:

  ```markdown
  Internal storage → Android/fmiop/config.yaml
  ```

### **📜 Example config.yaml**

```yaml
config_version: 1.4
dynamic_swappiness:
  enable: true # Wether to enable dynamic swappiness or not
  threshold_type: "psi" # "psi" or "legacy".
  swappiness_range:
    max: 140
    min: 40
  threshold_psi:
    mode: "auto" # "auto" or "manual"
    # Max and min sparsed into [40 57 73 90 107 123 140] for 6 levels
    # 6 levels would be [40 57 73 90 107 123 140]
    levels: 6
    # Each of auto settings below control swappiness sensitivity
    # higher range from min to max means less sensitive, careful low range could lead to oscilations
    # which could lead to system instability
    auto_cpu:
      max: 80
      min: 0
      time_window: "avg60" # Choose between: avg10, avg60, avg300. Smaller means more sensitive
    auto_memory:
      max: 20
      min: 0
      time_window: "avg60"
    auto_io:
      max: 25
      min: 0
      time_window: "avg60"
    # Pairs of pressure values and their corresponding swappiness values
    # Choose the highest value any pressure reached
    # Default to if higher pressure then lower swappiness
    cpu_pressure: [[5, 120], [10, 100], [20, 80], [60, 60], [100, 40]]
    memory_pressure: [[5, 120], [10, 100], [15, 90], [20, 60], [25, 40]]
    io_pressure: [[10, 120], [15, 100], [25, 60], [30, 40]]
  # Percentage of memory usage to activate swappiness
  # Lower memory pressure values means higher memory pressure
  # which is confusing, ask google why.
  threshold_mem_pressure: [[60, 80], [50, 60], [40, 40]]
virtual_memory:
  enable: true # Wether to enable dynamic zram or not
  pressure_binding: false # True means only activate zram when pressure is high
  # Wether to deactivate zram when system is in sleep or immediately
  deactivate_in_sleep: true
  wait_timeout: 600 # Time in seconds to wait before deactivating zram, default to 10 minutes.
  zram:
    # Percentage of ZRAM usage to activate next zram
    activation_threshold: 80
    # Minimum size in MB of used swap to deactivate zram
    deactivation_threshold: 55
  swap:
    activation_threshold: 90
    deactivation_threshold: 40
```

---

## **📖 Explanation of Key Settings**

### **🧠 What You Wanna Use**

- **swappiness_range**: To control multitasking performance, also performance during high pressure. Low min will kill more apps which should improve performance. Lower min → more aggressive app killing = faster.
  - **enable**: If you have issue with dynamic swappiness you can turn it off.
- **threshold_psi**: Control dynamic swappiness sensitivity—higher values = less sensitive changes.
  - **auto_cpu**: This is more influential, changes a lot, control sensitivity of dynamic swappiness based on cpu presure, the idea is _when high cpu pressure we should decrease swapping to improve performance_, I never really test it but here is the module.

### **🌀 Dynamic Swappiness**

- **swappiness_range** – Controls swap limit:
  - **Min** – (e.g, 40). - Use less ZRAM/SWAP, kill more apps, improve performance.
  - **High (e.g., 140)** – Move memory to ZRAM/SWAP, improve multitasking. Lower this if your phone get laggy.
- **threshold_psi** – Threshold to adjusts swappiness based on system pressure:
  - **mode**
    - **auto**: `auto` will generate swappiness levels between your min and max. Like [40 60 80 100 120] for 4 levels between 40 and 120 swappiness, the program will automatically choose which swappiness to use based on system pressures.
    - **auto_cpu and else**: Sensitivity for each hardware pressure.
      - **time_window**: Pick between `avg10`, `avg60`, `avg300`. Smaller = more sensitive, so far avg60 is a nice spot.
  - **cpu_pressure and else**: Manual configuration for each pressure range. It's a pair in `[pressure, swappiness]`, if the pressure reached then use that swappiness.

### **🗃️ Virtual Memory (VM) Optimization**

- **enable** – Enables VM optimizations (**recommended** for multitasking).
- ~~**pressure_binding** – Activates swap **only under pressure** (⚠️ experimental). **This function is broken**.~~
- **deactivate_in_sleep** – Only deactivate in sleep to be more **battery** friendly.
- **zram**: Handles **incremental ZRAM management**
  - **activation_threshold**: Percentage of ZRAM usage to activate next zram
  - **deactivation_threshold**: Minimum size in MB of used swap to deactivate zram. The default is 55MB, deactivating ZRAM when high usage can increase cpu usage. It's why only deactivate in sleep, the program also deactivate swap automatically when usage only 10MB.
- **swap**: You get it, its same as above except this one for SWAP.

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
⚙️ **Tuning example** ⇒ [Performance tuning](https://github.com/lululoid/LMKD-PSI-Activator/blob/main/tuning_example.md)

### Want to see how the module works?

Try opening a bunch of apps or gaming while opening other apps then use this command on termux:

```shell
sudo logcat -s fmiop -v brief
```

Or on your computer(Make sure your developer mode active, and you authorized your computer):

```shell
adb logcat -s fmiop -v brief
```

Or just check log in:

``` markdown
 Internal storage → Android/fmiop/archives
```
