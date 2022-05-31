#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <linux/kernel-page-flags.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <linux/perf_event.h>
#include <asm/unistd.h>
#include <sys/ioctl.h>
#include <signal.h>

#define NOINLINE __attribute__((noinline))
#define UNUSED __attribute__((unused))

#define PAGE_SHIFT 12
#define HPAGE_SHIFT 21

#define PAGE_SIZE (1 << PAGE_SHIFT)
#define HPAGE_SIZE (1 << HPAGE_SHIFT)

#define fail(...) do { fprintf(stderr, __VA_ARGS__); exit(EXIT_FAILURE); } while (false)

static bool verbose = false;

#define log(...) if (verbose) { fprintf(stderr, __VA_ARGS__); }

struct Options {
  // Whether to busy loop on syscalls with non blocking, or whether to block.
  bool busy_loop = false;
  bool poll = false;
  // Whether to allocate the buffers in a huge page
  bool huge_page = false;
  bool check_huge_page = false;
  // How big should the buffer be
  size_t buf_size = 1 << 18;
  bool write_with_vmsplice = false;
  bool read_with_splice = false;
  // Whether pages should be gifted (and then moved if with READ_WITH_SPLICE) to
  // vmsplice
  bool gift = false;
  // Lock pages to ensure that they aren't reclaimed
  bool lock_memory = false;
  // Don't fault pages in before we start piping
  bool dont_touch_pages = false;
  // Use a single, contiguous buffer, rather than two page-aligned ones.
  // This increases page table contention, as the author of fizzbuzz notes,
  // for a ~20% slowdown.
  bool same_buffer = false;
  // Output CSV rather than human readable
  bool csv = false;
  // Bytes to pipe (10GiB)
  size_t bytes_to_pipe = (1ull << 30) * 10ull;
  // Pipe size. If 0, the size will not be set. If we're using vmsplice, the
  // buffer size will be automatically determined, and setting it here is an
  // error.
  size_t pipe_size = 0;
};

static size_t read_size_str(const char* str) {
  size_t sz;
  char control;
  int matched = sscanf(str, "%zu%c", &sz, &control);
  if (matched == 1) {
    // no-op -- it's bytes
  } else if (matched == 2 && control == 'G') {
    sz = sz << 30;
  } else if (matched == 2 && control == 'M') {
    sz = sz << 20;
  } else if (matched == 2 && control == 'K') {
    sz = sz << 10;
  } else {
    fail("bad size specification %s\n", str);
  }
  return sz;
}

UNUSED
static void write_size_str(size_t x, char* buf) {
  if ((x & ((1 << 30)-1)) == 0) {
    sprintf(buf, "%zuGiB", x >> 30);
  } else if ((x & ((1 << 20)-1)) == 0) {
    sprintf(buf, "%zuMiB", x >> 20);
  } else if ((x & ((1 << 10)-1)) == 0) {
    sprintf(buf, "%zuKiB", x >> 10);
  } else {
    sprintf(buf, "%zuB", x);
  }
}

static void parse_options(int argc, char** argv, Options& options) {
  struct option long_options[] = {
    { "verbose",              no_argument,       0, 0 },
    { "busy_loop",            no_argument,       0, 0 },
    { "poll",                 no_argument,       0, 0 },
    { "huge_page",            no_argument,       0, 0 },
    { "check_huge_page",      no_argument,       0, 0 },
    { "buf_size",             required_argument, 0, 0 },
    { "write_with_vmsplice",  no_argument,       0, 0 },
    { "read_with_splice",     no_argument,       0, 0 },
    { "gift",                 no_argument,       0, 0 },
    { "bytes_to_pipe",        required_argument, 0, 0 },
    { "pipe_size",            required_argument, 0, 0 },
    { "lock_memory",          no_argument,       0, 0 },
    { "dont_touch_pages",     no_argument,       0, 0 },
    { "same_buffer",          no_argument,       0, 0 },
    { "csv",                  no_argument,       0, 0 },
    { 0,                      0,                 0, 0 }
  };

  opterr = 0; // we handle errors ourselves
  while (true) {
    int option_index;
    int c = getopt_long(argc, argv, "", long_options, &option_index);
    if (c == -1) {
      break;
    } else if (c == '?') {
      optind--; // we want to print the one we just skipped over as well
      fprintf(stderr, "bad usage, non-option arguments starting from:\n  ");
      while (optind < argc) {
        fprintf(stderr, "%s ", argv[optind++]);
      }
      fprintf(stderr, "\n");
      exit(EXIT_FAILURE);
    } else if (c == 0) {
      const char* option = long_options[option_index].name;
      options.busy_loop = options.busy_loop || (strcmp("busy_loop", option) == 0);
      options.poll = options.poll || (strcmp("poll", option) == 0);
      options.huge_page = options.huge_page || (strcmp("huge_page", option) == 0);
      options.check_huge_page = options.check_huge_page || (strcmp("check_huge_page", option) == 0);
      options.write_with_vmsplice =
        options.write_with_vmsplice || (strcmp("write_with_vmsplice", option) == 0);
      options.read_with_splice =
        options.read_with_splice || (strcmp("read_with_splice", option) == 0);
      verbose = verbose || (strcmp("verbose", option) == 0);
      options.gift = options.gift || (strcmp("gift", option) == 0);
      options.lock_memory = options.lock_memory || (strcmp("lock_memory", option) == 0);
      options.dont_touch_pages = options.dont_touch_pages || (strcmp("dont_touch_pages", option) == 0);
      options.same_buffer = options.same_buffer || (strcmp("same_buffer", option) == 0);
      options.csv = options.csv || (strcmp("csv", option) == 0);
      if (strcmp("buf_size", option) == 0) {
        options.buf_size = read_size_str(optarg);
      }
      if (strcmp("bytes_to_pipe", option) == 0) {
        options.bytes_to_pipe = read_size_str(optarg);
      }
      if (strcmp("pipe_size", option) == 0) {
        options.pipe_size = read_size_str(optarg);
      }
    } else {
      fail("getopt returned character code 0%o\n", c);
    }
  }

  if (options.dont_touch_pages && options.check_huge_page) {
    fail("--dont_touch_pages and --check_huge_page are incompatible -- we can't the huge pages if we don't fault them in first.\n");
  }

  const auto bool_str = [](const bool b) {
    if (b) { return "true"; }
    else { return "false"; }
  };
  log("busy_loop\t\t%s\n", bool_str(options.busy_loop));
  log("poll\t\t\t%s\n", bool_str(options.poll));
  log("huge_page\t\t%s\n", bool_str(options.huge_page));
  log("check_huge_page\t\t%s\n", bool_str(options.check_huge_page));
  log("buf_size\t\t%zu\n", options.buf_size);
  log("write_with_vmsplice\t%s\n", bool_str(options.write_with_vmsplice));
  log("read_with_splice\t%s\n", bool_str(options.read_with_splice));
  log("gift\t\t\t%s\n", bool_str(options.gift));
  log("lock_memory\t\t%s\n", bool_str(options.lock_memory));
  log("dont_touch_pages\t%s\n", bool_str(options.dont_touch_pages));
  log("same_buffer\t\t%s\n", bool_str(options.same_buffer));
  log("csv\t\t\t%s\n", bool_str(options.csv));
  log("bytes_to_pipe\t\t%zu\n", options.bytes_to_pipe);
  log("pipe_size\t\t%zu\n", options.pipe_size);
  log("\n");
}

#define PAGEMAP_PRESENT(ent) (((ent) & (1ull << 63)) != 0)
#define PAGEMAP_PFN(ent) ((ent) & ((1ull << 55) - 1))

static void check_huge_page(void* ptr) {
  if (prctl(PR_SET_DUMPABLE, 1, 0, 0) < 0) {
    fail("could not set the process as dumpable: %s", strerror(errno));
  }

  int pagemap_fd = open("/proc/self/pagemap", O_RDONLY);
  if (pagemap_fd < 0) {
    fail("could not open /proc/self/pagemap: %s", strerror(errno));
  }
  int kpageflags_fd = open("/proc/kpageflags", O_RDONLY);
  if (kpageflags_fd < 0) {
    fail("could not open /proc/kpageflags: %s", strerror(errno));
  }

  // each entry is 8 bytes long, so to get the offset in pagemap we need to
  // ptr / PAGE_SIZE * 8, or equivalently ptr >> (PAGE_SHIFT - 3)
  uint64_t ent;
  if (pread(pagemap_fd, &ent, sizeof(ent), ((uintptr_t) ptr) >> (PAGE_SHIFT - 3)) != sizeof(ent)) {
    fail("could not read from pagemap\n");
  }

  if (!PAGEMAP_PRESENT(ent)) {
    fail("page not present in /proc/self/pagemap, this should never happen\n");
  }
  if (!PAGEMAP_PFN(ent)) {
    fail("page frame number not present, run this program as root\n");
  }

  uint64_t flags;
  if (pread(kpageflags_fd, &flags, sizeof(flags), PAGEMAP_PFN(ent) << 3) != sizeof(flags)) {
    fail("could not read from kpageflags\n");
  }

  if (!(flags & (1ull << KPF_THP))) {
    fail("could not allocate huge page\n");
  }

  if (close(pagemap_fd) < 0) {
    fail("could not close /proc/self/pagemap: %s", strerror(errno));
  }
  if (close(kpageflags_fd) < 0) {
    fail("could not close /proc/kpageflags: %s", strerror(errno));
  }
}

NOINLINE UNUSED
static char* allocate_buf(const Options& options) {
  void* buf = NULL;
  if (options.huge_page) {
    // Round to hpage size, so we allocate only huge pages
    size_t sz = ((options.buf_size - 1) & ~(HPAGE_SIZE - 1)) + HPAGE_SIZE;
    buf = aligned_alloc(HPAGE_SIZE, sz);
    if (!buf) {
      fail("could not allocate aligned page: %s", strerror(errno));
    }
    if (madvise(buf, sz, MADV_HUGEPAGE) < 0) {
      fail("could not defrag memory: %s", strerror(errno));
    }
  } else {
    buf = malloc(options.buf_size);
  }
  if (!buf) {
    fail("could not allocate buffer\n");
  }
  if (options.lock_memory) {
    if (mlock(buf, options.buf_size) < 0) {
      fail("could not lock memory\n");
    }
  }
  // fill the buffer with Xs so that we know it's printable stuff
  // we also need to do that to actually allocate the huge page
  // and have check_huge_page to work. which is why we do
  // check_huge_page afterwards.
  if (!options.dont_touch_pages) {
    memset((void*) buf, 'X', options.buf_size);
  }
  if (options.huge_page && options.check_huge_page) {
    check_huge_page(buf);
  }
  return (char *) buf;
}

// perf instrumentation -- a mixture of man 2 perf_event_open and
// <https://stackoverflow.com/a/42092180>

UNUSED
static long
perf_event_open(struct perf_event_attr *hw_event, pid_t pid, int cpu, int group_fd, unsigned long flags) {
  int ret;
  ret = syscall(__NR_perf_event_open, hw_event, pid, cpu, group_fd, flags);
  return ret;
}

UNUSED
static void setup_perf_event(
  struct perf_event_attr *evt,
  int *fd,
  uint64_t *id,
  uint32_t evt_type,
  uint64_t evt_config,
  int group_fd
) {
  memset(evt, 0, sizeof(struct perf_event_attr));
  evt->type = evt_type;
  evt->size = sizeof(struct perf_event_attr);
  evt->config = evt_config;
  evt->disabled = 1;
  // We care especially about the kernel here
  evt->exclude_kernel = 0;
  evt->exclude_hv = 1;
  evt->read_format = PERF_FORMAT_GROUP | PERF_FORMAT_ID;

  *fd = perf_event_open(evt, 0, -1, group_fd, 0);
  if (*fd == -1) {
    fprintf(stderr, "Error opening leader %llx\n", evt->config);
    exit(EXIT_FAILURE);
  }

  ioctl(*fd, PERF_EVENT_IOC_ID, id);
}

static struct perf_event_attr perf_faults_evt;
static int perf_faults_fd;
static uint64_t perf_faults_id;

UNUSED
static void perf_init() {
  // page faults
  setup_perf_event(
    &perf_faults_evt, &perf_faults_fd, &perf_faults_id,
    PERF_TYPE_SOFTWARE, PERF_COUNT_SW_PAGE_FAULTS, -1
  );
}

UNUSED
static void perf_close() {
  close(perf_faults_fd);
}

UNUSED
static void disable_perf_count() {
  ioctl(perf_faults_fd, PERF_EVENT_IOC_DISABLE, PERF_IOC_FLAG_GROUP);
}

UNUSED
static void enable_perf_count() {
  ioctl(perf_faults_fd, PERF_EVENT_IOC_ENABLE, PERF_IOC_FLAG_GROUP);
}

UNUSED
static void reset_perf_count() {
  ioctl(perf_faults_fd, PERF_EVENT_IOC_RESET, PERF_IOC_FLAG_GROUP);
}

struct perf_read_value {
  uint64_t value;
  uint64_t id;
};

struct perf_read_format {
  uint64_t nr;
  struct perf_read_value values[];
};

static char perf_read_buf[4096];

struct perf_count {
  uint64_t faults;
};

UNUSED
static void read_perf_count(struct perf_count& count) {
  if (!read(perf_faults_fd, perf_read_buf, sizeof(perf_read_buf))) {
    fprintf(stderr, "Could not read faults from perf\n");
    exit(EXIT_FAILURE);
  }
  struct perf_read_format* rf = (struct perf_read_format *) perf_read_buf;
  if (rf->nr != 1) {
    fprintf(stderr, "Bad number of perf events\n");
    exit(EXIT_FAILURE);
  }
  for (uint64_t i = 0; i < rf->nr; i++) {
    struct perf_read_value *value = &rf->values[i];
    if (value->id == perf_faults_id) {
      count.faults = value->value;
    } else {
      fprintf(stderr, "Spurious value in perf read (%ld)\n", value->id);
      exit(EXIT_FAILURE);
    }
  }
}

UNUSED
static void log_perf_count() {
  struct perf_count count;
  read_perf_count(count);
  log("page faults: %ld\n", count.faults);
}
