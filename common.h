
#define NOINLINE __attribute__((noinline))
#define UNUSED __attribute__((unused))

// Whether to busy loop on `vmsplice` or to block
#ifndef BUSY_LOOP
#define BUSY_LOOP 1
#endif

// Whether to allocate the buffers in a huge page
#ifndef HUGE_PAGE
#define HUGE_PAGE 1
#endif

// How big should the buffer be
#ifndef BUF_SIZE
#define BUF_SIZE (1 << 17) // 128KiB
#endif

#ifndef WRITE_WITH_VMSPLICE
#define WRITE_WITH_VMSPLICE 1
#endif

// Whether the read end should just shovel data into /dev/null with `splice`
#ifndef READ_WITH_SPLICE
#define READ_WITH_SPLICE 1
#endif

// Linux huge pages are 2MiB or 1GiB, we use the 2MiB ones.
#ifndef HUGE_PAGE_SIZE
#define HUGE_PAGE_SIZE (1 << 21) // 2MiB huge page
#endif

// Whether pages should be gifted (and then moved if with READ_WITH_SPLICE) to
// vmsplice
#ifndef GIFT
#define GIFT 1
#endif

#ifndef HUGE_PAGE_ALIGNMENT
#define HUGE_PAGE_ALIGNMENT (1 << 21)
#endif

// Whether to use page-info to print out info about huge pages
#ifndef PAGE_INFO
#define PAGE_INFO 0
#endif

// End of config

#if PAGE_INFO
#include "page-info.h"
#endif

#if HUGE_PAGE
  static char buf[HUGE_PAGE_SIZE] __attribute__((aligned(HUGE_PAGE_ALIGNMENT)));
#else
  static char buf[BUF_SIZE];
#endif

static void defrag_buf() {
#if HUGE_PAGE
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
}
