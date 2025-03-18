#include <android/log.h>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>
#include <yaml-cpp/yaml.h>

using namespace std;

#define LOG_TAG "fmiop"
#define ALOGD(...) __android_log_print(ANDROID_LOG_DEBUG, LOG_TAG, __VA_ARGS__)
#define ALOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define ALOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define ALOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)

atomic<bool> running(true);
const string fmiop_dir = "/sdcard/Android/fmiop";
const string config_file = fmiop_dir + "/config.yaml";
const string NVBASE = "/data/adb";
const string LOG_FOLDER = NVBASE + "/" + LOG_TAG;
const string PID_DB = LOG_FOLDER + "/" + LOG_TAG + ".pids";

/**
 * Reads a value from a YAML config file with a default fallback.
 */
template <typename T> T read_config(const string &key_path, T default_value) {
  try {
    YAML::Node node = YAML::LoadFile(config_file);
    size_t pos = 0, found;
    string clean_key_path =
        (key_path[0] == '.') ? key_path.substr(1) : key_path;

    while ((found = clean_key_path.find('.', pos)) != string::npos) {
      string key = clean_key_path.substr(pos, found - pos);
      node = node[key];

      if (!node) {
        ALOGW("Config key not found: %s. Using default: %d", key_path.c_str(),
              default_value);
        return default_value;
      }
      pos = found + 1;
    }

    string finalKey = clean_key_path.substr(pos);
    node = node[finalKey];

    if (!node) {
      ALOGW("Config key not found: %s. Using default: %d", key_path.c_str(),
            default_value);
      return default_value;
    }

    T value = node.as<T>();
    ALOGI("Config [%s] = %d", key_path.c_str(), value);
    return value;

  } catch (const exception &e) {
    ALOGE("Error reading config: %s", e.what());
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
    ALOGE("Error: Unable to write to /proc/sys/vm/swappiness. Check "
          "permissions.");
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
    ALOGE("Error: Unable to open %s", file_path.c_str());
    return nan("");
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
  return nan("");
}

/**
 * Dynamic swappiness adjustment service.
 */
void dyn_swap_service() {
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
      ALOGE("Error reading swappiness");
      break;
    }

    double memory_metric = read_pressure("memory", "some", "avg60");
    double cpu_metric = read_pressure("cpu", "some", "avg10");
    double io_metric = read_pressure("io", "some", "avg60");

    if (isnan(memory_metric) || isnan(cpu_metric) || isnan(io_metric)) {
      ALOGE("Error reading pressure metrics.");
      break;
    }

    int new_swappiness = current_swappiness;

    if (io_metric > IO_PRESSURE_THRESHOLD ||
        cpu_metric > CPU_PRESSURE_THRESHOLD ||
        memory_metric > MEMORY_PRESSURE_THRESHOLD) {
      new_swappiness =
          max(SWAPPINESS_MIN, current_swappiness - SWAPPINESS_STEP);
    } else {
      new_swappiness =
          min(SWAPPINESS_MAX, current_swappiness + SWAPPINESS_STEP);
    }

    if (new_swappiness != current_swappiness) {
      write_swappiness(new_swappiness);

      if (new_swappiness == SWAPPINESS_MIN) {
        ALOGI("Swappiness decreased to the minimum due to system pressure");
      } else if (new_swappiness == SWAPPINESS_MAX) {
        ALOGI("Swappiness increased to the maximum as the system is stable");
      } else {
        ALOGI("Swappiness adjusted to %d", new_swappiness);
      }
    }

    for (int i = 0; i < 10 && running; ++i) {
      this_thread::sleep_for(chrono::milliseconds(100));
    }
  }
}

/**
 * Handles termination signals.
 */
void signal_handler(int signal) { running = false; }

/**
 * Saves a PID to a file (PID_DB) with a given name.
 * If the name already exists, it is replaced.
 *
 * @param pid_name The name associated with the PID.
 * @param pid_value The PID to be saved.
 */
void save_pid(const string &pid_name, int pid_value) {
  vector<string> lines;
  string line;
  bool found = false;

  // Open the PID_DB file for reading.
  ifstream infile(PID_DB);
  if (infile) {
    while (getline(infile, line)) {
      // Check if the line starts with "pid_name="
      if (line.compare(0, pid_name.size() + 1, pid_name + "=") != 0) {
        lines.push_back(line);
      } else {
        found = true;
      }
    }
    infile.close();
  }

  // Append the new PID entry.
  lines.push_back(pid_name + "=" + to_string(pid_value));

  // Open PID_DB for writing (this overwrites the file).
  ofstream outfile(PID_DB);
  if (!outfile) {
    ALOGE("Error: Unable to open %s for writing.", PID_DB.c_str());
    return;
  }

  for (const auto &l : lines) {
    outfile << l << "\n";
  }
  outfile.close();

  ALOGD("Saved PID %d for %s %s", pid_value, pid_name.c_str(),
        found ? "(Updated)" : "(New)");
}

int main() {
  signal(SIGINT, signal_handler);

  pid_t current_pid = getpid();
  ALOGI("Current PID: %d", current_pid);

  save_pid("dyn_swap_service", current_pid);

  thread adjust_thread(dyn_swap_service);
  adjust_thread.join();
  return 0;
}
