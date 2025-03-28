import os
import time
import csv
import subprocess

CSV_FILE = "performance_data.csv"
PRESSURE_PATH = "/proc/pressure/"
CHECK_INTERVAL = 5  # Check every 5 seconds


def init_csv():
    """Initialize CSV file with headers if it doesn't exist."""
    if not os.path.exists(CSV_FILE):
        with open(CSV_FILE, "w", newline="") as file:
            writer = csv.writer(file)
            writer.writerow(
                [
                    "Timestamp",
                    "CPU_Usage(%)",
                    "RAM_Usage(%)",
                    "Temp(°C)",
                    "Battery(%)",
                    "Pressure_CPU_avg10",
                    "Pressure_CPU_avg60",
                    "Pressure_CPU_avg300",
                    "Pressure_IO_avg10",
                    "Pressure_IO_avg60",
                    "Pressure_IO_avg300",
                    "Pressure_Memory_avg10",
                    "Pressure_Memory_avg60",
                    "Pressure_Memory_avg300",
                ]
            )


def read_cpu_usage():
    """Reads CPU usage from /proc/stat."""
    with open("/proc/stat", "r") as f:
        line = f.readline()
    values = line.split()[1:5]  # Extract user, nice, system, idle times
    return list(map(int, values))


def calculate_cpu_load(before, after):
    """Calculates CPU load percentage with error handling."""
    idle_before, total_before = before[3], sum(before)
    idle_after, total_after = after[3], sum(after)

    idle_diff = idle_after - idle_before
    total_diff = total_after - total_before

    if total_diff == 0:  # Avoid division by zero
        return 0.0

    cpu_usage = 100 * (1 - (idle_diff / total_diff))
    return round(cpu_usage, 2)


def read_ram_usage():
    """Reads RAM usage from /proc/meminfo."""
    meminfo = {}
    with open("/proc/meminfo", "r") as f:
        for line in f:
            parts = line.split(":")
            key, value = parts[0], parts[1].strip().split()[0]
            meminfo[key] = int(value)

    total_ram = meminfo["MemTotal"]
    free_ram = meminfo["MemAvailable"]
    used_ram = total_ram - free_ram

    return round((used_ram / total_ram) * 100, 2)


def read_cpu_temperature():
    """Reads CPU temperature (if available)."""
    thermal_path = "/sys/class/thermal/thermal_zone10/temp"
    if os.path.exists(thermal_path):
        with open(thermal_path, "r") as f:
            temp = int(f.read().strip()) / 1000  # Convert to Celsius
        return round(temp, 1)
    return "N/A"


def read_battery_percentage():
    """Reads battery percentage (if available)."""
    battery_path = "/sys/class/power_supply/battery/capacity"
    if os.path.exists(battery_path):
        with open(battery_path, "r") as f:
            return int(f.read().strip())
    return "N/A"


def parse_pressure_file(file_path):
    """Parses a pressure file and extracts data into a structured dictionary."""
    data = {}

    with open(file_path, "r") as file:
        for line in file:
            parts = line.strip().split()
            category = parts[0]  # 'some' or 'full'
            metrics = {k: float(v) for k, v in (x.split("=") for x in parts[1:])}
            data[category] = metrics

    return data


def read_all_pressure():
    """Reads all pressure files in /proc/pressure/ and returns structured data."""
    results = {}

    for filename in os.listdir(PRESSURE_PATH):
        file_path = os.path.join(PRESSURE_PATH, filename)
        if os.path.isfile(file_path):
            results[filename] = parse_pressure_file(file_path)

    return results


def send_notification(message):
    """Sends a notification using the 'su' command on Android."""
    command = f"su -lp 2000 -c \"command cmd notification post -S bigtext -t 'fmiop monitor' 'fmiop monitor' '{message}'\""

    result = subprocess.run(command, shell=True, capture_output=True)
    if result.returncode != 0:
        print(f"⚠️ Notification failed! Error: {result.stderr.decode().strip()}")
    else:
        print(f"✅ Notification sent: {message}")


def read_pressure_data():
    """Reads CPU, IO, and Memory pressure data from /proc/pressure/."""
    pressure_data = {}

    for category in ["cpu", "io", "memory"]:
        file_path = os.path.join(PRESSURE_PATH, category)
        if os.path.exists(file_path):
            with open(file_path, "r") as file:
                for line in file:
                    parts = line.strip().split()
                    level = parts[0]  # 'some' or 'full'
                    metrics = {
                        k: float(v) for k, v in (x.split("=") for x in parts[1:])
                    }
                    pressure_data[f"{category}_{level}"] = metrics

    return pressure_data


def log_performance():
    """Logs system performance and pressure metrics to CSV."""
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    cpu_before = read_cpu_usage()
    time.sleep(1)
    cpu_now = read_cpu_usage()
    cpu_usage = calculate_cpu_load(cpu_before, cpu_now) if cpu_before else "N/A"
    ram_usage = read_ram_usage()
    cpu_temp = read_cpu_temperature()
    battery = read_battery_percentage()
    pressure_data = read_pressure_data()

    # Convert pressure data into a formatted string
    pressure_log = " | ".join(
        [
            f"{key}: avg10={value['avg10']} avg60={value['avg60']} avg300={value['avg300']}"
            for key, value in pressure_data.items()
        ]
    )

    log = (
        f"[{timestamp}] CPU: {cpu_usage}% | RAM: {ram_usage}% | Temp: {cpu_temp}°C | "
        f"Battery: {battery}% | {pressure_log}"
    )
    print(log)

    # Append to CSV
    with open(CSV_FILE, "a", newline="") as file:
        writer = csv.writer(file)

        # CSV Header (written only if the file is empty)
        if file.tell() == 0:
            headers = [
                "Timestamp",
                "CPU Usage",
                "RAM Usage",
                "CPU Temp",
                "Battery",
            ]
            headers += [f"{key}_avg10" for key in pressure_data.keys()]
            headers += [f"{key}_avg60" for key in pressure_data.keys()]
            headers += [f"{key}_avg300" for key in pressure_data.keys()]
            writer.writerow(headers)

        # Log data in CSV format
        row = [timestamp, cpu_usage, ram_usage, cpu_temp, battery]
        for key in pressure_data.keys():
            row.append(pressure_data[key]["avg10"])
        for key in pressure_data.keys():
            row.append(pressure_data[key]["avg60"])
        for key in pressure_data.keys():
            row.append(pressure_data[key]["avg300"])

        writer.writerow(row)


# 🔵 Initialize CSV
init_csv()

# 🟢 Start measuring
print("Measuring performance...")

while True:
    pressure_data = read_all_pressure()

    # 🔥 Check if any value is high and send a notification
    for category, data in pressure_data.items():
        for level, metrics in data.items():
            if metrics["avg10"] > 50:  # Adjust threshold as needed
                msg = f"{category.upper()} {level} pressure high! avg10={metrics['avg10']}"
                send_notification(msg)

    log_performance()

    time.sleep(CHECK_INTERVAL)  # Wait before checking again
