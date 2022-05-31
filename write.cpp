#include "common.hpp"

NOINLINE UNUSED
static void with_write(const Options& options, char* buf) {
  if (options.busy_loop) {
    if (fcntl(STDOUT_FILENO, F_SETFL, O_NONBLOCK) < 0) {
      fail("could not mark stdout pipe as non blocking: %s", strerror(errno));
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
      if (ret < 0 && errno == EPIPE) {
        goto finished;
      }
      // we never seem to get stuck here when writing manually
      if (ret < 0 && errno == EAGAIN) {
        continue;
      }
      if (ret < 0) {
        fail("read failed: %s", strerror(errno));
      }
      cursor += ret;
      remaining -= ret;
    }
  }
finished:
  return;
}

NOINLINE UNUSED
static void with_vmsplice(const Options& options, char* bufs[2]) {
  struct pollfd pollfd = {
    .fd = STDOUT_FILENO,
    .events = POLLOUT | POLLWRBAND
  };
  // When writing with vmsplice, we do a double buffering, just like
  // fizzbuzz. This ensures that after one half-write the other buffer
  // is ready to read. This simulates one possible measure when streaming
  // to a pipe with vmsplice.
  size_t buf_ix = 0;
  while (true) {
    struct iovec bufvec {
      .iov_base = bufs[buf_ix],
      .iov_len = options.buf_size
    };
    buf_ix = (buf_ix + 1) % 2;
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
      if (ret < 0 && errno == EPIPE) {
        goto finished;
      }
      if (ret < 0 && errno == EAGAIN) {
        continue;
      }
      if (ret < 0) {
        fail("vmsplice failed: %s", strerror(errno));
      }
      bufvec.iov_base = (void*) (((char*) bufvec.iov_base) + ret);
      bufvec.iov_len -= ret;
    }
  }
finished:
  return;
}

int main(int argc, char** argv) {
  signal(SIGPIPE, SIG_IGN); // we terminate cleanly when the pipe is closed
  perf_init();

  Options options;
  parse_options(argc, argv, options);

  if (options.pipe_size && options.write_with_vmsplice) {
    fail("cannot write with vmsplice and set the pipe size manually. it will be automatically determined.");
  }
  if (options.write_with_vmsplice) {
    if (options.buf_size % 2 != 0) {
      fail("if writing with vmsplice, the buffer size must be divisible by two");
    }
    options.pipe_size = options.buf_size / 2;
  }
  if (options.pipe_size > 0) {
    int fcntl_res = fcntl(STDOUT_FILENO, F_SETPIPE_SZ, options.pipe_size);
    if (fcntl_res < 0) {
      if (errno == EPERM) {
        fail("setting the pipe size failed with EPERM, %zu is probably above the pipe size limit\n", options.buf_size);

      } else {
        fail("setting the pipe size failed, are you piping the output somewhere? error: %s\n", strerror(errno));

      }
    }
    if ((size_t) fcntl_res != options.pipe_size) {
      fail("could not set the pipe size to %zu, got %d instead\n", options.pipe_size, fcntl_res);
    }
  }

  reset_perf_count();
  enable_perf_count();
  if (options.write_with_vmsplice) {
    char* bufs[2];
    if (options.same_buffer) {
      char* buf = allocate_buf(options);
      options.buf_size = options.buf_size / 2;
      bufs[0] = buf;
      bufs[1] = buf + options.buf_size;
    } else {
      bufs[0] = allocate_buf(options);
      bufs[1] = allocate_buf(options);
    }
    log("starting to write\n");
    with_vmsplice(options, bufs);
  } else {
    char* buf = allocate_buf(options);
    log("starting to write\n");
    with_write(options, buf);
  }
  disable_perf_count();
  log_perf_count();

  perf_close();

  return 0;
}
