#include <atomic>
#include <chrono>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <thread>
#include <yaml-cpp/yaml.h>

using namespace std;

#define SWAPPINESS_MAX 100
#define SWAPPINESS_MIN 10
#define SWAPPINESS_STEP 10
#define CPU_PRESSURE_THRESHOLD 40.0
#define MEMORY_PRESSURE_THRESHOLD 15.0
#define IO_PRESSURE_THRESHOLD 30.0

atomic<bool> running(true);
const string fmiop_dir = "/sdcard/Android/fmiop";
const string config_file = fmiop_dir + "/config.yaml";

/**
 * Reads a value from a YAML config file with a default fallback.
 *
 * @param key_path YAML key path (e.g.,
 * ".virtual_memory.zram.activation_threshold").
 * @param default_value The default value if the key is missing or unreadable.
 * @param config_file Path to the YAML configuration file.
 * @return The value as a string.
 */
template <typename T> T read_config(const string &key_path, T default_value) {
  try {
    YAML::Node config = YAML::LoadFile(config_file);
    YAML::Node node = config;
    size_t pos = 0, found;

    // Parse key_path like ".dynamic_swappiness.swappiness_range.max"
    while ((found = key_path.find('.', pos)) != string::npos) {
      string key = key_path.substr(pos, found - pos);
      node = node[key];
      if (!node)
        return default_value; // If key not found, return default
      pos = found + 1;
    }

    string finalKey = key_path.substr(pos);
    node = node[finalKey];

    return node ? node.as<T>() : default_value; // Return found value or default
  } catch (const exception &e) {
    cerr << "Error reading config: " << e.what() << endl;
    return default_value;
  }
}

int read_swappiness() {
  ifstream file("/proc/sys/vm/swappiness");
  int swappiness;
  if (file >> swappiness) {
    return swappiness;
  }
  return -1;
}

void write_swappiness(int value) {
  ofstream file("/proc/sys/vm/swappiness");
  if (file) {
    file << value;
  }
}

/**
 * Reads a specific pressure metric from /proc/pressure/<resource>.
 *
 * @param resource The system resource to check (cpu, memory, io).
 * @param level The pressure level to find (some, full).
 * @param key The metric key to extract (avg10, avg60, avg300, total).
 * @return The pressure value as a double, or -1.0 if not found.
 */
double read_pressure(const string &resource, const string &level,
                     const string &key) {
  string file_path = "/proc/pressure/" + resource;
  ifstream file(file_path);

  if (!file.is_open()) {
    cerr << "Error: Unable to open " << file_path << endl;
    return -1.0;
  }

  string line;
  while (getline(file, line)) {
    istringstream iss(line);
    string word;
    iss >> word; // Read the first word (should be 'some' or 'full')

    if (word == level) {
      string metric;
      while (iss >> metric) { // Read key=value pairs
        size_t pos = metric.find('=');
        if (pos != string::npos) {
          string metric_key = metric.substr(0, pos);
          string metric_value = metric.substr(pos + 1);

          if (metric_key == key) {
            return stod(metric_value); // Convert to double
          }
        }
      }
    }
  }

  return -1.0; // Key not found
}

void dynv_service() {
  while (running) {
    int current_swappiness = read_swappiness();
    if (current_swappiness == -1) {
      cerr << "Error reading swappiness" << endl;
      return;
    }

    double memory_metric = read_pressure("memory", "some", "avg60");
    double cpu_metric = read_pressure("cpu", "some", "avg10");
    double io_metric = read_pressure("io", "some", "avg60");
    int new_swappiness = current_swappiness;

    if (io_metric > IO_PRESSURE_THRESHOLD ||
        cpu_metric > CPU_PRESSURE_THRESHOLD ||
        memory_metric > MEMORY_PRESSURE_THRESHOLD) {
      new_swappiness =
          max(SWAPPINESS_MIN, current_swappiness - SWAPPINESS_STEP);
      cout << "Decreased swappiness due to system pressure" << endl;
    } else {
      new_swappiness =
          min(SWAPPINESS_MAX, current_swappiness + SWAPPINESS_STEP);
      if (!(new_swappiness == SWAPPINESS_MAX)) {
        cout << "Increased swappiness as system is stable" << endl;
      }
    }

    if (new_swappiness != current_swappiness) {
      write_swappiness(new_swappiness);
      cout << "Swappiness adjusted from " << current_swappiness << " to "
           << new_swappiness << endl;
    }

    this_thread::sleep_for(chrono::seconds(1));
  }
}

void signal_handler(int signal) { running = false; }

int main() {
  signal(SIGINT, signal_handler);
  thread adjust_thread(dynv_service);
  adjust_thread.join();
  return 0;
}
