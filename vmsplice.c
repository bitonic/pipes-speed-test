#define _GNU_SOURCE
#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <sys/uio.h>
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <sys/mman.h>
#include <linux/kernel-page-flags.h>

#define NOINLINE __attribute__((noinline))

// Whether to busy loop on `vmsplice` or to block
#define BUSY_LOOP 1

// How many bytes to fill at each iteration. Useful to lose time between syscalls
// and simulate fizzbuzz
#define FILL_SIZE 0

// Whether to allocate the buffers in a huge page
#define USE_HUGE_PAGE 1

#define PAGE_INFO 1

#if PAGE_INFO
#include "page-info.h"
#endif

// 128KiB
#define BUF_SIZE (1 << 17)

// Linux huge pages are 2MiB or 1GiB, we use the 2MiB ones.
#define HUGE_PAGE_SIZE (1 << 21) // 2MiB huge page
// #define HUGE_PAGE_SIZE (1 << 30)

#define HUGE_PAGE_ALIGNMENT (1 << 21)

#if USE_HUGE_PAGE
  char buf[HUGE_PAGE_SIZE] __attribute__((aligned(HUGE_PAGE_ALIGNMENT)));
#else
  char buf[BUF_SIZE];
#endif

NOINLINE
static void start_stream() {
  struct iovec bufvec;
  bufvec.iov_len = BUF_SIZE;
  while (1) {
    for (int i = 0; i < FILL_SIZE; i++) {
      buf[i] = (char) (i % 10) + '0';
    }
    bufvec.iov_base = buf;
    while (bufvec.iov_base < (void *) (buf + BUF_SIZE)) {
      ssize_t ret = vmsplice(
        STDOUT_FILENO, &bufvec, 1,
#if BUSY_LOOP
        SPLICE_F_NONBLOCK
#else
        0
#endif
      );
      if (ret < 0) {
        if (errno == EAGAIN) {
          continue;
        }
        fprintf(stderr, "vmsplice failed: %s", strerror(errno));
        exit(EXIT_FAILURE);
      }
      bufvec.iov_base += ret;
    }
  }
}

int main(void) {
#if USE_HUGE_PAGE
  if ((((size_t) buf) & ((1 << 21) - 1)) != 0) {
    fprintf(stderr, "buf location %p is not 2MiB aligned\n", buf);
    exit(EXIT_FAILURE);
  }

  fprintf(stderr, "defragging buffer area\n");
  if (madvise(buf, sizeof(buf), MADV_HUGEPAGE) < 0) {
    fprintf(stderr, "could not defrag memory: %s", strerror(errno));
    exit(EXIT_FAILURE);
  }
#endif

#if PAGE_INFO
  page_info_array pinfo = get_info_for_range(buf, buf + sizeof(buf));
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
#endif

  fprintf(stderr, "filling buffer\n\n");
  for (int i = 0; i < BUF_SIZE; i++) {
    buf[i] = (char) (i % 10) + '0';
  }

  fprintf(stderr, "resizing pipe to 0x%x\n", BUF_SIZE);
  int fcntl_res = fcntl(STDOUT_FILENO, F_SETPIPE_SZ, BUF_SIZE);
  if (fcntl_res < 0) {
    fprintf(stderr, "setting the pipe size failed, are you piping the output somewhere? error: %s\n", strerror(errno));
    exit(EXIT_FAILURE);
  }
  if ((size_t) fcntl_res != BUF_SIZE) {
    fprintf(stderr, "could not set the pipe size to 0x%dx, got 0x%dx instead\n", BUF_SIZE, fcntl_res);
    exit(EXIT_FAILURE);
  }

  fprintf(stderr, "starting stream\n");
  start_stream();

  return 0;
}
