#include <algorithm>
#include <android/log.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <sstream>
#include <string>
#include <sys/swap.h> // For swapon(), swapoff()
#include <thread>
#include <unistd.h>
#include <unordered_set>
#include <utility>
#include <vector>
#include <yaml-cpp/yaml.h>

#define SWAP_PROC_FILE "/proc/swaps"
#define ZRAM_DIR "/dev/block"
#define SWAP_DIR "/data/adb"

using namespace std;
namespace fs = std::filesystem;

#define LOG_TAG "fmiop"
#define ALOGD(...) __android_log_print(ANDROID_LOG_DEBUG, LOG_TAG, __VA_ARGS__)
#define ALOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define ALOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define ALOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)

extern void save_pid(const std::string &filename, pid_t pid);
extern void dyn_swap_service();
extern void fmiop();

atomic<bool> running(true);
const string fmiop_dir = "/sdcard/Android/fmiop";
const string config_file = fmiop_dir + "/config.yaml";
const string NVBASE = "/data/adb";
const string LOG_FOLDER = NVBASE + "/" + LOG_TAG;
const string PID_DB = LOG_FOLDER + "/" + LOG_TAG + ".pids";
string SWAP_FILE = "fmiop_swap.";

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
void signal_handler(int signal) {
  ALOGI("Received signal %d, exiting...", signal);
  running = false;
  exit(signal);
}

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

vector<string> get_available_swap() {
  vector<string> available_swaps;
  vector<string> dir_list = {ZRAM_DIR, SWAP_DIR}; // Directories to check
  string line;

  for (const auto &dir : dir_list) {
    if (!fs::exists(dir)) {
      ALOGW("Directory does not exist: %s", dir.c_str());
      continue; // Continue to the next directory
    }
    if (!fs::is_directory(dir)) {
      ALOGW("Path is not a directory: %s", dir.c_str());
      continue;
    }

    bool found_swap = false;
    for (const auto &entry : fs::directory_iterator(dir)) {
      if (entry.is_directory())
        continue; // Skip non-file entries

      string pathStr = entry.path().string();
      if (pathStr.find("swap") != string::npos ||
          pathStr.find("zram") != string::npos) { // Filter swap files
        if (is_active(pathStr)) {
          ALOGI("ACTIVE SWAP detected: %s",
                pathStr.c_str()); // Log active swaps
        } else {
          ALOGD("INACTIVE SWAP found: %s",
                pathStr.c_str()); // Log inactive swaps
          available_swaps.insert(available_swaps.begin(), pathStr);
        }
        found_swap = true;
      }
    }

    if (!found_swap) {
      ALOGW("No swap files found in directory: %s", dir.c_str());
    }
  }

  return available_swaps; // Only return inactive swaps
}

vector<string> get_active_swap() {
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
    active_swaps.push_back(device);
  }

  return active_swaps;
}

pair<int, int> get_swap_usage(const string &device) {
  string line;
  ifstream proc_file(SWAP_PROC_FILE);

  getline(proc_file, line); // Skip header line

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
    return {0, -1}; // Return -1% to indicate error
  }

  int used_percentage = (used * 100) / size;
  int used_mb = (used / 1024);
  return {used_mb, used_percentage}; // Return {used MB, percentage}
}

unordered_set<string>
get_deactivation_candidates(int threshold,
                            const unordered_set<string> last_candidates) {
  unordered_set<string> candidates = last_candidates;
  vector<string> active_swaps = get_active_swap();
  int low_swap_count = 0;

  candidates.reserve(active_swaps.size()); // Prevent multiple reallocations

  for (const auto &swap : active_swaps) {
    pair<int, int> usage = get_swap_usage(swap);
    bool is_in_candidates = find(last_candidates.begin(), last_candidates.end(),
                                 swap) != last_candidates.end();
    if (!is_in_candidates) {
      if (swap.find(SWAP_FILE) != string::npos) {
        candidates.insert(swap);
        ALOGD("%s is in candidates, because it's swap file.", swap.c_str());
      } else if (usage.first > threshold) {
        ALOGD("%s is in candidates, usage(%dMB > %dMB).", swap.c_str(),
              usage.first, threshold);
        candidates.insert(swap);
      } else {
        low_swap_count++;
        if (low_swap_count > 1) {
          ALOGI("Keeping low swap count to 1, adding %s to candidates.",
                swap.c_str());
          candidates.insert(swap);
          low_swap_count--;
        }
      }
    }
  }

  return candidates;
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
      read_config(".virtual_memory.zram.activation_threshold", 70);
  int ZRAM_DEACTIVATION_THRESHOLD =
      read_config(".virtual_memory.zram.deactivation_threshold", 50);
  int SWAP_ACTIVATION_THRESHOLD =
      read_config(".virtual_memory.swap.activation_threshold", 90);
  int SWAP_DEACTIVATION_THRESHOLD =
      read_config(".virtual_memory.swap.deactivation_threshold", 50);
  bool PRESSURE_BINDING =
      read_config(".virtual_memory.pressure_binding", false);

  vector<string> available_swaps = get_available_swap();
  vector<string> active_swaps = get_active_swap();
  unordered_set<string> deactivation_candidates;
  string swap_type = "zram";
  string last_active_swap;
  int activation_threshold, deactivation_threshold, unbounded, new_swappiness;
  int last_swappiness = read_swappiness();

  while (running) {
    int current_swappiness = read_swappiness();
    if (current_swappiness == -1) {
      ALOGE("Error reading swappiness");
      return;
    }

    double memory_metric = read_pressure("memory", "some", "avg60");
    double cpu_metric = read_pressure("cpu", "some", "avg10");
    double io_metric = read_pressure("io", "some", "avg60");

    if (isnan(memory_metric) || isnan(cpu_metric) || isnan(io_metric)) {
      ALOGE("Error reading pressure metrics.");
      return;
    }

    if (current_swappiness > SWAPPINESS_MIN &&
        (io_metric > IO_PRESSURE_THRESHOLD ||
         cpu_metric > CPU_PRESSURE_THRESHOLD ||
         memory_metric > MEMORY_PRESSURE_THRESHOLD)) {
      new_swappiness =
          max(SWAPPINESS_MIN, current_swappiness - SWAPPINESS_STEP);
      unbounded = true;
    } else if (current_swappiness < SWAPPINESS_MAX) {
      new_swappiness =
          min(SWAPPINESS_MAX, current_swappiness + SWAPPINESS_STEP);
      unbounded = !PRESSURE_BINDING;
    }

    if (new_swappiness != current_swappiness) {
      if (new_swappiness >= last_swappiness + 10 ||
          new_swappiness <= last_swappiness - 10) {
        ALOGI("Swappiness -> %d", new_swappiness);
        last_swappiness = new_swappiness;
      }
      write_swappiness(new_swappiness);
    }

    if (unbounded) {
      if (active_swaps.empty()) {
        if (!available_swaps.empty()) {
          string first_swap = available_swaps.back();
          active_swaps.push_back(first_swap);

          if (swapon(first_swap.c_str(), 0) == 0) {
            ALOGE("SWAP: %s turned on.", first_swap.c_str());
            available_swaps.pop_back(); // Use pop_back() instead of `erase()`
          } else {
            ALOGE("Failed to activate swap: %s", first_swap.c_str());
          }
        }
      } else {
        last_active_swap = active_swaps.back();
        pair<int, int> lst_swap_usage = get_swap_usage(last_active_swap);
        activation_threshold =
            (last_active_swap.find(SWAP_FILE) != string::npos)
                ? SWAP_ACTIVATION_THRESHOLD
                : ZRAM_ACTIVATION_THRESHOLD;
        deactivation_threshold =
            (last_active_swap.find(SWAP_FILE) != string::npos)
                ? SWAP_DEACTIVATION_THRESHOLD
                : ZRAM_DEACTIVATION_THRESHOLD;

        if (lst_swap_usage.second > activation_threshold) {
          string next_swap = available_swaps.back();

          if (swapon(next_swap.c_str(), 0) == 0) {
            ALOGE("SWAP: %s turned on", next_swap.c_str());
            active_swaps.push_back(next_swap);
            available_swaps.erase(remove(available_swaps.begin(),
                                         available_swaps.end(), next_swap),
                                  available_swaps.end());
          } else {
            ALOGE("Failed to activate swap: %s", next_swap.c_str());
          }
        } else if (last_active_swap.empty() &&
                   lst_swap_usage.first < deactivation_threshold) {
          deactivation_candidates = get_deactivation_candidates(
              deactivation_threshold, deactivation_candidates);
          bool is_in_candidates =
              (deactivation_candidates.find(last_active_swap) !=
               deactivation_candidates.end());

          ALOGI("SWAP deactivation threshold reached (Usage: %dMB < %dMB).",
                lst_swap_usage.first, deactivation_threshold);

          if (is_in_candidates) {
            if (swapoff(last_active_swap.c_str()) == 0) {
              ALOGI("Turning off %s.", last_active_swap.c_str());
              deactivation_candidates.erase(last_active_swap);
              available_swaps.push_back(last_active_swap);
            } else {
              ALOGE("Failed to deactivate swap: %s", last_active_swap.c_str());
            }
          }
        }
      }
    }

    // Sleep for 1 second (100ms * 10 loops)
    for (int i = 0; i < 10 && running; ++i) {
      this_thread::sleep_for(chrono::milliseconds(100));
    }
  }
}

void relmkd() {
  system("resetprop lmkd.reinit 1");
  ALOGD("LMKD reinitialized");
}

bool prop_exists(const std::string &prop) {
  std::string command = "resetprop -v " + prop + " 2>/dev/null";
  FILE *pipe = popen(command.c_str(), "r");
  if (!pipe) {
    ALOGW("Failed to check property: %s", prop.c_str());
    return false;
  }

  char buffer[128];
  bool exists = false;
  if (fgets(buffer, sizeof(buffer), pipe) != nullptr) {
    exists = true; // If output is not empty, property exists
  }

  pclose(pipe);
  return exists;
}

void rm_prop(const std::vector<std::string> &props) {
  for (const auto &prop : props) {
    if (prop_exists(prop)) {
      std::string command = "resetprop -d " + prop;
      int result = system(command.c_str());

      if (result == 0) {
        ALOGW("Prop %s deleted successfully", prop.c_str());
      } else {
        ALOGW("Failed to delete prop: %s", prop.c_str());
      }
    }
  }
}

void fmiop() {
  ALOGI("Starting fmiop memory optimization");

  // Load properties
  map<string, string> props;
  ifstream props_file("/data/adb/modules/fogimp/system.prop");
  string line;

  while (getline(props_file, line)) {
    if (line.empty() || line[0] == '#')
      continue;
    size_t equal_pos = line.find('=');
    if (equal_pos != string::npos) {
      string key = line.substr(0, equal_pos);
      string value = line.substr(equal_pos + 1);
      props[key] = value;
      ALOGD("Loaded property %s=%s", key.c_str(), value.c_str());
    }
  }
  props_file.close();

  while (true) {
    rm_prop({"sys.lmk.minfree_levels"});

    for (const auto &[prop, value] : props) {
      string check_command = "resetprop " + prop + " >/dev/null 2>&1";
      if (system(check_command.c_str()) != 0) {
        string reset_command = "resetprop " + prop + " " + value;
        system(reset_command.c_str());
        ALOGI("Reapplied %s=%s", prop.c_str(), value.c_str());
        relmkd();
      }
    }

    this_thread::sleep_for(chrono::seconds(1));
  }
}

int main() {
  signal(SIGINT, signal_handler);

  pid_t current_pid = getpid();
  ALOGI("Current PID: %d", current_pid);
  save_pid("dyn_swap_service", current_pid);

  std::thread adjust_thread(dyn_swap_service);
  std::thread fmiop_thread(fmiop);

  adjust_thread.join();
  fmiop_thread.join();

  return 0;
}
