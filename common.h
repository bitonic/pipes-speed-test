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
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define NOINLINE __attribute__((noinline))
#define UNUSED __attribute__((unused))

#define PAGE_SHIFT 12
#define HPAGE_SHIFT 21

#define PAGE_SIZE (1 << PAGE_SHIFT)
#define HPAGE_SIZE (1 << HPAGE_SHIFT)

#define fail(...) do { fprintf(stderr, __VA_ARGS__); exit(EXIT_FAILURE); } while (false)

struct Options {
  // Whether to busy loop on syscalls with non blocking, or whether to block.
  bool busy_loop = false;
  bool poll = false;
  // Whether to allocate the buffers in a huge page
  bool huge_page = false;
  // How big should the buffer be
  size_t buf_size = 1 << 17;
  bool write_with_vmsplice = false;
  bool read_with_splice = false;
  // Whether pages should be gifted (and then moved if with READ_WITH_SPLICE) to
  // vmsplice
  bool gift = false;
  // Bytes to pipe
  size_t bytes_to_pipe = 1 << 30;
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

static void parse_options(int argc, char** argv, Options& options) {
  struct option long_options[] = {
    { "busy_loop",           no_argument,       0, 0 },
    { "poll",                no_argument,       0, 0 },
    { "huge_page",           no_argument,       0, 0 },
    { "buf_size",            required_argument, 0, 0 },
    { "write_with_vmsplice", no_argument,       0, 0 },
    { "read_with_splice",    no_argument,       0, 0 },
    { "gift",                no_argument,       0, 0 },
    { "bytes_to_pipe",       required_argument, 0, 0 },
    { 0,                     0,                 0, 0 }
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
      options.write_with_vmsplice =
        options.write_with_vmsplice || (strcmp("write_with_vmsplice", option) == 0);
      options.read_with_splice =
        options.read_with_splice || (strcmp("read_with_splice", option) == 0);
      options.gift = options.gift || (strcmp("gift", option) == 0);
      if (strcmp("buf_size", option) == 0) {
        options.buf_size = read_size_str(optarg);
      }
      if (strcmp("bytes_to_pipe", option) == 0) {
        options.bytes_to_pipe = read_size_str(optarg);
      }
    } else {
      fail("getopt returned character code 0%o\n", c);
    }
  }

  const auto bool_str = [](const bool b) {
    if (b) { return "true"; }
    else { return "false"; }
  };
  fprintf(stderr, "busy_loop\t\t%s\n", bool_str(options.busy_loop));
  fprintf(stderr, "poll\t\t\t%s\n", bool_str(options.poll));
  fprintf(stderr, "huge_page\t\t%s\n", bool_str(options.huge_page));
  fprintf(stderr, "buf_size\t\t%zu\n", options.buf_size);
  fprintf(stderr, "write_with_vmsplice\t%s\n", bool_str(options.write_with_vmsplice));
  fprintf(stderr, "read_with_splice\t%s\n", bool_str(options.read_with_splice));
  fprintf(stderr, "gift\t\t\t%s\n", bool_str(options.gift));
  fprintf(stderr, "bytes_to_pipe\t\t%zu\n", options.bytes_to_pipe);
  fprintf(stderr, "\n");
}

#define PAGEMAP_PRESENT(ent) (((ent) & (1ull << 63)) != 0)
#define PAGEMAP_PFN(ent) ((ent) & ((1ull << 55) - 1))

static void check_huge_page(void* ptr) {
  // *(volatile void **)ptr = ptr;

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
}

static char* allocate_buf(const Options& options) {
  void* buf = NULL;
  if (options.huge_page) {
    size_t sz = HPAGE_SIZE > options.buf_size ? HPAGE_SIZE : options.buf_size;
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
  // fill the buffer with 0s so that we know it's printable stuff
  // we also need to do that to actually allocate the huge page
  // and have check_huge_page to work. which is why we do
  // check_huge_page afterwards.
  memset((void *) buf, options.buf_size, '0');
  if (options.huge_page) {
    check_huge_page(buf);
  }
  return (char *) buf;
}
