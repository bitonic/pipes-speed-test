#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/kernel-page-flags.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "common.h"

NOINLINE
static void start_stream() {
  struct iovec bufvec;
  bufvec.iov_len = BUF_SIZE;
  while (1) {
    for (int i = 0; i < FILL_SIZE; i++) {
      buf[i] = (char) (i % 10) + '0';
    }
    bufvec.iov_base = buf;
    // unlikely to enter this loop twice with huge pages
    while (__builtin_expect(bufvec.iov_base < (void*) (buf + BUF_SIZE), !USE_HUGE_PAGE)) {
      ssize_t ret = vmsplice(
        STDOUT_FILENO, &bufvec, 1,
        (BUSY_LOOP ? SPLICE_F_NONBLOCK : 0) | (GIFT ? SPLICE_F_GIFT : 0)
      );
      // likely when busy looping
      if (__builtin_expect(ret < 0 && errno == EAGAIN, BUSY_LOOP)) {
        continue;
      }
      // always unlikely
      if (__builtin_expect(ret < 0, 0)) {
        fprintf(stderr, "vmsplice failed: %s", strerror(errno));
        exit(EXIT_FAILURE);
      }
      bufvec.iov_base += ret;
    }
  }
}

int main(void) {
  defrag_buf();

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
