#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>
#include <string.h>
#include <time.h>
#include <sys/stat.h>
#include <fcntl.h>

#include "common.h"

#define PASSTHROUGH 1

static struct timespec tspec;

static double get_millis() {
  if (clock_gettime(CLOCK_REALTIME, &tspec) < 0) {
    fprintf(stderr, "could not get time: %s", strerror(errno));
    exit(EXIT_FAILURE);
  }
  return ((double) tspec.tv_sec)*1000.0 + ((double) tspec.tv_nsec)/1000000.0;
}

int main(int argc, const char* argv[]) {
  defrag_buf();

  // Read 1GiB by default
  size_t bytes_to_read = 1ULL << 30;
  if (argc == 1) {
    // all good
  } else if (argc == 2) {
    if (sscanf(argv[1], "%zuG", &bytes_to_read)) {
      bytes_to_read = bytes_to_read << 30;
    } else if (sscanf(argv[1], "%zuM", &bytes_to_read)) {
      bytes_to_read = bytes_to_read << 20;
    } else if (sscanf(argv[1], "%zuK", &bytes_to_read)) {
      bytes_to_read = bytes_to_read << 10;
    } else {
      fprintf(stderr, "bad size specification %s\n", argv[1]);
      exit(EXIT_FAILURE);
    }
  } else {
    fprintf(stderr, "bad usage, expecting %s <num>K|<num>M|<num>G\n", argv[0]);
    exit(EXIT_FAILURE);
  }

  fprintf(stderr, "will read %zu bytes\n", bytes_to_read);

  double t0 = get_millis();
  size_t read_count = 0;
#if PASSTHROUGH
  int devnull = open("/dev/null", O_WRONLY);
  while (read_count < bytes_to_read) {
    ssize_t ret = splice(
      STDIN_FILENO, NULL, devnull, NULL, BUF_SIZE,
      (BUSY_LOOP ? SPLICE_F_NONBLOCK : 0) | (GIFT ? SPLICE_F_GIFT : 0)
    );
    if (__builtin_expect(ret < 0 && errno == EAGAIN, BUSY_LOOP)) {
      continue;
    }
    if (__builtin_expect(ret < 0, 0)) {
      fprintf(stderr, "splice failed: %s", strerror(errno));
      exit(EXIT_FAILURE);
    }
    read_count += ret;
  }
  close(devnull);
#else
  while (read_count < bytes_to_read) {
    ssize_t ret = read(STDIN_FILENO, buf, BUF_SIZE);
    if (__builtin_expect(ret < 0, 0)) {
      fprintf(stderr, "read failed: %s", strerror(errno));
      exit(EXIT_FAILURE);
    }
    read_count += ret;
  }
#endif
  double t1 = get_millis();
  printf("%f\n", 1000.0 * ((double) read_count) / (t1 - t0));

  return 0;
}
