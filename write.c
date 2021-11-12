#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/kernel-page-flags.h>
#include <poll.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "common.h"

NOINLINE UNUSED
static void with_write() {
#if BUSY_LOOP
  if (fcntl(STDOUT_FILENO, F_SETFL, O_NONBLOCK) < 0) {
    fprintf(stderr, "could not mark stdout pipe as non blocking: %s", strerror(errno));
    exit(EXIT_FAILURE);
  }
#endif
#if POLL
  struct pollfd pollfd;
  pollfd.fd = STDOUT_FILENO;
  pollfd.events = POLLOUT | POLLWRBAND;
#endif
  while (1) {
    char* cursor = buf;
    ssize_t remaining = BUF_SIZE;
    while (__builtin_expect(remaining > 0, !HUGE_PAGE)) {
#if POLL && BUSY_LOOP
      while (poll(&pollfd, 1, 0) == 0) {}
#elif POLL
      poll(&pollfd, 1, -1);
#endif
      ssize_t ret = write(STDOUT_FILENO, cursor, remaining);
      // we never seem to get stuck here when writing manually
      if (__builtin_expect(ret < 0 && errno == EAGAIN, 0)) {
        continue;
      }
      if (__builtin_expect(ret < 0, 0)) {
        fprintf(stderr, "read failed: %s", strerror(errno));
        exit(EXIT_FAILURE);
      }
      if (ret != BUF_SIZE) {
        fprintf(stderr, "only wrote %zu bytes rather than %d!\n", ret, BUF_SIZE);
        exit(EXIT_FAILURE);
      }
      cursor += ret;
      remaining -= ret;
    }
  }
}

NOINLINE UNUSED
static void with_vmsplice() {
  struct iovec bufvec;
#if POLL
  struct pollfd pollfd;
  pollfd.fd = STDOUT_FILENO;
  pollfd.events = POLLOUT | POLLWRBAND;
#endif
  while (1) {
    bufvec.iov_base = buf;
    bufvec.iov_len = BUF_SIZE;
    while (__builtin_expect(bufvec.iov_len > 0, !HUGE_PAGE)) {
#if POLL && BUSY_LOOP
      while (poll(&pollfd, 1, 0) == 0) {}
#elif POLL
      poll(&pollfd, 1, -1);
#endif
      ssize_t ret = vmsplice(
        STDOUT_FILENO, &bufvec, 1,
        (BUSY_LOOP ? SPLICE_F_NONBLOCK : 0) | (GIFT ? SPLICE_F_GIFT : 0)
      );
      if (__builtin_expect(ret < 0 && errno == EAGAIN, BUSY_LOOP & !POLL)) {
        continue;
      }
      if (__builtin_expect(ret < 0, 0)) {
        fprintf(stderr, "vmsplice failed: %s", strerror(errno));
        exit(EXIT_FAILURE);
      }
      bufvec.iov_base += ret;
      bufvec.iov_len -= ret;
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
    if (errno == EPERM) {
      fprintf(stderr, "setting the pipe size failed with EPERM, %d is probably above the pipe size limit\n", BUF_SIZE);

    } else {
      fprintf(stderr, "setting the pipe size failed, are you piping the output somewhere? error: %s\n", strerror(errno));
    }
    exit(EXIT_FAILURE);
  }
  if ((size_t) fcntl_res != BUF_SIZE) {
    fprintf(stderr, "could not set the pipe size to 0x%dx, got 0x%dx instead\n", BUF_SIZE, fcntl_res);
    exit(EXIT_FAILURE);
  }

  getchar();

  fprintf(stderr, "starting stream\n");
#if WRITE_WITH_VMSPLICE
  with_vmsplice();
#else
  with_write();
#endif

  return 0;
}
