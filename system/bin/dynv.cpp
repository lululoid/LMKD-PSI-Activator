#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <thread>
#include <yaml-cpp/yaml.h>

using namespace std;

atomic<bool> running(true);
const string fmiop_dir = "/sdcard/Android/fmiop";
const string config_file = fmiop_dir + "/config.yaml";

/**
 * Reads a value from a YAML config file with a default fallback.
 */
template <typename T> T read_config(const string &key_path, T default_value) {
  try {
    YAML::Node node = YAML::LoadFile(config_file);
    size_t pos = 0, found;

    // **Fix: Ignore leading dot if present**
    string clean_key_path = key_path;
    if (!key_path.empty() && key_path[0] == '.') {
      clean_key_path = key_path.substr(1);
    }

    while ((found = clean_key_path.find('.', pos)) != string::npos) {
      string key = clean_key_path.substr(pos, found - pos);
      node = node[key];

      if (!node) {
        cerr << "Config key not found: " << key_path
             << ". Using default: " << default_value << endl;
        return default_value;
      }
      pos = found + 1;
    }

    string finalKey = clean_key_path.substr(pos);
    node = node[finalKey];

    if (!node) {
      cerr << "Config key not found: " << key_path
           << ". Using default: " << default_value << endl;
      return default_value;
    }

    T value = node.as<T>();

    cout << "Config [" << key_path << "] = " << value << endl;
    return value;

  } catch (const exception &e) {
    cerr << "Error reading config: " << e.what() << endl;
    return default_value;
  }
}

/**
 * Reads the current swappiness value from the system.
 */
int read_swappiness() {
  ifstream file("/proc/sys/vm/swappiness");
  int swappiness;
  if (file >> swappiness) {
    return swappiness;
  }
  return -1;
}

/**
 * Writes a new swappiness value to the system.
 */
void write_swappiness(int value) {
  ofstream file("/proc/sys/vm/swappiness");
  if (!file) {
    cerr << "Error: Unable to write to /proc/sys/vm/swappiness. Check "
            "permissions."
         << endl;
    return;
  }
  file << value;
}

/**
 * Reads a specific pressure metric from /proc/pressure/<resource>.
 */
double read_pressure(const string &resource, const string &level,
                     const string &key) {
  string file_path = "/proc/pressure/" + resource;
  ifstream file(file_path);

  if (!file.is_open()) {
    cerr << "Error: Unable to open " << file_path << endl;
    return nan(""); // Return NaN instead of -1.0 for clarity
  }

  string line;
  while (getline(file, line)) {
    istringstream iss(line);
    string word;
    iss >> word;

    if (word == level) {
      string metric;
      while (iss >> metric) {
        size_t pos = metric.find('=');
        if (pos != string::npos) {
          string metric_key = metric.substr(0, pos);
          string metric_value = metric.substr(pos + 1);

          if (metric_key == key) {
            return stod(metric_value);
          }
        }
      }
    }
  }
  return nan(""); // Return NaN if key not found
}

/**
 * Dynamic swappiness adjustment service.
 */
void dynv_service() {
  int SWAPPINESS_MAX =
      read_config(".dynamic_swappiness.swappiness_range.max", 140);
  int SWAPPINESS_MIN =
      read_config(".dynamic_swappiness.swappiness_range.min", 80);
  int CPU_PRESSURE_THRESHOLD =
      read_config(".dynamic_swappiness.threshold.cpu_pressure", 35);
  int MEMORY_PRESSURE_THRESHOLD =
      read_config(".dynamic_swappiness.threshold.memory_pressure", 15);
  int IO_PRESSURE_THRESHOLD =
      read_config(".dynamic_swappiness.threshold.io_pressure", 30);
  int SWAPPINESS_STEP = read_config(".dynamic_swappiness.threshold.step", 2);

  while (running) {
    int current_swappiness = read_swappiness();
    if (current_swappiness == -1) {
      cerr << "Error reading swappiness" << endl;
      break;
    }

    double memory_metric = read_pressure("memory", "some", "avg60");
    double cpu_metric = read_pressure("cpu", "some", "avg10");
    double io_metric = read_pressure("io", "some", "avg60");

    if (isnan(memory_metric) || isnan(cpu_metric) || isnan(io_metric)) {
      cerr << "Error reading pressure metrics." << endl;
      break;
    }

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

    // Sleep with interrupt handling
    for (int i = 0; i < 10 && running; ++i) {
      this_thread::sleep_for(chrono::milliseconds(100));
    }
  }
}

/**
 * Handles termination signals.
 */
void signal_handler(int signal) { running = false; }

int main() {
  signal(SIGINT, signal_handler);
  thread adjust_thread(dynv_service);
  adjust_thread.join();
  return 0;
}
