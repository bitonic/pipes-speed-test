#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/types.h>

#include <linux/types.h>

#include "common.hpp"

#define GUP_FAST_BENCHMARK	_IOWR('g', 1, struct gup_test)
#define GUP_TEST_MAX_PAGES_TO_DUMP              8

struct gup_test {
  __u64 get_delta_usec;
  __u64 put_delta_usec;
  __u64 addr;
  __u64 size;
  __u32 nr_pages_per_call;
  __u32 gup_flags;
  __u32 test_flags;
  __u32 which_pages[GUP_TEST_MAX_PAGES_TO_DUMP];
};

int main(int argc, char **argv) {
  Options options;
  parse_options(argc, argv, options);

  char* buf = allocate_buf(options);

  struct gup_test gup;
  memset((void*)&gup, 0, sizeof(gup));
  gup.nr_pages_per_call = options.buf_size/2/PAGE_SIZE;
  gup.addr = (uint64_t)buf;

  if (!options.dont_touch_pages) {
    memset((void*) buf, '0', options.buf_size);
  }

  int gup_test_fd = open("/sys/kernel/debug/gup_test", O_RDWR);
  if (gup_test_fd == -1) {
    fail("could not open gup_test: %s", strerror(errno));
  }

  uint64_t total_usec = 0;
  log("will get %u pages per call, %lu times\n", gup.nr_pages_per_call, options.bytes_to_pipe/(options.buf_size/2));
  for (size_t i = 0; i < options.bytes_to_pipe; i += options.buf_size/2) {
    gup.size = options.buf_size;
    if (ioctl(gup_test_fd, GUP_FAST_BENCHMARK, &gup)) {
      fail("gup_test failed: %s", strerror(errno));
    }
    total_usec += gup.get_delta_usec;
  }

  printf("total get_user_pages_fast time: %zu\n", total_usec);

  return 0;
}
