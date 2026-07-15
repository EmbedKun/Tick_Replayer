// Host-memory to FPGA-DDR XDMA H2C throughput benchmark.
//
// This measures the memory-mapped XDMA char-device write path with large
// pwrite() transfers.  It intentionally does not touch replay registers.

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <fcntl.h>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <sstream>
#include <string>
#include <thread>
#include <vector>
#include <unistd.h>

struct Args {
  std::string h2c = "auto";
  uint64_t addr = 0x80000000ULL;
  uint64_t bytes = 1ULL << 30;
  uint64_t chunk_bytes = 64ULL << 20;
  int threads = 1;
  int passes = 1;
};

static uint64_t int_auto(const std::string &text) {
  size_t idx = 0;
  uint64_t value = std::stoull(text, &idx, 0);
  if (idx != text.size()) {
    throw std::runtime_error("invalid integer: " + text);
  }
  return value;
}

static std::vector<std::string> split_device_paths(const std::string &text) {
  std::vector<std::string> paths;
  if (text == "auto") {
    for (int channel = 0; channel < 4; ++channel) {
      std::string path = "/dev/xdma0_h2c_" + std::to_string(channel);
      if (::access(path.c_str(), W_OK) == 0) {
        paths.push_back(path);
      }
    }
    if (!paths.empty()) {
      return paths;
    }
    throw std::runtime_error("no writable /dev/xdma0_h2c_* engine was found");
  }
  std::stringstream stream(text);
  std::string item;
  while (std::getline(stream, item, ',')) {
    if (!item.empty()) {
      paths.push_back(item);
    }
  }
  if (paths.empty()) {
    throw std::runtime_error("at least one H2C device path is required");
  }
  return paths;
}

static void usage(const char *argv0) {
  std::cerr
      << "Usage: " << argv0 << " [options]\n\n"
      << "Options:\n"
      << "  --h2c auto|PATH[,PATH...] H2C engine list, default auto\n"
      << "  --addr ADDR            FPGA DDR byte address, default 0x80000000\n"
      << "  --bytes BYTES          bytes per pass, default 1GiB\n"
      << "  --chunk-bytes BYTES    pwrite chunk size, default 64MiB\n"
      << "  --threads N            parallel pwrite streams, default 1\n"
      << "  --passes N             repeated passes, default 1\n";
}

static Args parse_args(int argc, char **argv) {
  Args args;
  for (int i = 1; i < argc; ++i) {
    std::string key = argv[i];
    auto need_value = [&](const char *name) -> std::string {
      if (i + 1 >= argc) {
        throw std::runtime_error(std::string("missing value for ") + name);
      }
      return argv[++i];
    };

    if (key == "--h2c") {
      args.h2c = need_value("--h2c");
    } else if (key == "--addr") {
      args.addr = int_auto(need_value("--addr"));
    } else if (key == "--bytes") {
      args.bytes = int_auto(need_value("--bytes"));
    } else if (key == "--chunk-bytes") {
      args.chunk_bytes = int_auto(need_value("--chunk-bytes"));
    } else if (key == "--threads") {
      args.threads = static_cast<int>(int_auto(need_value("--threads")));
    } else if (key == "--passes") {
      args.passes = static_cast<int>(int_auto(need_value("--passes")));
    } else if (key == "-h" || key == "--help") {
      usage(argv[0]);
      std::exit(0);
    } else {
      throw std::runtime_error("unknown argument: " + key);
    }
  }
  if (args.bytes == 0 || args.chunk_bytes == 0 || args.threads <= 0 || args.passes <= 0) {
    throw std::runtime_error("bytes, chunk-bytes, threads, and passes must be positive");
  }
  return args;
}

static void write_all_at(int fd, const uint8_t *ptr, size_t len, uint64_t offset) {
  size_t done = 0;
  while (done < len) {
    ssize_t rc = ::pwrite(fd, ptr + done, len - done, static_cast<off_t>(offset + done));
    if (rc < 0) {
      throw std::runtime_error(std::string("pwrite failed: ") + std::strerror(errno));
    }
    if (rc == 0) {
      throw std::runtime_error("pwrite returned zero");
    }
    done += static_cast<size_t>(rc);
  }
}

static void fill_pattern(uint8_t *ptr, size_t len, int thread_id) {
  for (size_t i = 0; i < len; ++i) {
    ptr[i] = static_cast<uint8_t>((i * 17 + thread_id * 29 + (i >> 8)) & 0xff);
  }
}

int main(int argc, char **argv) {
  try {
    Args args = parse_args(argc, argv);
    const std::vector<std::string> h2c_paths = split_device_paths(args.h2c);
    uint64_t total_bytes = args.bytes * static_cast<uint64_t>(args.passes);
    uint64_t thread_span = (args.bytes + static_cast<uint64_t>(args.threads) - 1) /
                           static_cast<uint64_t>(args.threads);
    thread_span = ((thread_span + 4095) / 4096) * 4096;

    std::atomic<uint64_t> written_bytes{0};
    std::exception_ptr first_error;
    std::mutex error_mutex;
    auto t0 = std::chrono::steady_clock::now();

    std::vector<std::thread> workers;
    for (int tid = 0; tid < args.threads; ++tid) {
      workers.emplace_back([&, tid]() {
        try {
          const std::string &path = h2c_paths[static_cast<size_t>(tid) % h2c_paths.size()];
          int fd = ::open(path.c_str(), O_WRONLY);
          if (fd < 0) {
            throw std::runtime_error("cannot open H2C device: " + path);
          }

          void *raw = nullptr;
          size_t alloc_size = static_cast<size_t>(args.chunk_bytes);
          if (::posix_memalign(&raw, 4096, alloc_size) != 0 || raw == nullptr) {
            ::close(fd);
            throw std::runtime_error("posix_memalign failed");
          }
          auto *buf = static_cast<uint8_t *>(raw);
          fill_pattern(buf, alloc_size, tid);

          for (int pass = 0; pass < args.passes; ++pass) {
            uint64_t thread_base = args.addr + static_cast<uint64_t>(tid) * thread_span;
            uint64_t thread_limit = std::min<uint64_t>(
                args.bytes, static_cast<uint64_t>(tid + 1) * thread_span);
            uint64_t thread_start = static_cast<uint64_t>(tid) * thread_span;
            if (thread_start >= args.bytes) {
              continue;
            }
            uint64_t todo = thread_limit - thread_start;
            uint64_t offset = 0;
            while (offset < todo) {
              size_t chunk = static_cast<size_t>(
                  std::min<uint64_t>(args.chunk_bytes, todo - offset));
              (void)pass;
              uint64_t pass_addr = thread_base + offset;
              write_all_at(fd, buf, chunk, pass_addr);
              written_bytes.fetch_add(chunk, std::memory_order_relaxed);
              offset += chunk;
            }
          }

          std::free(raw);
          ::close(fd);
        } catch (...) {
          std::lock_guard<std::mutex> lock(error_mutex);
          if (!first_error) {
            first_error = std::current_exception();
          }
        }
      });
    }

    for (auto &worker : workers) {
      worker.join();
    }
    if (first_error) {
      std::rethrow_exception(first_error);
    }

    double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    uint64_t actual = written_bytes.load(std::memory_order_relaxed);
    double gbps = seconds > 0.0 ? static_cast<double>(actual) * 8.0 / seconds / 1e9 : 0.0;
    double gib_s = seconds > 0.0 ? static_cast<double>(actual) / seconds / (1024.0 * 1024.0 * 1024.0) : 0.0;

    std::cout << "h2c_device        : " << args.h2c << "\n";
    std::cout << "addr              : 0x" << std::hex << args.addr << std::dec << "\n";
    std::cout << "bytes_per_pass    : " << args.bytes << "\n";
    std::cout << "passes            : " << args.passes << "\n";
    std::cout << "chunk_bytes       : " << args.chunk_bytes << "\n";
    std::cout << "threads           : " << args.threads << "\n";
    std::cout << "written_bytes     : " << actual << "\n";
    std::cout << std::fixed << std::setprecision(6);
    std::cout << "seconds           : " << seconds << "\n";
    std::cout << std::setprecision(3);
    std::cout << "throughput_gib_s  : " << gib_s << "\n";
    std::cout << "throughput_gbps   : " << gbps << "\n";
    if (actual != total_bytes) {
      std::cerr << "WARNING: expected " << total_bytes << " bytes\n";
    }
    return 0;
  } catch (const std::exception &e) {
    std::cerr << "ERROR: " << e.what() << "\n";
    return 1;
  }
}
