#!/system/bin/sh

### Load Configuration from YAML ###
# Virtual Memory Settings (with defaults if config.yaml is missing)
ZRAM_ACTIVATION_THRESHOLD=$(read_config ".virtual_memory.zram.activation_threshold" 25)
ZRAM_DEACTIVATION_THRESHOLD=$(read_config ".virtual_memory.zram.deactivation_threshold" 10)
SWAP_ACTIVATION_THRESHOLD=$(read_config ".virtual_memory.swap.activation_threshold" 90)
SWAP_DEACTIVATION_THRESHOLD=$(read_config ".virtual_memory.swap.deactivation_threshold" 25)

# Dynamic Swappiness Settings (with defaults)
SWAPPINESS_MAX=$(read_config ".dynamic_swappiness.swappiness_range.max" 140)
SWAPPINESS_MIN=$(read_config ".dynamic_swappiness.swappiness_range.min" 80)
CPU_PRESSURE_THRESHOLD=$(read_config ".dynamic_swappiness.threshold.cpu_pressure" 35)
MEMORY_PRESSURE_THRESHOLD=$(read_config ".dynamic_swappiness.threshold.memory_pressure" 15)
IO_PRESSURE_THRESHOLD=$(read_config ".dynamic_swappiness.threshold.io_pressure" 30)
SWAPPINESS_STEP=$(read_config ".dynamic_swappiness.threshold.step" 2)
PRESSURE_BINDING=$(read_config ".virtual_memory.pressure_binding" false)
VTRIGGER=false
