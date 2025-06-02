# Tuning Example

## Performance mode

>[!CAUTION]
>This is only recommendation, I haven't tested it.  
>It should work in theory. Read README.md to tune it for your need.

```yaml
config_version: 1.4

dynamic_swappiness:
  enable: true  # Whether to enable dynamic swappiness
  threshold_type: "psi"  # "psi" or "legacy"
  swappiness_range:
    max: 100  # Lower max to reduce swap aggressiveness
    min: 20   # Lower min to favor RAM usage
  threshold_psi:
    mode: "auto"  # "auto" or "manual"
    levels: 6
    auto_cpu:
      max: 60
      min: 0
      time_window: "avg60"  # Balanced sensitivity
    auto_memory:
      max: 15
      min: 5
      time_window: "avg60"
    auto_io:
      max: 20
      min: 5
      time_window: "avg60"
    # Manual pressure thresholds (used if mode is "manual")
    cpu_pressure: [[10, 80], [20, 60], [40, 40]]
    memory_pressure: [[10, 80], [15, 60], [20, 40]]
    io_pressure: [[15, 80], [25, 60], [30, 40]]
  threshold_mem_pressure: [[70, 60], [60, 40], [50, 20]]

virtual_memory:
  enable: true  # Whether to enable dynamic ZRAM
  pressure_binding: false
  deactivate_in_sleep: true
  wait_timeout: 600  # Time in seconds before deactivating ZRAM
  zram:
    activation_threshold: 70  # Activate next ZRAM at 70% usage
    deactivation_threshold: 60  # Deactivate ZRAM when usage drops below 60MB
  swap:
    activation_threshold: 80
    deactivation_threshold: 50
```
