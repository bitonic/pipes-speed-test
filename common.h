#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <linux/kernel-page-flags.h>
#include <poll.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define NOINLINE __attribute__((noinline))
#define UNUSED __attribute__((unused))

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
  size_t huge_page_size = 1 << 21;
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
    fprintf(stderr, "bad size specification %s\n", str);
    exit(EXIT_FAILURE);
  }
  return sz;
}

static void parse_options(int argc, char** argv, Options& options) {
  struct option long_options[] = {
    { "busy_loop",      no_argument,       0, 0 },
    { "poll",           no_argument,       0, 0 },
    { "huge_page",      no_argument,       0, 0 },
    { "buf_size",       required_argument, 0, 0 },
    { "write_vmsplice", no_argument,       0, 0 },
    { "read_splice",    no_argument,       0, 0 },
    { "gift",           no_argument,       0, 0 },
    { "bytes_to_pipe",  required_argument, 0, 0 },
    { 0,                0,                 0, 0 }
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
        options.write_with_vmsplice || (strcmp("write_vmsplice", option) == 0);
      options.read_with_splice = options.read_with_splice || (strcmp("read_splice", option) == 0);
      options.gift = options.gift || (strcmp("gift", option) == 0);
      if (strcmp("buf_size", option) == 0) {
        options.buf_size = read_size_str(optarg);
      }
      if (strcmp("bytes_to_pipe", option) == 0) {
        options.bytes_to_pipe = read_size_str(optarg);
      }
    } else {
      fprintf(stderr, "getopt returned character code 0%o\n", c);
      exit(EXIT_FAILURE);
    }
  }

  const auto bool_str = [](const bool b) {
    if (b) { return "true"; }
    else { return "false"; }
  };
  fprintf(stderr, "busy_loop\t\t%s\n", bool_str(options.busy_loop));
  fprintf(stderr, "poll\t\t\t%s\n", bool_str(options.poll));
  fprintf(stderr, "huge_page\t\t%s\n", bool_str(options.huge_page));
  fprintf(stderr, "huge_page_size\t\t%zu\n", options.huge_page_size);
  fprintf(stderr, "buf_size\t\t%zu\n", options.buf_size);
  fprintf(stderr, "write_with_vmsplice\t%s\n", bool_str(options.write_with_vmsplice));
  fprintf(stderr, "read_with_splice\t%s\n", bool_str(options.read_with_splice));
  fprintf(stderr, "gift\t\t\t%s\n", bool_str(options.gift));
  fprintf(stderr, "bytes_to_pipe\t\t%zu\n", options.bytes_to_pipe);
  fprintf(stderr, "\n");
}

static char* allocate_buf(const Options& options) {
  void* buf = NULL;
  if (options.huge_page) {
    size_t sz = options.huge_page_size > options.buf_size ? options.huge_page_size : options.buf_size;
    fprintf(stderr, "allocating %zu bytes with %zu alignment\n\n", sz, options.huge_page_size);
    int ret = posix_memalign(&buf, options.huge_page_size, sz);
    if (ret != 0) {
      fprintf(stderr, "failed to allocate aligned memory: %s", strerror(ret));
      exit(EXIT_FAILURE);
    }
    // should be unnecessary according to madvise(2), but let's err o
    // the safe side.
    if (madvise(buf, options.buf_size, MADV_HUGEPAGE) < 0) {
      fprintf(stderr, "could not defrag memory: %s", strerror(errno));
      exit(EXIT_FAILURE);
    }
  } else {
    buf = malloc(options.buf_size);
  }
  if (!buf) {
    fprintf(stderr, "could not allocate buffer\n");
    exit(EXIT_FAILURE);
  }
  // fill the buffer with 0s so that we know it's printable stuff
  memset((void *) buf, options.buf_size, '0');
  return (char *) buf;
}

// Whether to use page-info to print out info about huge pages
#ifndef PAGE_INFO
#define PAGE_INFO 1
#endif

#if PAGE_INFO
#include "page-info.h"
#endif

UNUSED
static void buf_page_info(const Options& options, char* buf) {
#if PAGE_INFO
  page_info_array pinfo = get_info_for_range(buf, buf + options.buf_size);
  flag_count thp_count = get_flag_count(pinfo, KPF_THP);
  if (thp_count.pages_available) {
    fprintf(
      stderr,
      "source pages allocated with transparent hugepages: %4.1f%% (%lu total pages, %4.1f%% flagged)\n",
      100.0 * thp_count.pages_set / thp_count.pages_total,
      thp_count.pages_total,
      100.0 * thp_count.pages_available / thp_count.pages_total
    );
  } else {
    fprintf(stderr, "couldn't determine hugepage info (you are probably not running as root)\n");
  }
  fprintf(stderr, "\n");
#endif
}
