// High-throughput DDR ring feeder for Tick Replayer STREAM mode.
//
// This tool preserves replay timing semantics: the host only fills a bounded
// FPGA DDR ring and advances STREAM_WR_PTR after complete packet records are
// written. Packet release timing remains owned by the FPGA replay scheduler.

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cctype>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <exception>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <mutex>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <vector>
#include <unistd.h>

namespace fs = std::filesystem;

static constexpr uint64_t DATA_BEAT_BYTES = 64;
static constexpr uint64_t DEFAULT_TICK_HZ = 300000000ULL;

static constexpr off_t REG_CONTROL = 0x0000;
static constexpr off_t REG_MODE = 0x0004;
static constexpr off_t REG_STATUS = 0x0008;
static constexpr off_t REG_DESC_BASE_LO = 0x0010;
static constexpr off_t REG_DESC_BASE_HI = 0x0014;
static constexpr off_t REG_DATA_BASE_LO = 0x0018;
static constexpr off_t REG_DATA_BASE_HI = 0x001c;
static constexpr off_t REG_TRACE_LO = 0x0020;
static constexpr off_t REG_TRACE_HI = 0x0024;
static constexpr off_t REG_PKT_LO = 0x0028;
static constexpr off_t REG_PKT_HI = 0x002c;
static constexpr off_t REG_START_LO = 0x0040;
static constexpr off_t REG_START_HI = 0x0044;
static constexpr off_t REG_RATE = 0x0048;
static constexpr off_t REG_WATERMARK = 0x004c;
static constexpr off_t REG_DEBUG_CTRL = 0x0054;
static constexpr off_t REG_TX_PKTS_LO = 0x0060;
static constexpr off_t REG_TX_PKTS_HI = 0x0064;
static constexpr off_t REG_TX_BYTES_LO = 0x0068;
static constexpr off_t REG_TX_BYTES_HI = 0x006c;
static constexpr off_t REG_LATE_LO = 0x0070;
static constexpr off_t REG_LATE_HI = 0x0074;
static constexpr off_t REG_UNDERRUN_LO = 0x0078;
static constexpr off_t REG_UNDERRUN_HI = 0x007c;
static constexpr off_t REG_DEBUG_TICK_LO = 0x0094;
static constexpr off_t REG_DEBUG_TICK_HI = 0x0098;
static constexpr off_t REG_STREAM_WR_LO = 0x00a0;
static constexpr off_t REG_STREAM_WR_HI = 0x00a4;
static constexpr off_t REG_STREAM_RD_LO = 0x00a8;
static constexpr off_t REG_STREAM_RD_HI = 0x00ac;
static constexpr off_t REG_STREAM_RING_LO = 0x00b0;
static constexpr off_t REG_STREAM_RING_HI = 0x00b4;
static constexpr off_t REG_STREAM_CTRL = 0x00b8;
static constexpr off_t REG_STREAM_STATUS = 0x00bc;
static constexpr off_t REG_STREAM_LEVEL_LO = 0x00c0;
static constexpr off_t REG_STREAM_LEVEL_HI = 0x00c4;

static constexpr uint32_t MODE_STREAM = 1;

struct Args {
  fs::path stream;
  fs::path manifest;
  std::string h2c = "/dev/xdma0_h2c_0";
  std::string user = "/dev/xdma0_user";
  int port = 0;
  uint64_t reg_base_override = UINT64_MAX;
  uint64_t ring_base = 0x20000000ULL;
  uint64_t ring_size = 0x08000000ULL;
  uint64_t prefill_bytes = 0;
  uint64_t guard_bytes = 1ULL << 20;
  uint64_t batch_bytes = 64ULL << 20;
  uint64_t read_bytes = 64ULL << 20;
  uint64_t start_time = 0;
  uint32_t rate_q16_16 = 0x00010000U;
  uint32_t watermark = 4096;
  uint64_t tick_hz = DEFAULT_TICK_HZ;
  double poll_interval = 0.0002;
  double timeout = 60.0;
  double feed_timeout = 0.0;
  size_t queue_depth = 4;
  bool force_link_up = false;
  bool force_tx_ready = false;
  bool no_wait = false;
};

struct Chunk {
  std::vector<uint8_t> data;
  uint64_t packets = 0;
};

class ChunkQueue {
 public:
  explicit ChunkQueue(size_t depth) : depth_(std::max<size_t>(1, depth)) {}

  void push(Chunk &&chunk) {
    std::unique_lock<std::mutex> lock(mutex_);
    cv_not_full_.wait(lock, [&] { return chunks_.size() < depth_ || done_; });
    if (done_) {
      return;
    }
    chunks_.push_back(std::move(chunk));
    cv_not_empty_.notify_one();
  }

  bool pop(Chunk &chunk) {
    std::unique_lock<std::mutex> lock(mutex_);
    cv_not_empty_.wait(lock, [&] { return !chunks_.empty() || done_; });
    if (chunks_.empty()) {
      return false;
    }
    chunk = std::move(chunks_.front());
    chunks_.pop_front();
    cv_not_full_.notify_one();
    return true;
  }

  void finish() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      done_ = true;
    }
    cv_not_empty_.notify_all();
    cv_not_full_.notify_all();
  }

 private:
  size_t depth_;
  bool done_ = false;
  std::mutex mutex_;
  std::condition_variable cv_not_empty_;
  std::condition_variable cv_not_full_;
  std::deque<Chunk> chunks_;
};

static uint64_t int_auto(const std::string &text) {
  size_t idx = 0;
  uint64_t value = std::stoull(text, &idx, 0);
  if (idx != text.size()) {
    throw std::runtime_error("invalid integer: " + text);
  }
  return value;
}

static uint64_t align_up(uint64_t value, uint64_t alignment) {
  return ((value + alignment - 1) / alignment) * alignment;
}

static uint16_t load_le16(const uint8_t *p) {
  return static_cast<uint16_t>(p[0]) |
         static_cast<uint16_t>(static_cast<uint16_t>(p[1]) << 8);
}

static void usage(const char *argv0) {
  std::cerr
      << "Usage: " << argv0 << " --manifest stream_manifest.json [options]\n"
      << "       " << argv0 << " --stream stream.bin [options]\n\n"
      << "Options:\n"
      << "  --h2c PATH                 default /dev/xdma0_h2c_0\n"
      << "  --user PATH                default /dev/xdma0_user\n"
      << "  --port 0|1                 default 0\n"
      << "  --reg-base ADDR            override AXI-Lite base\n"
      << "  --ring-base ADDR           default 0x20000000\n"
      << "  --ring-size BYTES          default 0x08000000\n"
      << "  --prefill-bytes BYTES      default min(ring/2, 64MiB)\n"
      << "  --guard-bytes BYTES        default 1MiB\n"
      << "  --batch-bytes BYTES        complete-record batch target, default 64MiB\n"
      << "  --read-bytes BYTES         file read chunk, default --batch-bytes\n"
      << "  --queue-depth N            producer queue depth, default 4\n"
      << "  --poll-interval SEC        default 0.0002\n"
      << "  --timeout SEC              wait timeout, default 60\n"
      << "  --feed-timeout SEC         default --timeout\n"
      << "  --watermark BYTES          default 4096\n"
      << "  --rate-q16-16 VALUE        default 0x10000\n"
      << "  --start-time TICKS         default 0\n"
      << "  --force-link-up\n"
      << "  --force-tx-ready\n"
      << "  --no-wait\n";
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

    if (key == "--stream") {
      args.stream = need_value("--stream");
    } else if (key == "--manifest") {
      args.manifest = need_value("--manifest");
    } else if (key == "--h2c") {
      args.h2c = need_value("--h2c");
    } else if (key == "--user") {
      args.user = need_value("--user");
    } else if (key == "--port") {
      args.port = static_cast<int>(int_auto(need_value("--port")));
    } else if (key == "--reg-base") {
      args.reg_base_override = int_auto(need_value("--reg-base"));
    } else if (key == "--ring-base") {
      args.ring_base = int_auto(need_value("--ring-base"));
    } else if (key == "--ring-size") {
      args.ring_size = int_auto(need_value("--ring-size"));
    } else if (key == "--prefill-bytes") {
      args.prefill_bytes = int_auto(need_value("--prefill-bytes"));
    } else if (key == "--guard-bytes") {
      args.guard_bytes = int_auto(need_value("--guard-bytes"));
    } else if (key == "--batch-bytes") {
      args.batch_bytes = int_auto(need_value("--batch-bytes"));
    } else if (key == "--read-bytes") {
      args.read_bytes = int_auto(need_value("--read-bytes"));
    } else if (key == "--queue-depth") {
      args.queue_depth = static_cast<size_t>(int_auto(need_value("--queue-depth")));
    } else if (key == "--poll-interval") {
      args.poll_interval = std::stod(need_value("--poll-interval"));
    } else if (key == "--timeout") {
      args.timeout = std::stod(need_value("--timeout"));
    } else if (key == "--feed-timeout") {
      args.feed_timeout = std::stod(need_value("--feed-timeout"));
    } else if (key == "--watermark") {
      args.watermark = static_cast<uint32_t>(int_auto(need_value("--watermark")));
    } else if (key == "--rate-q16-16") {
      args.rate_q16_16 = static_cast<uint32_t>(int_auto(need_value("--rate-q16-16")));
    } else if (key == "--start-time") {
      args.start_time = int_auto(need_value("--start-time"));
    } else if (key == "--tick-hz") {
      args.tick_hz = int_auto(need_value("--tick-hz"));
    } else if (key == "--force-link-up") {
      args.force_link_up = true;
    } else if (key == "--force-tx-ready") {
      args.force_tx_ready = true;
    } else if (key == "--no-wait") {
      args.no_wait = true;
    } else if (key == "-h" || key == "--help") {
      usage(argv[0]);
      std::exit(0);
    } else {
      throw std::runtime_error("unknown argument: " + key);
    }
  }

  if (args.port != 0 && args.port != 1) {
    throw std::runtime_error("--port must be 0 or 1");
  }
  if (args.read_bytes == 0) {
    args.read_bytes = args.batch_bytes;
  }
  if (args.feed_timeout == 0.0) {
    args.feed_timeout = args.timeout;
  }
  return args;
}

static std::string read_text_file(const fs::path &path) {
  std::ifstream file(path);
  if (!file) {
    throw std::runtime_error("cannot open " + path.string());
  }
  return std::string(std::istreambuf_iterator<char>(file), {});
}

static std::string find_json_string(const std::string &text, const std::string &key) {
  const std::string needle = "\"" + key + "\"";
  size_t pos = text.find(needle);
  if (pos == std::string::npos) {
    return {};
  }
  pos = text.find(':', pos + needle.size());
  if (pos == std::string::npos) {
    return {};
  }
  pos = text.find('"', pos + 1);
  if (pos == std::string::npos) {
    return {};
  }
  std::string out;
  bool escape = false;
  for (size_t i = pos + 1; i < text.size(); ++i) {
    char c = text[i];
    if (escape) {
      out.push_back(c);
      escape = false;
    } else if (c == '\\') {
      escape = true;
    } else if (c == '"') {
      return out;
    } else {
      out.push_back(c);
    }
  }
  return {};
}

static uint64_t find_json_uint(const std::string &text, const std::string &key) {
  const std::string needle = "\"" + key + "\"";
  size_t pos = text.find(needle);
  if (pos == std::string::npos) {
    return 0;
  }
  pos = text.find(':', pos + needle.size());
  if (pos == std::string::npos) {
    return 0;
  }
  ++pos;
  while (pos < text.size() && std::isspace(static_cast<unsigned char>(text[pos]))) {
    ++pos;
  }
  size_t start = pos;
  while (pos < text.size() && std::isdigit(static_cast<unsigned char>(text[pos]))) {
    ++pos;
  }
  if (pos == start) {
    return 0;
  }
  return std::stoull(text.substr(start, pos - start));
}

static uint64_t load_manifest(Args &args) {
  if (args.manifest.empty()) {
    return 0;
  }
  std::string text = read_text_file(args.manifest);
  if (args.stream.empty()) {
    std::string stream_file = find_json_string(text, "stream_file");
    if (stream_file.empty()) {
      throw std::runtime_error("manifest has no stream_file");
    }
    args.stream = args.manifest.parent_path() / fs::path(stream_file).filename();
  }
  return find_json_uint(text, "packet_count");
}

static void write_all_at(int fd, const void *buf, size_t len, uint64_t offset) {
  const uint8_t *ptr = static_cast<const uint8_t *>(buf);
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

static void read_all_at(int fd, void *buf, size_t len, uint64_t offset) {
  uint8_t *ptr = static_cast<uint8_t *>(buf);
  size_t done = 0;
  while (done < len) {
    ssize_t rc = ::pread(fd, ptr + done, len - done, static_cast<off_t>(offset + done));
    if (rc < 0) {
      throw std::runtime_error(std::string("pread failed: ") + std::strerror(errno));
    }
    if (rc == 0) {
      throw std::runtime_error("pread returned zero");
    }
    done += static_cast<size_t>(rc);
  }
}

static void write32(int fd, uint64_t offset, uint32_t value) {
  uint8_t data[4] = {
      static_cast<uint8_t>(value & 0xff),
      static_cast<uint8_t>((value >> 8) & 0xff),
      static_cast<uint8_t>((value >> 16) & 0xff),
      static_cast<uint8_t>((value >> 24) & 0xff),
  };
  write_all_at(fd, data, sizeof(data), offset);
}

static uint32_t read32(int fd, uint64_t offset) {
  uint8_t data[4];
  read_all_at(fd, data, sizeof(data), offset);
  return static_cast<uint32_t>(data[0]) |
         (static_cast<uint32_t>(data[1]) << 8) |
         (static_cast<uint32_t>(data[2]) << 16) |
         (static_cast<uint32_t>(data[3]) << 24);
}

static void write64(int fd, uint64_t lo, uint64_t hi, uint64_t value) {
  write32(fd, lo, static_cast<uint32_t>(value));
  write32(fd, hi, static_cast<uint32_t>(value >> 32));
}

static uint64_t read64(int fd, uint64_t lo, uint64_t hi) {
  return static_cast<uint64_t>(read32(fd, lo)) |
         (static_cast<uint64_t>(read32(fd, hi)) << 32);
}

static void pwrite_ring(int fd, const uint8_t *data, size_t len,
                        uint64_t ring_base, uint64_t ring_size,
                        uint64_t write_count) {
  uint64_t offset = write_count % ring_size;
  size_t done = 0;
  while (done < len) {
    size_t chunk = std::min<size_t>(len - done, static_cast<size_t>(ring_size - offset));
    write_all_at(fd, data + done, chunk, ring_base + offset);
    done += chunk;
    offset = 0;
  }
}

static uint64_t reg_base_for_port(const Args &args) {
  if (args.reg_base_override != UINT64_MAX) {
    return args.reg_base_override;
  }
  return args.port == 0 ? 0x00000ULL : 0x10000ULL;
}

static void configure(int user_fd, uint64_t base, const Args &args) {
  write32(user_fd, base + REG_CONTROL, 0x2);
  std::this_thread::sleep_for(std::chrono::milliseconds(1));
  write32(user_fd, base + REG_CONTROL, 0x4);
  std::this_thread::sleep_for(std::chrono::milliseconds(1));
  write32(user_fd, base + REG_MODE, MODE_STREAM);
  write64(user_fd, base + REG_DESC_BASE_LO, base + REG_DESC_BASE_HI, args.ring_base);
  write64(user_fd, base + REG_DATA_BASE_LO, base + REG_DATA_BASE_HI, 0);
  write64(user_fd, base + REG_TRACE_LO, base + REG_TRACE_HI, 0);
  write64(user_fd, base + REG_PKT_LO, base + REG_PKT_HI, 0);
  write64(user_fd, base + REG_START_LO, base + REG_START_HI, args.start_time);
  write32(user_fd, base + REG_RATE, args.rate_q16_16);
  write32(user_fd, base + REG_WATERMARK, args.watermark);
  write64(user_fd, base + REG_STREAM_WR_LO, base + REG_STREAM_WR_HI, 0);
  write64(user_fd, base + REG_STREAM_RING_LO, base + REG_STREAM_RING_HI, args.ring_size);
  write32(user_fd, base + REG_STREAM_CTRL, 0);

  uint32_t debug = read32(user_fd, base + REG_DEBUG_CTRL);
  if (args.force_link_up) {
    debug |= 0x1;
  }
  if (args.force_tx_ready) {
    debug |= 0x2;
  }
  write32(user_fd, base + REG_DEBUG_CTRL, debug);
}

static void start_replay(int user_fd, uint64_t base) {
  write32(user_fd, base + REG_CONTROL, 0x1);
}

static void stop_and_clear(int user_fd, uint64_t base) {
  write32(user_fd, base + REG_CONTROL, 0x2);
  std::this_thread::sleep_for(std::chrono::milliseconds(1));
  write32(user_fd, base + REG_CONTROL, 0x4);
  std::this_thread::sleep_for(std::chrono::milliseconds(1));
}

static std::pair<bool, double> wait_done(int user_fd, uint64_t base, double timeout) {
  auto t0 = std::chrono::steady_clock::now();
  while (true) {
    uint32_t status = read32(user_fd, base + REG_STATUS);
    bool running = (status & 0x1) != 0;
    bool done = (status & 0x2) != 0;
    auto now = std::chrono::steady_clock::now();
    double elapsed = std::chrono::duration<double>(now - t0).count();
    if (done && !running) {
      return {true, elapsed};
    }
    if (elapsed > timeout) {
      return {false, elapsed};
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
}

static void producer_thread(const Args &args, ChunkQueue &queue,
                            std::atomic<uint64_t> &parsed_packets,
                            std::atomic<uint64_t> &parsed_bytes,
                            std::exception_ptr &producer_error) {
  try {
    int fd = ::open(args.stream.c_str(), O_RDONLY);
    if (fd < 0) {
      throw std::runtime_error("cannot open stream file: " + args.stream.string());
    }
    (void)::posix_fadvise(fd, 0, 0, POSIX_FADV_SEQUENTIAL);

    std::vector<uint8_t> carry;
    uint64_t total_packets = 0;
    uint64_t total_bytes = 0;

    while (true) {
      std::vector<uint8_t> data;
      data.swap(carry);
      size_t carry_bytes = data.size();
      data.resize(carry_bytes + static_cast<size_t>(args.read_bytes));

      ssize_t n = ::read(fd, data.data() + carry_bytes, static_cast<size_t>(args.read_bytes));
      if (n < 0) {
        ::close(fd);
        throw std::runtime_error(std::string("read failed: ") + std::strerror(errno));
      }
      if (n == 0) {
        data.resize(carry_bytes);
        data.swap(carry);
        break;
      }
      data.resize(carry_bytes + static_cast<size_t>(n));

      size_t pos = 0;
      uint64_t packets = 0;
      while (data.size() - pos >= DATA_BEAT_BYTES) {
        uint16_t frame_len = load_le16(data.data() + pos + 12);
        uint64_t record_len = DATA_BEAT_BYTES + align_up(frame_len, DATA_BEAT_BYTES);
        if (data.size() - pos < record_len) {
          break;
        }
        pos += static_cast<size_t>(record_len);
        ++packets;
      }

      if (pos != 0) {
        if (pos < data.size()) {
          carry.assign(data.begin() + static_cast<std::ptrdiff_t>(pos), data.end());
          data.resize(pos);
        } else {
          carry.clear();
        }

        Chunk chunk;
        chunk.data = std::move(data);
        chunk.packets = packets;
        total_packets += packets;
        total_bytes += pos;
        parsed_packets.store(total_packets, std::memory_order_relaxed);
        parsed_bytes.store(total_bytes, std::memory_order_relaxed);
        queue.push(std::move(chunk));
      } else {
        data.swap(carry);
      }
      if (carry.size() > args.batch_bytes + DATA_BEAT_BYTES) {
        ::close(fd);
        throw std::runtime_error("stream parser carry buffer grew unexpectedly");
      }
    }

    ::close(fd);
    if (!carry.empty()) {
      throw std::runtime_error("stream file ends with a partial packet record");
    }
  } catch (...) {
    producer_error = std::current_exception();
  }
  queue.finish();
}

int main(int argc, char **argv) {
  try {
    Args args = parse_args(argc, argv);
    uint64_t manifest_packets = load_manifest(args);
    if (args.stream.empty()) {
      usage(argv[0]);
      throw std::runtime_error("--stream or --manifest is required");
    }
    if (args.ring_size == 0 || (args.ring_size % DATA_BEAT_BYTES) != 0) {
      throw std::runtime_error("--ring-size must be a positive 64-byte multiple");
    }
    if (args.guard_bytes < DATA_BEAT_BYTES || args.guard_bytes >= args.ring_size) {
      throw std::runtime_error("--guard-bytes must be at least 64 and smaller than ring size");
    }
    if (args.batch_bytes < DATA_BEAT_BYTES || args.read_bytes < DATA_BEAT_BYTES) {
      throw std::runtime_error("--batch-bytes and --read-bytes must be at least 64");
    }
    if (args.batch_bytes + args.guard_bytes > args.ring_size) {
      throw std::runtime_error("--batch-bytes plus --guard-bytes must fit in the ring");
    }

    uint64_t prefill = args.prefill_bytes;
    if (prefill == 0) {
      prefill = std::min<uint64_t>(args.ring_size / 2, 64ULL << 20);
    }
    prefill = std::max<uint64_t>(DATA_BEAT_BYTES, std::min(prefill, args.ring_size - args.guard_bytes));
    uint64_t base = reg_base_for_port(args);

    int h2c_fd = ::open(args.h2c.c_str(), O_WRONLY);
    if (h2c_fd < 0) {
      throw std::runtime_error("cannot open H2C device: " + args.h2c);
    }
    int user_fd = ::open(args.user.c_str(), O_RDWR);
    if (user_fd < 0) {
      ::close(h2c_fd);
      throw std::runtime_error("cannot open user BAR device: " + args.user);
    }

    ChunkQueue queue(args.queue_depth);
    std::atomic<uint64_t> parsed_packets{0};
    std::atomic<uint64_t> parsed_bytes{0};
    std::exception_ptr producer_error;
    std::thread producer(producer_thread, std::cref(args), std::ref(queue),
                         std::ref(parsed_packets), std::ref(parsed_bytes),
                         std::ref(producer_error));

    bool started = false;
    uint64_t write_count = 0;
    uint64_t packet_count = 0;
    uint64_t max_level = 0;
    uint64_t min_free = args.ring_size;
    auto load_start = std::chrono::steady_clock::now();
    bool completed = false;
    double wall_seconds = 0.0;

    try {
      configure(user_fd, base, args);

      Chunk chunk;
      while (queue.pop(chunk)) {
        if (chunk.data.size() + args.guard_bytes > args.ring_size) {
          throw std::runtime_error("producer chunk is too large for selected ring");
        }

        while (true) {
          double feed_elapsed = std::chrono::duration<double>(
              std::chrono::steady_clock::now() - load_start).count();
          if (args.feed_timeout > 0.0 && feed_elapsed > args.feed_timeout) {
            throw std::runtime_error("ring feed timeout after " + std::to_string(args.feed_timeout) + "s");
          }

          uint64_t read_count = read64(user_fd, base + REG_STREAM_RD_LO, base + REG_STREAM_RD_HI);
          if (read_count > write_count) {
            throw std::runtime_error("FPGA read pointer advanced past host write pointer");
          }
          uint64_t level = write_count - read_count;
          uint64_t free = args.ring_size - level - args.guard_bytes;
          max_level = std::max(max_level, level);
          min_free = std::min(min_free, free);

          if (free >= chunk.data.size()) {
            pwrite_ring(h2c_fd, chunk.data.data(), chunk.data.size(),
                        args.ring_base, args.ring_size, write_count);
            write_count += chunk.data.size();
            packet_count += chunk.packets;
            write64(user_fd, base + REG_STREAM_WR_LO, base + REG_STREAM_WR_HI, write_count);
            if (!started && write_count >= prefill) {
              start_replay(user_fd, base);
              started = true;
            }
            break;
          }

          if (!started && write_count != 0) {
            start_replay(user_fd, base);
            started = true;
          }
          std::this_thread::sleep_for(std::chrono::duration<double>(args.poll_interval));
        }
      }

      if (producer.joinable()) {
        producer.join();
      }
      if (producer_error) {
        std::rethrow_exception(producer_error);
      }
      if (manifest_packets != 0 && manifest_packets != packet_count) {
        throw std::runtime_error("manifest packet_count mismatch: expected " +
                                 std::to_string(manifest_packets) + " parsed " +
                                 std::to_string(packet_count));
      }

      write64(user_fd, base + REG_PKT_LO, base + REG_PKT_HI, packet_count);
      write32(user_fd, base + REG_STREAM_CTRL, 0x1);
      if (!started) {
        start_replay(user_fd, base);
        started = true;
      }

      double load_seconds = std::chrono::duration<double>(
          std::chrono::steady_clock::now() - load_start).count();

      if (!args.no_wait) {
        auto wait_result = wait_done(user_fd, base, args.timeout);
        completed = wait_result.first;
        wall_seconds = wait_result.second;
      }

      uint64_t tx_pkts = read64(user_fd, base + REG_TX_PKTS_LO, base + REG_TX_PKTS_HI);
      uint64_t tx_bytes = read64(user_fd, base + REG_TX_BYTES_LO, base + REG_TX_BYTES_HI);
      uint64_t late_pkts = read64(user_fd, base + REG_LATE_LO, base + REG_LATE_HI);
      uint64_t underrun_pkts = read64(user_fd, base + REG_UNDERRUN_LO, base + REG_UNDERRUN_HI);
      uint64_t ticks = read64(user_fd, base + REG_DEBUG_TICK_LO, base + REG_DEBUG_TICK_HI);
      uint32_t stream_status = read32(user_fd, base + REG_STREAM_STATUS);
      uint64_t stream_level = read64(user_fd, base + REG_STREAM_LEVEL_LO, base + REG_STREAM_LEVEL_HI);

      double hw_seconds = ticks ? static_cast<double>(ticks) / static_cast<double>(args.tick_hz) : wall_seconds;
      double hw_gbps = hw_seconds > 0.0 ? static_cast<double>(tx_bytes) * 8.0 / hw_seconds / 1e9 : 0.0;
      double load_gbps = load_seconds > 0.0 ? static_cast<double>(write_count) * 8.0 / load_seconds / 1e9 : 0.0;

      std::cout << std::boolalpha;
      std::cout << "stream_file       : " << args.stream << "\n";
      std::cout << "ring_base         : 0x" << std::hex << args.ring_base << std::dec << "\n";
      std::cout << "ring_size         : " << args.ring_size << "\n";
      std::cout << "committed_bytes   : " << write_count << "\n";
      std::cout << "committed_packets : " << packet_count << "\n";
      std::cout << "completed         : " << completed << "\n";
      std::cout << "tx_packets        : " << tx_pkts << "\n";
      std::cout << "tx_bytes          : " << tx_bytes << "\n";
      std::cout << "late_packets      : " << late_pkts << "\n";
      std::cout << "underrun_packets  : " << underrun_pkts << "\n";
      std::cout << "stream_status     : 0x" << std::hex << std::setw(8) << std::setfill('0')
                << stream_status << std::dec << std::setfill(' ') << "\n";
      std::cout << "final_level       : " << stream_level << "\n";
      std::cout << "max_ring_level    : " << max_level << "\n";
      std::cout << "min_ring_free     : " << min_free << "\n";
      std::cout << std::fixed << std::setprecision(3);
      std::cout << "load_gbps         : " << load_gbps << "\n";
      std::cout << "hw_gbps           : " << hw_gbps << "\n";
      std::cout << std::setprecision(6);
      std::cout << "load_seconds      : " << load_seconds << "\n";
      std::cout << "wall_seconds      : " << wall_seconds << "\n";

      if (!completed && !args.no_wait) {
        stop_and_clear(user_fd, base);
      }
    } catch (...) {
      queue.finish();
      if (producer.joinable()) {
        producer.join();
      }
      stop_and_clear(user_fd, base);
      ::close(h2c_fd);
      ::close(user_fd);
      throw;
    }

    ::close(h2c_fd);
    ::close(user_fd);
    return 0;
  } catch (const std::exception &e) {
    std::cerr << "ERROR: " << e.what() << "\n";
    return 1;
  }
}
