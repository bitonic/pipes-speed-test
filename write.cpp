#include "common.h"

NOINLINE UNUSED
static void with_write(const Options& options, char* buf) {
  if (options.busy_loop) {
    if (fcntl(STDOUT_FILENO, F_SETFL, O_NONBLOCK) < 0) {
      fprintf(stderr, "could not mark stdout pipe as non blocking: %s", strerror(errno));
      exit(EXIT_FAILURE);
    }
  }
  struct pollfd pollfd;
  pollfd.fd = STDOUT_FILENO;
  pollfd.events = POLLOUT | POLLWRBAND;
  while (true) {
    char* cursor = buf;
    ssize_t remaining = options.buf_size;
    while (remaining > 0) {
      if (options.poll && options.busy_loop) {
        while (poll(&pollfd, 1, 0) == 0) {}
      } else if (options.poll) {
        poll(&pollfd, 1, -1);
      }
      ssize_t ret = write(STDOUT_FILENO, cursor, remaining);
      // we never seem to get stuck here when writing manually
      if (ret < 0 && errno == EAGAIN) {
        continue;
      }
      if (ret < 0) {
        fprintf(stderr, "read failed: %s", strerror(errno));
        exit(EXIT_FAILURE);
      }
      if ((size_t) ret != options.buf_size) {
        fprintf(stderr, "only wrote %zd bytes rather than %zu!\n", ret, options.buf_size);
        exit(EXIT_FAILURE);
      }
      cursor += ret;
      remaining -= ret;
    }
  }
}

NOINLINE UNUSED
static void with_vmsplice(const Options& options, char* buf) {
  struct iovec bufvec;
  struct pollfd pollfd;
  pollfd.fd = STDOUT_FILENO;
  pollfd.events = POLLOUT | POLLWRBAND;
  while (true) {
    bufvec.iov_base = (void*) buf;
    bufvec.iov_len = options.buf_size;
    while (bufvec.iov_len > 0) {
      if (options.poll && options.busy_loop) {
        while (poll(&pollfd, 1, 0) == 0) {}
      } else if (options.poll) {
        poll(&pollfd, 1, -1);
      }
      ssize_t ret = vmsplice(
        STDOUT_FILENO, &bufvec, 1,
        (options.busy_loop ? SPLICE_F_NONBLOCK : 0) | (options.gift ? SPLICE_F_GIFT : 0)
      );
      if (ret < 0 && errno == EAGAIN) {
        continue;
      }
      if (ret < 0) {
        fprintf(stderr, "vmsplice failed: %s", strerror(errno));
        exit(EXIT_FAILURE);
      }
      bufvec.iov_base = (void*) (((char*) bufvec.iov_base) + ret);
      bufvec.iov_len -= ret;
    }
  }
}

int main(int argc, char** argv) {
  Options options;
  parse_options(argc, argv, options);

  char* buf = allocate_buf(options);

  buf_page_info(options, buf);

  int fcntl_res = fcntl(STDOUT_FILENO, F_SETPIPE_SZ, options.buf_size);
  if (fcntl_res < 0) {
    if (errno == EPERM) {
      fprintf(stderr, "setting the pipe size failed with EPERM, %zu is probably above the pipe size limit\n", options.buf_size);

    } else {
      fprintf(stderr, "setting the pipe size failed, are you piping the output somewhere? error: %s\n", strerror(errno));
    }
    exit(EXIT_FAILURE);
  }
  if ((size_t) fcntl_res != options.buf_size) {
    fprintf(stderr, "could not set the pipe size to 0x%zx, got 0x%dx instead\n", options.buf_size, fcntl_res);
    exit(EXIT_FAILURE);
  }

  fprintf(stderr, "starting to write\n");
  if (options.write_with_vmsplice) {
    with_vmsplice(options, buf);
  } else {
    with_write(options, buf);
  }

  return 0;
}
