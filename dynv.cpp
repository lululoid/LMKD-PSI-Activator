#include <algorithm>
#include <android/log.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>
#include <yaml-cpp/yaml.h>

#define SWAP_PROC_FILE "/proc/swaps"
#define ZRAM_DIR "/dev/block"
#define ZRAM_PATTERN "/dev/block/zram*"

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

// Function to get the smallest priority of active ZRAM swaps
int get_last_priority(const string &filter) {
  ifstream file(SWAP_PROC_FILE);
  if (!file) {
    ALOGE("Error: Unable to open %s", SWAP_PROC_FILE);
    return -1;
  }

  string line;
  vector<int> priorities;

  // Skip the first line (header)
  getline(file, line);

  while (getline(file, line)) {
    istringstream iss(line);
    string device;
    int priority;
    string temp;

    // Extract values: device name is first, priority is the 5th column
    for (int i = 0; i < 5; ++i) {
      if (!(iss >> temp)) {
        break;
      }
      if (i == 0) {
        device = temp;
      } else if (i == 4) {
        priority = stoi(temp);
      }
    }

    if (device.find(filter) != string::npos) {
      priorities.push_back(priority);
    }
  }

  if (priorities.empty()) {
    ALOGW("No active ZRAM swaps found.");
    return -1;
  }

  return *min_element(priorities.begin(), priorities.end());
}

// Function to check if a ZRAM device is active
bool is_active(const string &device) {
  ifstream file(SWAP_PROC_FILE);
  if (!file) {
    ALOGE("Error: Unable to open %s", SWAP_PROC_FILE);
    return false;
  }

  string line;
  while (getline(file, line)) {
    if (line.find(device) != string::npos) {
      return true;
    }
  }
  return false;
}

vector<string> get_available_swap(const string &filter) {
  vector<string> available_swaps;

  for (const auto &entry : filesystem::directory_iterator(ZRAM_DIR)) {
    string pathStr = entry.path().string();
    if (pathStr.find(filter) != string::npos) {
      available_swaps.push_back(pathStr);
    }
  }

  if (available_swaps.empty()) {
    ALOGW("No ZRAM partitions available in %s", ZRAM_DIR);
  }

  return available_swaps;
}

vector<string> get_active_swap(const string &filter) {
  string line;
  vector<string> active_swaps;
  ifstream file(SWAP_PROC_FILE);

  if (!file) {
    ALOGE("Error: Unable to open %s", SWAP_PROC_FILE);
  }

  // Skip header
  getline(file, line);

  while (getline(file, line)) {
    istringstream iss(line);
    string device;
    iss >> device;
    if (device.find(filter) != string::npos) {
      active_swaps.push_back(device);
    }
  }

  return active_swaps;
}

int get_swap_usage(const string &device) {
  string line;
  ifstream proc_file(SWAP_PROC_FILE);

  getline(proc_file, line);

  int size = 0, used = 0;
  while (getline(proc_file, line)) {
    if (line.find(device) != string::npos) {
      istringstream iss(line);
      string temp;
      iss >> temp >> temp >> size >> used;
      break;
    }
  }

  if (size == 0) {
    ALOGE("Error: Could not determine size of %s", device.c_str());
    return nan("");
  }

  return (used * 100) / size;
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
  int ZRAM_ACTIVATION_THRESHOLD =
      read_config(".virtual_memory.zram.activation_threshold", 25);
  int ZRAM_DEACTIVATION_THRESHOLD =
      read_config(".virtual_memory.zram.deactivation_threshold", 10);

  vector<string> available_zrams = get_available_swap("zram");
  vector<string> deactivation_candidates;

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
      ALOGI("Swappiness adjusted to %d", new_swappiness);
    }

    vector<string> active_zrams = get_active_swap("zram");

    if (active_zrams.empty() && !available_zrams.empty()) {
      string first_zram = available_zrams[0];
      int zram_priority = 32767;
      ALOGI("No active ZRAM found. Activating %s with priority %d",
            first_zram.c_str(), zram_priority);

      // Instead of system(), consider direct manipulation if possible
      system(
          ("swapon -p " + to_string(zram_priority) + " " + first_zram).c_str());
      return;
    }

    if (!active_zrams.empty()) {
      string last_active_zram = active_zrams.back();
      int lst_zram_usage = get_swap_usage(last_active_zram);

      if (lst_zram_usage >= ZRAM_ACTIVATION_THRESHOLD) {
        string next_zram;
        for (const auto &zram : available_zrams) {
          if (!is_active(zram)) {
            next_zram = zram;
            break;
          }
        }

        if (!next_zram.empty()) {
          int last_zpriority = get_last_priority("zram");
          if (last_zpriority != -1) {
            last_zpriority--;
            ALOGI("Activating %s at %d%% usage with priority %d",
                  next_zram.c_str(), lst_zram_usage, last_zpriority);
            system(("swapon -p " + to_string(last_zpriority) + " " + next_zram)
                       .c_str());
          }
        } else {
          ALOGW("No additional ZRAM available; switching to swap mode.");
        }
      }

      bool is_in_candidates =
          find(deactivation_candidates.begin(), deactivation_candidates.end(),
               last_active_zram) != deactivation_candidates.end();

      if (lst_zram_usage >= ZRAM_DEACTIVATION_THRESHOLD && !is_in_candidates) {
        ALOGI("ZRAM: %s usage (%d%% < %d%%). Marking for deactivation...",
              last_active_zram.c_str(), lst_zram_usage,
              ZRAM_DEACTIVATION_THRESHOLD);
        deactivation_candidates.push_back(last_active_zram);
      } else if (is_in_candidates) {
        ALOGI("ZRAM deactivation threshold reached");
        system(("swapoff " + last_active_zram).c_str());
        deactivation_candidates.erase(remove(deactivation_candidates.begin(),
                                             deactivation_candidates.end(),
                                             last_active_zram),
                                      deactivation_candidates.end());
      }
    }

    for (int i = 0; i < 10 && running; ++i) {
      this_thread::sleep_for(chrono::milliseconds(100));
    }
  }
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
