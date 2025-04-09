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
#include <stdexcept>
#include <string>
#include <sys/stat.h>
#include <sys/swap.h> // For swapon(), swapoff()
#include <thread>
#include <unistd.h>
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

extern void save_pid(const string &filename, pid_t pid);
extern void dyn_swap_service();
extern void fmiop();

atomic<bool> running(true);
const string fmiop_dir = "/sdcard/Android/fmiop";
const string NVBASE = "/data/adb";
const string LOG_FOLDER = NVBASE + "/" + LOG_TAG;
const string config_file = LOG_FOLDER + "/config.yaml";
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

pair<vector<string>, vector<string>> get_available_swap() {
  vector<string> swap_files, zram_devices;
  vector<string> dir_list = {SWAP_DIR, ZRAM_DIR};

  for (const auto &dir : dir_list) {
    if (!fs::exists(dir)) {
      ALOGW("Directory does not exist: %s", dir.c_str());
      continue;
    }
    if (!fs::is_directory(dir)) {
      ALOGW("Path is not a directory: %s", dir.c_str());
      continue;
    }

    for (const auto &entry : fs::directory_iterator(dir)) {
      bool swap_found = false;

      if (entry.is_directory())
        continue;

      string pathStr = entry.path().string();
      if (is_active(pathStr)) {
        ALOGI("ACTIVE SWAP detected: %s", pathStr.c_str());
      } else {
        if (pathStr.find("swap") != string::npos) {
          swap_files.push_back(pathStr);
          swap_found = true;
        } else if (pathStr.find("zram") != string::npos) {
          zram_devices.push_back(pathStr);
          swap_found = true;
        }

        if (swap_found) {
          ALOGD("INACTIVE SWAP found: %s", pathStr.c_str());
        }
      }
    }
  }

  // ✅ **Sorting logic**
  auto extract_number = [](const string &s) -> int {
    size_t pos = s.find_last_not_of("0123456789");
    return (pos != string::npos) ? stoi(s.substr(pos + 1)) : -1;
  };

  sort(swap_files.begin(), swap_files.end(),
       [&](const string &a, const string &b) {
         return extract_number(a) > extract_number(b);
       });

  sort(zram_devices.begin(), zram_devices.end(),
       [&](const string &a, const string &b) {
         return extract_number(a) > extract_number(b);
       });

  // ✅ **Combine them: swap first, then zram**
  vector<string> available_swaps;
  available_swaps.insert(available_swaps.end(), swap_files.begin(),
                         swap_files.end());
  available_swaps.insert(available_swaps.end(), zram_devices.begin(),
                         zram_devices.end());

  for (const auto &swap : available_swaps) {
    ALOGD("Available SWAP: %s", swap.c_str());
  }

  return {zram_devices, swap_files};
}

vector<string> get_active_swap() {
  string line;
  vector<pair<string, long>> swaps; // Store (device, usage)
  ifstream file(SWAP_PROC_FILE);

  if (!file) {
    ALOGE("Error: Unable to open %s", SWAP_PROC_FILE);
    return {}; // Return empty if file can't be opened
  }

  // Skip header
  getline(file, line);

  while (getline(file, line)) {
    istringstream iss(line);
    string device;
    long size, used; // We only care about "used"
    iss >> device >> size >> used;

    if (!device.empty()) {
      swaps.emplace_back(device, used);
    }
  }

  // Sort swaps by usage (descending order)
  sort(swaps.begin(), swaps.end(),
       [](const pair<string, long> &a, const pair<string, long> &b) {
         return a.second > b.second; // Biggest usage first
       });

  // Extract sorted device names
  vector<string> active_swaps;
  for (const auto &swap : swaps) {
    active_swaps.push_back(swap.first);
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

pair<pair<string, int>, vector<string>> get_lusg_swaps(int threshold) {
  string line;
  ifstream proc_file(SWAP_PROC_FILE);
  vector<string> low_usage_swaps;
  pair<string, int> last_nl_swap = {"", 0}; // initialize it with 0
  int &low_swaps_count = last_nl_swap.second;

  getline(proc_file, line); // Skip header line

  int used = 0;
  string device;
  while (getline(proc_file, line)) {
    istringstream iss(line);
    string temp;
    iss >> device >> temp >> temp >> used;
    int used_mb = (used / 1024);

    if (used_mb < threshold) {
      last_nl_swap.first = device;
    } else if (used_mb < 10) {
      low_usage_swaps.push_back(device);
      low_swaps_count++;
    }
  }

  return {last_nl_swap, low_usage_swaps};
}

int get_memory_pressure() {
  ifstream file("/proc/meminfo");
  string line;
  int pressure = 0;

  while (getline(file, line)) {
    if (line.find("MemAvailable") != string::npos) {
      istringstream iss(line);
      string label;
      int available_mem;
      iss >> label >> available_mem;
      pressure = 100 - (available_mem * 100 / 4000000); // Example calculation
      break;
    }
  }

  return pressure;
}

// Function to perform swapoff on a single device
void swapoff_th(const string &device,
                pair<vector<string>, vector<string>> &available_swaps,
                vector<string> &active_swaps) {
  ALOGI("[THREAD] Swapoff: %s", device.c_str());

  if (swapoff(device.c_str()) == 0) {
    ALOGI("Swap: %s is turned off.", device.c_str());
    if (device.find("zram") != string::npos) {
      available_swaps.first.push_back(device);
    } else {
      available_swaps.second.push_back(device);
    }
  } else {
    ALOGE("Failed to deactivate swap: %s", device.c_str());
    active_swaps.push_back(device);
  }
}

bool is_doze_mode() {
  FILE *pipe = popen("dumpsys deviceidle get deep", "r");
  if (!pipe) {
    cerr << "Failed to check Doze Mode!" << endl;
    return false;
  }

  char buffer[128];
  string result = "";

  while (fgets(buffer, sizeof(buffer), pipe) != nullptr) {
    result += buffer;
  }

  pclose(pipe);

  // Trim whitespace
  result.erase(0, result.find_first_not_of(" \n\r\t"));
  result.erase(result.find_last_not_of(" \n\r\t") + 1);

  return (result == "IDLE");
}

bool is_sleep_mode() {
  FILE *pipe = popen("dumpsys power", "r");
  if (!pipe) {
    cerr << "Failed to check Sleep Mode!" << endl;
    return false;
  }

  char buffer[128];
  string result = "";

  while (fgets(buffer, sizeof(buffer), pipe) != nullptr) {
    result += buffer;
  }

  pclose(pipe);

  // Check if display is OFF
  return (result.find("mWakefulness=Asleep") != string::npos);
}

bool is_boot_wait() {
  ifstream file(LOG_FOLDER + "/.boot_wait");
  string line;

  if (!file.is_open()) {
    ALOGE(".boot_wait file is not exists.");
    return false;
  }

  while (getline(file, line)) {
    if (line.find("true") != string::npos) {
      return true;
    }
  }

  return false;
}

void set_boot_wait(const string &value) {
  ofstream outfile(LOG_FOLDER + "/.boot_wait");
  outfile << value;
  outfile.close();
}

void do_wait(int value) {
  ALOGI("Waiting for a while for lmkd to adjust.");
  this_thread::sleep_for(chrono::seconds(value));
  set_boot_wait("false");
  ALOGI("Waited %d second. Dynamic swappiness active now.", value);
}

/**
 * Dynamic swappiness adjustment service.
 */
void dyn_swap_service() {
  int SWAPPINESS_MAX =
      read_config(".dynamic_swappiness.swappiness_range.max", 100);
  int SWAPPINESS_MIN =
      read_config(".dynamic_swappiness.swappiness_range.min", 80);
  int CPU_PRESSURE_THRESHOLD =
      read_config(".dynamic_swappiness.threshold.cpu_pressure", 35);
  int MEMORY_PRESSURE_THRESHOLD =
      read_config(".dynamic_swappiness.threshold.memory_pressure", 15);
  int IO_PRESSURE_THRESHOLD =
      read_config(".dynamic_swappiness.threshold.io_pressure", 30);
  int SWAPPINESS_STEP = read_config(".dynamic_swappiness.step", 2);
  int SWAPPINESS_APPLY_STEP = read_config(".dynamic_swappiness.apply_step", 20);
  int ZRAM_ACTIVATION_THRESHOLD =
      read_config(".virtual_memory.zram.activation_threshold", 70);
  int ZRAM_DEACTIVATION_THRESHOLD =
      read_config(".virtual_memory.zram.deactivation_threshold", 50);
  int SWAP_ACTIVATION_THRESHOLD =
      read_config(".virtual_memory.swap.activation_threshold", 90);
  int SWAP_DEACTIVATION_THRESHOLD =
      read_config(".virtual_memory.swap.deactivation_threshold", 50);
  int SWAP_DEACTIVATION_TIME = read_config(".virtual_memory.wait_timeout", 10);
  bool PRESSURE_BINDING =
      read_config(".virtual_memory.pressure_binding", false);
  bool DEACTIVATE_IN_SLEEP =
      read_config(".virtual_memory.deactivate_in_sleep", true);

  vector<string> active_swaps = get_active_swap();
  pair<vector<string>, vector<string>> available_swaps = get_available_swap();
  string swap_type = "zram";
  string last_active_swap, last_nl_swap, next_swap, first_swap;
  pair<int, int> lst_swap_usage, nl_prev_swap_usg;
  pair<pair<string, int>, vector<string>> nes_info;
  int activation_threshold, deactivation_threshold, lst_nl_act_threshold,
      low_nl_count;
  int last_swappiness = read_swappiness(), new_swappiness = SWAPPINESS_MIN;
  int wait_timeout = SWAP_DEACTIVATION_TIME * 60;
  bool unbounded = true, no_pressure = false;
  bool is_swapoff_session = false, is_condition_met, ls_condition;
  vector<thread> swapoff_thread;
  vector<string> *current_avs, low_usage_swaps;

  while (running) {
    double memory_metric = read_pressure("memory", "some", "avg60");
    double cpu_metric = read_pressure("cpu", "some", "avg10");
    double io_metric = read_pressure("io", "some", "avg60");

    if (isnan(memory_metric) || isnan(cpu_metric) || isnan(io_metric)) {
      ALOGE("Error reading pressure metrics.");
      no_pressure = true;
    }

    if ((io_metric > IO_PRESSURE_THRESHOLD ||
         cpu_metric > CPU_PRESSURE_THRESHOLD ||
         memory_metric > MEMORY_PRESSURE_THRESHOLD) ||
        no_pressure) {
      new_swappiness = max(SWAPPINESS_MIN, new_swappiness - SWAPPINESS_STEP);
      unbounded = true;
    } else {
      new_swappiness = min(SWAPPINESS_MAX, new_swappiness + SWAPPINESS_STEP);
      unbounded = !PRESSURE_BINDING;
    }

    if (!DEACTIVATE_IN_SLEEP) {
      is_swapoff_session = true;
    } else if (!is_swapoff_session && is_sleep_mode()) {
      ALOGI("Waiting for %d minutes...", SWAP_DEACTIVATION_TIME);
      for (int i = 0; i < wait_timeout; ++i) {
        if (!is_sleep_mode()) {
          ALOGI("Device awake before %d minutes, swap deactivation skipped.",
                SWAP_DEACTIVATION_TIME);
          break;
        }
        this_thread::sleep_for(chrono::seconds(1));
      }

      if (is_sleep_mode()) {
        is_swapoff_session = true;
        ALOGD("Swapoff session started...");
      }
    } else if (!is_sleep_mode()) {
      is_swapoff_session = false;
    }

    if (!is_boot_wait()) {
      if (new_swappiness != last_swappiness) {
        if (abs(last_swappiness - new_swappiness) >= SWAPPINESS_APPLY_STEP ||
            new_swappiness == SWAPPINESS_MIN ||
            new_swappiness == SWAPPINESS_MAX) {
          ALOGI("Swappiness -> %d", new_swappiness);
          last_swappiness = new_swappiness;
          write_swappiness(new_swappiness);
        }
      }
    }

    if (!available_swaps.first.empty()) {
      current_avs = &available_swaps.first;
    } else if (!available_swaps.second.empty()) {
      current_avs = &available_swaps.second;
    }

    if (unbounded) {
      // If there's no swap turn on first swap
      if (active_swaps.empty()) {
        if (!current_avs->empty()) {
          first_swap = current_avs->back();
          active_swaps.push_back(first_swap);
          current_avs->pop_back();

          if ((swapon(first_swap.c_str(), 0)) == 0) {
            ALOGI("SWAP: %s turned on.", first_swap.c_str());
          } else {
            ALOGE("Failed to activate swap: %s", first_swap.c_str());
          }
        }
      } else {
        last_active_swap = active_swaps.back();
        lst_swap_usage = get_swap_usage(last_active_swap);
        activation_threshold =
            (last_active_swap.find(SWAP_FILE) != string::npos)
                ? SWAP_ACTIVATION_THRESHOLD
                : ZRAM_ACTIVATION_THRESHOLD;
        deactivation_threshold =
            (last_active_swap.find(SWAP_FILE) != string::npos)
                ? SWAP_DEACTIVATION_THRESHOLD
                : ZRAM_DEACTIVATION_THRESHOLD;

        if (lst_swap_usage.second > activation_threshold) {
          next_swap = current_avs->back();
          active_swaps.push_back(next_swap);
          current_avs->pop_back();

          if ((swapon(next_swap.c_str(), 0)) == 0) {
            ALOGI("SWAP: %s turned on", next_swap.c_str());
          } else {
            ALOGE("Failed to activate swap: %s", next_swap.c_str());
          }
        } else {
          nes_info = get_lusg_swaps(10);
          low_usage_swaps = nes_info.second;
          last_nl_swap = nes_info.first.first;
          low_nl_count = nes_info.first.second;
          lst_nl_act_threshold = (last_nl_swap.find(SWAP_FILE) != string::npos)
                                     ? SWAP_ACTIVATION_THRESHOLD
                                     : ZRAM_ACTIVATION_THRESHOLD;
          nl_prev_swap_usg = get_swap_usage(last_nl_swap);
          is_condition_met = (nl_prev_swap_usg.second < lst_nl_act_threshold &&
                              lst_swap_usage.first < deactivation_threshold) &&
                             is_swapoff_session;
          ls_condition = (nl_prev_swap_usg.second < lst_nl_act_threshold &&
                          low_nl_count > 1);

          if (is_condition_met) {
            ALOGI("Device sleep more than %d minutes. Deactivating swap...",
                  SWAP_DEACTIVATION_TIME);
            swapoff_thread.emplace_back(swapoff_th, last_active_swap,
                                        ref(available_swaps),
                                        ref(active_swaps));
            active_swaps.pop_back();
          } else if (ls_condition) {
            ALOGI("Low swap usage detected...");
            for (auto swap : low_usage_swaps) {
              swapoff_thread.emplace_back(
                  swapoff_th, swap, ref(available_swaps), ref(active_swaps));
              active_swaps.pop_back();
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

bool prop_exists(const string &prop) {
  string command = "resetprop -v " + prop + " 2>/dev/null";
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

void rm_prop(const vector<string> &props) {
  for (const auto &prop : props) {
    if (prop_exists(prop)) {
      string command = "resetprop -d " + prop;
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

  pid_t pid, sid;

  pid = fork();

  if (pid < 0) {
    exit(EXIT_FAILURE);
  }

  if (pid > 0) {
    exit(EXIT_SUCCESS); // Parent process exits
  }

  // Set file mode creation mask to 0
  umask(0);

  // Create a new session ID
  sid = setsid();
  if (sid < 0) {
    ALOGE("Failed to create new session: %s", strerror(errno));
    exit(EXIT_FAILURE);
  }

  if (chdir("/") < 0) {
    ALOGE("Failed to change working directory: %s", strerror(errno));
    exit(EXIT_FAILURE);
  }

  // Close standard file descriptors
  close(STDIN_FILENO);
  close(STDOUT_FILENO);
  close(STDERR_FILENO);

  pid_t current_pid = getpid();
  ALOGI("Current PID: %d", current_pid);
  save_pid("dyn_swap_service", current_pid);

  if (is_boot_wait()) {
    thread boot_waiting(do_wait, 180);
    boot_waiting.detach();
  }
  thread adjust_thread(dyn_swap_service);
  thread fmiop_thread(fmiop);

  adjust_thread.join();
  fmiop_thread.join();

  return 0;
}
