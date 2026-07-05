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
#include <future>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <map>
#include <mutex>
#include <new>
#include <stdexcept>
#include <sstream>
#include <string>
#include <string_view>
#include <thread>
#include <vector>
#include <unistd.h>

namespace fs = std::filesystem;

static constexpr uint64_t DATA_BEAT_BYTES = 64;
static constexpr uint64_t DEFAULT_TICK_HZ = 300000000ULL;
static constexpr size_t DMA_BUFFER_ALIGNMENT = 4096;

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
static constexpr uint32_t STREAM_STATUS_ERROR = 1u << 6;
static constexpr uint32_t STREAM_STATUS_RING_MODE = 1u << 7;
static constexpr uint32_t STREAM_STATUS_SIZE_VALID = 1u << 9;
static constexpr uint32_t STREAM_STATUS_OVERRUN = 1u << 10;
static constexpr uint32_t STREAM_STATUS_PTR_ERROR = 1u << 12;

struct Args {
  fs::path stream;
  fs::path manifest;
  fs::path stripe_manifest;
  fs::path block_list;
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
  uint64_t fixed_record_len = 0;
  uint64_t fixed_frame_len = 0;
  uint64_t host_cache_bytes = 0;
  uint64_t host_cache_effective_bytes = 0;
  double poll_interval = 0.0002;
  double timeout = 60.0;
  double feed_timeout = 0.0;
  double host_cache_fraction = 0.85;
  size_t queue_depth = 4;
  size_t writer_threads = 1;
  size_t reader_threads = 0;
  size_t reader_window_blocks = 0;
  std::string host_cache_arg;
  bool queue_depth_set = false;
  bool writer_threads_set = false;
  bool reader_threads_set = false;
  bool reader_window_blocks_set = false;
  bool force_link_up = false;
  bool force_tx_ready = false;
  bool no_wait = false;
  bool dry_run = false;
};

template <typename T, size_t Alignment>
struct AlignedAllocator {
  using value_type = T;

  AlignedAllocator() noexcept = default;

  template <typename U>
  AlignedAllocator(const AlignedAllocator<U, Alignment> &) noexcept {}

  [[nodiscard]] T *allocate(std::size_t n) {
    if (n > std::size_t(-1) / sizeof(T)) {
      throw std::bad_array_new_length();
    }
    void *ptr = nullptr;
    size_t bytes = n * sizeof(T);
    if (bytes == 0) {
      return nullptr;
    }
    if (::posix_memalign(&ptr, Alignment, bytes) != 0 || ptr == nullptr) {
      throw std::bad_alloc();
    }
    return static_cast<T *>(ptr);
  }

  void deallocate(T *ptr, std::size_t) noexcept {
    std::free(ptr);
  }

  template <typename U>
  struct rebind {
    using other = AlignedAllocator<U, Alignment>;
  };
};

template <typename T, typename U, size_t Alignment>
bool operator==(const AlignedAllocator<T, Alignment> &,
                const AlignedAllocator<U, Alignment> &) {
  return true;
}

template <typename T, typename U, size_t Alignment>
bool operator!=(const AlignedAllocator<T, Alignment> &,
                const AlignedAllocator<U, Alignment> &) {
  return false;
}

using DmaBuffer = std::vector<uint8_t, AlignedAllocator<uint8_t, DMA_BUFFER_ALIGNMENT>>;

struct Chunk {
  DmaBuffer data;
  uint64_t packets = 0;
};

struct BlockInfo {
  uint64_t id = 0;
  uint64_t lane = 0;
  fs::path path;
  uint64_t bytes = 0;
  uint64_t packets = 0;
  uint64_t first_packet = 0;
};

struct WriteJob {
  std::future<void> future;
  uint64_t begin = 0;
  uint64_t bytes = 0;
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

static uint64_t read_mem_available_bytes() {
  std::ifstream file("/proc/meminfo");
  std::string key;
  uint64_t value_kb = 0;
  std::string unit;
  while (file >> key >> value_kb >> unit) {
    if (key == "MemAvailable:") {
      return value_kb * 1024ULL;
    }
  }
  return 0;
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
      << "       " << argv0 << " --stream stream.bin [options]\n"
      << "       " << argv0 << " --stripe-manifest block_manifest.json [options]\n\n"
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
      << "  --queue-depth N            producer queue depth, default 4; striped default 128\n"
      << "  --writer-threads N         parallel H2C pwrite workers, default 1; striped default 4\n"
      << "  --reader-threads N         parallel striped block readers, default 16\n"
      << "  --reader-window-blocks N   striped read-ahead window, default auto\n"
      << "  --block-list PATH          TSV block list for striped input\n"
      << "  --host-cache-bytes BYTES|auto\n"
      << "                              grow producer queue to use host DRAM as SSD cache\n"
      << "  --host-cache-fraction F    auto cache fraction of MemAvailable, default 0.85\n"
      << "  --poll-interval SEC        default 0.0002\n"
      << "  --timeout SEC              wait timeout, default 60\n"
      << "  --feed-timeout SEC         default --timeout\n"
      << "  --watermark BYTES          default 4096\n"
      << "  --rate-q16-16 VALUE        default 0x10000\n"
      << "  --start-time TICKS         default 0\n"
      << "  --force-link-up\n"
      << "  --force-tx-ready\n"
      << "  --no-wait\n"
      << "  --dry-run                  read/reorder source only; do not touch XDMA/BAR\n";
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
    } else if (key == "--stripe-manifest") {
      args.stripe_manifest = need_value("--stripe-manifest");
    } else if (key == "--block-list") {
      args.block_list = need_value("--block-list");
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
      args.queue_depth_set = true;
    } else if (key == "--writer-threads") {
      args.writer_threads = static_cast<size_t>(int_auto(need_value("--writer-threads")));
      args.writer_threads_set = true;
    } else if (key == "--reader-threads") {
      args.reader_threads = static_cast<size_t>(int_auto(need_value("--reader-threads")));
      args.reader_threads_set = true;
    } else if (key == "--reader-window-blocks") {
      args.reader_window_blocks = static_cast<size_t>(int_auto(need_value("--reader-window-blocks")));
      args.reader_window_blocks_set = true;
    } else if (key == "--host-cache-bytes") {
      args.host_cache_arg = need_value("--host-cache-bytes");
    } else if (key == "--host-cache-fraction") {
      args.host_cache_fraction = std::stod(need_value("--host-cache-fraction"));
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
    } else if (key == "--dry-run") {
      args.dry_run = true;
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
  if (args.writer_threads == 0) {
    throw std::runtime_error("--writer-threads must be positive");
  }
  if (!args.stripe_manifest.empty() || !args.block_list.empty()) {
    if (!args.reader_threads_set && args.reader_threads == 0) {
      args.reader_threads = 16;
    }
    if (!args.queue_depth_set) {
      args.queue_depth = std::max<size_t>(args.queue_depth, 128);
    }
    if (!args.writer_threads_set) {
      args.writer_threads = std::max<size_t>(args.writer_threads, 4);
    }
    if (!args.reader_window_blocks_set && args.reader_window_blocks == 0) {
      args.reader_window_blocks = std::max<size_t>(args.queue_depth, args.reader_threads * 8);
    }
  }
  if (args.read_bytes == 0) {
    args.read_bytes = args.batch_bytes;
  }
  if (args.feed_timeout == 0.0) {
    args.feed_timeout = args.timeout;
  }
  if (args.host_cache_fraction <= 0.0 || args.host_cache_fraction > 0.95) {
    throw std::runtime_error("--host-cache-fraction must be in (0, 0.95]");
  }
  return args;
}

static void resolve_host_cache(Args &args) {
  if (args.host_cache_arg.empty()) {
    return;
  }

  uint64_t requested = 0;
  if (args.host_cache_arg == "auto" || args.host_cache_arg == "all") {
    uint64_t available = read_mem_available_bytes();
    if (available == 0) {
      throw std::runtime_error("cannot read MemAvailable for --host-cache-bytes auto");
    }
    requested = static_cast<uint64_t>(static_cast<long double>(available) * args.host_cache_fraction);
  } else {
    requested = int_auto(args.host_cache_arg);
  }

  if (requested < args.read_bytes) {
    requested = args.read_bytes;
  }

  uint64_t depth64 = (requested + args.read_bytes - 1) / args.read_bytes;
  static constexpr uint64_t MAX_QUEUE_DEPTH = 65536;
  depth64 = std::min<uint64_t>(depth64, MAX_QUEUE_DEPTH);
  args.queue_depth = std::max<size_t>(args.queue_depth, static_cast<size_t>(depth64));
  args.host_cache_bytes = requested;
  args.host_cache_effective_bytes = static_cast<uint64_t>(args.queue_depth) * args.read_bytes;
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
  uint64_t packet_count = find_json_uint(text, "packet_count");
  uint64_t frame_len = find_json_uint(text, "frame_len");
  uint64_t stream_bytes = find_json_uint(text, "stream_bytes");
  if (packet_count != 0 && frame_len != 0) {
    uint64_t record_len = DATA_BEAT_BYTES + align_up(frame_len, DATA_BEAT_BYTES);
    if (stream_bytes == 0 || stream_bytes == packet_count * record_len) {
      args.fixed_frame_len = frame_len;
      args.fixed_record_len = record_len;
    }
  }
  return packet_count;
}

static std::string trim_copy(const std::string &text) {
  size_t begin = 0;
  while (begin < text.size() && std::isspace(static_cast<unsigned char>(text[begin]))) {
    ++begin;
  }
  size_t end = text.size();
  while (end > begin && std::isspace(static_cast<unsigned char>(text[end - 1]))) {
    --end;
  }
  return text.substr(begin, end - begin);
}

static std::vector<std::string> split_tabs(const std::string &line) {
  std::vector<std::string> fields;
  size_t start = 0;
  while (start <= line.size()) {
    size_t tab = line.find('\t', start);
    if (tab == std::string::npos) {
      fields.push_back(line.substr(start));
      break;
    }
    fields.push_back(line.substr(start, tab - start));
    start = tab + 1;
  }
  return fields;
}

static fs::path resolve_relative(const fs::path &base_file, const fs::path &path) {
  if (path.is_absolute()) {
    return path;
  }
  return base_file.parent_path() / path;
}

static std::vector<BlockInfo> load_block_list_tsv(const fs::path &path) {
  std::ifstream file(path);
  if (!file) {
    throw std::runtime_error("cannot open block list: " + path.string());
  }

  std::vector<BlockInfo> blocks;
  std::string line;
  bool saw_header = false;
  while (std::getline(file, line)) {
    line = trim_copy(line);
    if (line.empty() || line[0] == '#') {
      continue;
    }
    std::vector<std::string> fields = split_tabs(line);
    if (!saw_header) {
      saw_header = true;
      if (!fields.empty() && fields[0] == "block_id") {
        continue;
      }
    }
    if (fields.size() < 6) {
      throw std::runtime_error("bad block list line: " + line);
    }

    BlockInfo block;
    block.id = int_auto(fields[0]);
    block.lane = int_auto(fields[1]);
    block.path = resolve_relative(path, fs::path(fields[2]));
    block.bytes = int_auto(fields[3]);
    block.packets = int_auto(fields[4]);
    block.first_packet = int_auto(fields[5]);
    if (block.bytes == 0 || (block.bytes % DATA_BEAT_BYTES) != 0) {
      throw std::runtime_error("block bytes must be a positive 64-byte multiple: " + line);
    }
    if (block.packets == 0) {
      throw std::runtime_error("block packets must be positive: " + line);
    }
    blocks.push_back(std::move(block));
  }

  std::sort(blocks.begin(), blocks.end(),
            [](const BlockInfo &a, const BlockInfo &b) { return a.id < b.id; });
  for (size_t idx = 0; idx < blocks.size(); ++idx) {
    if (blocks[idx].id != idx) {
      throw std::runtime_error("block IDs must be contiguous starting at zero");
    }
  }
  return blocks;
}

static uint64_t load_stripe_manifest(Args &args, std::vector<BlockInfo> &blocks) {
  uint64_t packet_count = 0;
  if (!args.stripe_manifest.empty()) {
    std::string text = read_text_file(args.stripe_manifest);
    packet_count = find_json_uint(text, "packet_count");
    if (args.block_list.empty()) {
      std::string block_list_file = find_json_string(text, "block_list_file");
      if (block_list_file.empty()) {
        throw std::runtime_error("stripe manifest has no block_list_file");
      }
      args.block_list = resolve_relative(args.stripe_manifest, fs::path(block_list_file));
    }
  }
  if (args.block_list.empty()) {
    throw std::runtime_error("--block-list is required without --stripe-manifest");
  }

  blocks = load_block_list_tsv(args.block_list);
  if (blocks.empty()) {
    throw std::runtime_error("block list is empty");
  }

  uint64_t sum_packets = 0;
  for (const BlockInfo &block : blocks) {
    sum_packets += block.packets;
  }
  if (packet_count == 0) {
    packet_count = sum_packets;
  } else if (packet_count != sum_packets) {
    throw std::runtime_error("stripe manifest packet_count does not match block list");
  }
  return packet_count;
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

static uint32_t check_stream_status(int user_fd, uint64_t base) {
  uint32_t status = read32(user_fd, base + REG_STREAM_STATUS);
  uint32_t fatal = STREAM_STATUS_ERROR | STREAM_STATUS_OVERRUN | STREAM_STATUS_PTR_ERROR;
  if ((status & fatal) != 0) {
    std::ostringstream oss;
    oss << "FPGA stream ring error: status=0x" << std::hex << std::setw(8)
        << std::setfill('0') << status;
    throw std::runtime_error(oss.str());
  }
  if (status != 0 && (status & STREAM_STATUS_RING_MODE) == 0) {
    std::ostringstream oss;
    oss << "FPGA stream reader is not in ring mode: status=0x" << std::hex
        << std::setw(8) << std::setfill('0') << status;
    throw std::runtime_error(oss.str());
  }
  if (status != 0 && (status & STREAM_STATUS_SIZE_VALID) == 0) {
    std::ostringstream oss;
    oss << "FPGA stream ring size is invalid: status=0x" << std::hex
        << std::setw(8) << std::setfill('0') << status;
    throw std::runtime_error(oss.str());
  }
  return status;
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

    DmaBuffer carry;
    uint64_t total_packets = 0;
    uint64_t total_bytes = 0;

    while (true) {
      DmaBuffer data;
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
      if (args.fixed_record_len != 0) {
        pos = data.size() / static_cast<size_t>(args.fixed_record_len) *
              static_cast<size_t>(args.fixed_record_len);
        packets = pos / args.fixed_record_len;
      } else {
        while (data.size() - pos >= DATA_BEAT_BYTES) {
          uint16_t frame_len = load_le16(data.data() + pos + 12);
          uint64_t record_len = DATA_BEAT_BYTES + align_up(frame_len, DATA_BEAT_BYTES);
          if (data.size() - pos < record_len) {
            break;
          }
          pos += static_cast<size_t>(record_len);
          ++packets;
        }
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

class StripedReadState {
 public:
  StripedReadState(const std::vector<BlockInfo> &blocks, size_t window_blocks)
      : blocks_(blocks), window_blocks_(std::max<size_t>(1, window_blocks)),
        max_completed_(std::max<size_t>(1, window_blocks)) {}

  bool get_work(BlockInfo &block) {
    std::unique_lock<std::mutex> lock(mutex_);
    cv_work_.wait(lock, [&] {
      return error_ || next_assign_ >= blocks_.size() ||
             next_assign_ < next_emit_ + window_blocks_;
    });
    if (error_ || next_assign_ >= blocks_.size()) {
      return false;
    }
    block = blocks_[next_assign_++];
    return true;
  }

  void submit(uint64_t id, Chunk &&chunk) {
    std::unique_lock<std::mutex> lock(mutex_);
    cv_space_.wait(lock, [&] {
      return error_ || completed_.size() < max_completed_ || id == next_emit_;
    });
    if (error_) {
      return;
    }
    completed_.emplace(id, std::move(chunk));
    cv_emit_.notify_all();
  }

  bool pop_next(Chunk &chunk) {
    std::unique_lock<std::mutex> lock(mutex_);
    cv_emit_.wait(lock, [&] {
      return error_ || next_emit_ >= blocks_.size() ||
             completed_.find(next_emit_) != completed_.end();
    });
    if (error_) {
      std::rethrow_exception(error_);
    }
    if (next_emit_ >= blocks_.size()) {
      return false;
    }
    auto it = completed_.find(next_emit_);
    chunk = std::move(it->second);
    completed_.erase(it);
    ++next_emit_;
    cv_space_.notify_all();
    cv_work_.notify_all();
    return true;
  }

  void fail(std::exception_ptr error) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (!error_) {
        error_ = error;
      }
    }
    cv_work_.notify_all();
    cv_emit_.notify_all();
    cv_space_.notify_all();
  }

 private:
  const std::vector<BlockInfo> &blocks_;
  size_t window_blocks_;
  size_t max_completed_;
  size_t next_assign_ = 0;
  size_t next_emit_ = 0;
  std::map<uint64_t, Chunk> completed_;
  std::exception_ptr error_;
  std::mutex mutex_;
  std::condition_variable cv_work_;
  std::condition_variable cv_emit_;
  std::condition_variable cv_space_;
};

static void striped_reader_worker(StripedReadState &state) {
  try {
    BlockInfo block;
    while (state.get_work(block)) {
      int fd = ::open(block.path.c_str(), O_RDONLY);
      if (fd < 0) {
        throw std::runtime_error("cannot open stream block: " + block.path.string());
      }
      (void)::posix_fadvise(fd, 0, 0, POSIX_FADV_SEQUENTIAL);

      Chunk chunk;
      chunk.data.resize(static_cast<size_t>(block.bytes));
      chunk.packets = block.packets;
      try {
        read_all_at(fd, chunk.data.data(), chunk.data.size(), 0);
      } catch (...) {
        ::close(fd);
        throw;
      }
      ::close(fd);
      state.submit(block.id, std::move(chunk));
    }
  } catch (...) {
    state.fail(std::current_exception());
  }
}

static void striped_producer_thread(const Args &args,
                                    const std::vector<BlockInfo> &blocks,
                                    ChunkQueue &queue,
                                    std::atomic<uint64_t> &parsed_packets,
                                    std::atomic<uint64_t> &parsed_bytes,
                                    std::exception_ptr &producer_error) {
  size_t readers = args.reader_threads ? args.reader_threads : 2;
  size_t window = args.reader_window_blocks;
  if (window == 0) {
    window = std::max<size_t>(args.queue_depth, readers * 2);
  }
  window = std::max<size_t>(window, readers);

  StripedReadState state(blocks, window);
  std::vector<std::thread> reader_threads;
  reader_threads.reserve(readers);

  try {
    for (size_t idx = 0; idx < readers; ++idx) {
      reader_threads.emplace_back(striped_reader_worker, std::ref(state));
    }

    uint64_t total_packets = 0;
    uint64_t total_bytes = 0;
    Chunk chunk;
    while (state.pop_next(chunk)) {
      total_packets += chunk.packets;
      total_bytes += chunk.data.size();
      parsed_packets.store(total_packets, std::memory_order_relaxed);
      parsed_bytes.store(total_bytes, std::memory_order_relaxed);
      queue.push(std::move(chunk));
    }

    for (std::thread &thread : reader_threads) {
      if (thread.joinable()) {
        thread.join();
      }
    }
  } catch (...) {
    producer_error = std::current_exception();
    state.fail(producer_error);
    for (std::thread &thread : reader_threads) {
      if (thread.joinable()) {
        thread.join();
      }
    }
  }
  queue.finish();
}

int main(int argc, char **argv) {
  try {
    Args args = parse_args(argc, argv);
    std::vector<BlockInfo> stripe_blocks;
    bool striped_source = !args.stripe_manifest.empty() || !args.block_list.empty();
    uint64_t manifest_packets = striped_source ? load_stripe_manifest(args, stripe_blocks)
                                               : load_manifest(args);
    if (!striped_source && args.stream.empty()) {
      usage(argv[0]);
      throw std::runtime_error("--stream, --manifest, or --stripe-manifest is required");
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
    resolve_host_cache(args);

    uint64_t prefill = args.prefill_bytes;
    if (prefill == 0) {
      prefill = std::min<uint64_t>(args.ring_size / 2, 64ULL << 20);
    }
    prefill = std::max<uint64_t>(DATA_BEAT_BYTES, std::min(prefill, args.ring_size - args.guard_bytes));
    uint64_t base = reg_base_for_port(args);

    auto start_producer = [&](ChunkQueue &queue,
                              std::atomic<uint64_t> &parsed_packets,
                              std::atomic<uint64_t> &parsed_bytes,
                              std::exception_ptr &producer_error) {
      if (striped_source) {
        return std::thread(striped_producer_thread, std::cref(args), std::cref(stripe_blocks),
                           std::ref(queue), std::ref(parsed_packets),
                           std::ref(parsed_bytes), std::ref(producer_error));
      }
      return std::thread(producer_thread, std::cref(args), std::ref(queue),
                         std::ref(parsed_packets), std::ref(parsed_bytes),
                         std::ref(producer_error));
    };

    if (args.dry_run) {
      ChunkQueue queue(args.queue_depth);
      std::atomic<uint64_t> parsed_packets{0};
      std::atomic<uint64_t> parsed_bytes{0};
      std::exception_ptr producer_error;
      auto t0 = std::chrono::steady_clock::now();
      std::thread producer = start_producer(queue, parsed_packets, parsed_bytes, producer_error);

      uint64_t chunks = 0;
      uint64_t bytes = 0;
      uint64_t packets = 0;
      Chunk chunk;
      while (queue.pop(chunk)) {
        ++chunks;
        bytes += chunk.data.size();
        packets += chunk.packets;
      }
      if (producer.joinable()) {
        producer.join();
      }
      if (producer_error) {
        std::rethrow_exception(producer_error);
      }
      if (manifest_packets != 0 && manifest_packets != packets) {
        throw std::runtime_error("manifest packet_count mismatch: expected " +
                                 std::to_string(manifest_packets) + " parsed " +
                                 std::to_string(packets));
      }
      double seconds = std::chrono::duration<double>(
          std::chrono::steady_clock::now() - t0).count();
      double read_gbps = seconds > 0.0 ? static_cast<double>(bytes) * 8.0 / seconds / 1e9 : 0.0;
      std::cout << std::boolalpha;
      std::cout << "dry_run           : true\n";
      std::cout << "source_mode       : " << (striped_source ? "striped" : "stream") << "\n";
      if (striped_source) {
        std::cout << "stripe_manifest   : " << args.stripe_manifest << "\n";
        std::cout << "block_list        : " << args.block_list << "\n";
        std::cout << "block_count       : " << stripe_blocks.size() << "\n";
        std::cout << "reader_threads    : " << args.reader_threads << "\n";
        std::cout << "reader_window     : "
                  << (args.reader_window_blocks ? args.reader_window_blocks
                                                : std::max<size_t>(args.queue_depth, args.reader_threads * 2))
                  << "\n";
      } else {
        std::cout << "stream_file       : " << args.stream << "\n";
      }
      std::cout << "chunks            : " << chunks << "\n";
      std::cout << "committed_bytes   : " << bytes << "\n";
      std::cout << "committed_packets : " << packets << "\n";
      std::cout << std::fixed << std::setprecision(3);
      std::cout << "read_gbps         : " << read_gbps << "\n";
      std::cout << std::setprecision(6);
      std::cout << "read_seconds      : " << seconds << "\n";
      return 0;
    }

    std::vector<int> h2c_fds;
    h2c_fds.reserve(args.writer_threads);
    for (size_t idx = 0; idx < args.writer_threads; ++idx) {
      int fd = ::open(args.h2c.c_str(), O_WRONLY);
      if (fd < 0) {
        for (int old_fd : h2c_fds) {
          ::close(old_fd);
        }
        throw std::runtime_error("cannot open H2C device: " + args.h2c);
      }
      h2c_fds.push_back(fd);
    }
    int user_fd = ::open(args.user.c_str(), O_RDWR);
    if (user_fd < 0) {
      for (int fd : h2c_fds) {
        ::close(fd);
      }
      throw std::runtime_error("cannot open user BAR device: " + args.user);
    }

    ChunkQueue queue(args.queue_depth);
    std::atomic<uint64_t> parsed_packets{0};
    std::atomic<uint64_t> parsed_bytes{0};
    std::exception_ptr producer_error;
    std::thread producer = start_producer(queue, parsed_packets, parsed_bytes, producer_error);

    bool started = false;
    uint64_t write_count = 0;
    uint64_t reserved_count = 0;
    uint64_t packet_count = 0;
    uint64_t max_level = 0;
    uint64_t min_free = args.ring_size;
    size_t next_writer = 0;
    std::deque<WriteJob> write_jobs;
    auto load_start = std::chrono::steady_clock::now();
    bool completed = false;
    double wall_seconds = 0.0;

    try {
      configure(user_fd, base, args);

      auto commit_ready_jobs = [&](bool wait_front) {
        while (!write_jobs.empty()) {
          auto &job = write_jobs.front();
          if (!wait_front &&
              job.future.wait_for(std::chrono::seconds(0)) != std::future_status::ready) {
            break;
          }
          job.future.get();
          write_count = job.begin + job.bytes;
          packet_count += job.packets;
          write64(user_fd, base + REG_STREAM_WR_LO, base + REG_STREAM_WR_HI, write_count);
          if (!started && write_count >= prefill) {
            start_replay(user_fd, base);
            started = true;
          }
          write_jobs.pop_front();
          wait_front = false;
        }
      };

      Chunk chunk;
      while (queue.pop(chunk)) {
        if (chunk.data.size() + args.guard_bytes > args.ring_size) {
          throw std::runtime_error("producer chunk is too large for selected ring");
        }

        while (true) {
          commit_ready_jobs(false);
          double feed_elapsed = std::chrono::duration<double>(
              std::chrono::steady_clock::now() - load_start).count();
          if (args.feed_timeout > 0.0 && feed_elapsed > args.feed_timeout) {
            throw std::runtime_error("ring feed timeout after " + std::to_string(args.feed_timeout) + "s");
          }

          uint64_t read_count = read64(user_fd, base + REG_STREAM_RD_LO, base + REG_STREAM_RD_HI);
          (void)check_stream_status(user_fd, base);
          if (read_count > write_count) {
            throw std::runtime_error("FPGA read pointer advanced past host write pointer");
          }
          uint64_t level = reserved_count - read_count;
          uint64_t free = args.ring_size - level - args.guard_bytes;
          max_level = std::max(max_level, level);
          min_free = std::min(min_free, free);

          if (free >= chunk.data.size() && write_jobs.size() < args.writer_threads) {
            uint64_t job_begin = reserved_count;
            uint64_t job_bytes = chunk.data.size();
            uint64_t job_packets = chunk.packets;
            int job_fd = h2c_fds[next_writer++ % h2c_fds.size()];
            DmaBuffer job_data = std::move(chunk.data);
            reserved_count += job_bytes;
            write_jobs.push_back(WriteJob{
                std::async(std::launch::async,
                           [job_fd, data = std::move(job_data), ring_base = args.ring_base,
                            ring_size = args.ring_size, job_begin]() {
                             pwrite_ring(job_fd, data.data(), data.size(),
                                         ring_base, ring_size, job_begin);
                           }),
                job_begin,
                job_bytes,
                job_packets});
            break;
          }

          if (!write_jobs.empty()) {
            commit_ready_jobs(true);
            continue;
          }

          if (!started && write_count != 0) {
            start_replay(user_fd, base);
            started = true;
          } else {
            std::this_thread::sleep_for(std::chrono::duration<double>(args.poll_interval));
          }
        }
      }

      if (producer.joinable()) {
        producer.join();
      }
      if (producer_error) {
        std::rethrow_exception(producer_error);
      }
      while (!write_jobs.empty()) {
        commit_ready_jobs(true);
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
      std::cout << "source_mode       : " << (striped_source ? "striped" : "stream") << "\n";
      if (striped_source) {
        std::cout << "stripe_manifest   : " << args.stripe_manifest << "\n";
        std::cout << "block_list        : " << args.block_list << "\n";
        std::cout << "block_count       : " << stripe_blocks.size() << "\n";
        std::cout << "reader_threads    : " << args.reader_threads << "\n";
        std::cout << "reader_window     : "
                  << (args.reader_window_blocks ? args.reader_window_blocks
                                                : std::max<size_t>(args.queue_depth, args.reader_threads * 2))
                  << "\n";
      } else {
        std::cout << "stream_file       : " << args.stream << "\n";
      }
      if (args.fixed_record_len != 0) {
        std::cout << "fixed_frame_len   : " << args.fixed_frame_len << "\n";
        std::cout << "fixed_record_len  : " << args.fixed_record_len << "\n";
      }
      std::cout << "ring_base         : 0x" << std::hex << args.ring_base << std::dec << "\n";
      std::cout << "ring_size         : " << args.ring_size << "\n";
      std::cout << "read_bytes        : " << args.read_bytes << "\n";
      std::cout << "queue_depth       : " << args.queue_depth << "\n";
      std::cout << "writer_threads    : " << args.writer_threads << "\n";
      std::cout << "dma_buffer_align  : " << DMA_BUFFER_ALIGNMENT << "\n";
      if (args.host_cache_bytes != 0) {
        std::cout << "host_cache_target : " << args.host_cache_bytes << "\n";
        std::cout << "host_cache_window : " << args.host_cache_effective_bytes << "\n";
      }
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
      for (int fd : h2c_fds) {
        ::close(fd);
      }
      ::close(user_fd);
      throw;
    }

    for (int fd : h2c_fds) {
      ::close(fd);
    }
    ::close(user_fd);
    return 0;
  } catch (const std::exception &e) {
    std::cerr << "ERROR: " << e.what() << "\n";
    return 1;
  }
}
