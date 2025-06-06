use serde::{Serialize, Deserialize};
use std::env;
use std::fs;

#[derive(Debug, Serialize, Deserialize, Clone)]
struct Config {
    config_version: f32,
    dynamic_swappiness: DynamicSwappiness,
    virtual_memory: VirtualMemory,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
struct DynamicSwappiness {
    enable: bool,
    threshold_type: String,
    swappiness_range: Range,
    threshold_psi: ThresholdPsi,
    threshold_mem_pressure: Vec<[u32; 2]>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
struct Range {
    max: u32,
    min: u32,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
struct ThresholdPsi {
    mode: String,
    levels: u32,
    auto_cpu: AutoThreshold,
    auto_memory: AutoThreshold,
    auto_io: AutoThreshold,
    cpu_pressure: Vec<[u32; 2]>,
    memory_pressure: Vec<[u32; 2]>,
    io_pressure: Vec<[u32; 2]>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
struct AutoThreshold {
    max: u32,
    min: u32,
    time_window: String,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
struct VirtualMemory {
    enable: bool,
    pressure_binding: bool,
    deactivate_in_sleep: bool,
    wait_timeout: u32,
    zram: Zram,
    swap: Swap,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
struct Zram {
    activation_threshold: u32,
    deactivation_threshold: u32,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
struct Swap {
    activation_threshold: u32,
    deactivation_threshold: u32,
}

fn load_config(path: &str) -> Config {
    println!("📂 Loading config from: {}", path);
    let config_path = path.to_string();
    let config_data = fs::read_to_string(&config_path)
        .unwrap_or_else(|_| panic!("❌ Failed to read config file at '{}'", config_path));

    let config: Config = serde_yaml::from_str(&config_data)
        .unwrap_or_else(|e| panic!("❌ Failed to parse YAML: {}", e));

    println!("✅ Loaded config version: {}", config.config_version);
    return config;
}

fn main() {
    let default_path = "/sdcard/Android/fmiop/config.yaml".to_string();
    let mut config_path = default_path.clone();

    // Collect command-line args
    let args: Vec<String> = env::args().collect();

    // Look for --config argument
    if let Some(pos) = args.iter().position(|x| x == "--config") {
        if let Some(path) = args.get(pos + 1) {
            config_path = path.clone();
        } else {
            eprintln!("⚠️  '--config' provided but no path specified. Falling back to default.");
        }
    }

    let config = load_config(&config_path);
    println!("{:?}", config.dynamic_swappiness.threshold_psi.cpu_pressure);
}
