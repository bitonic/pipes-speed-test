Some experiments concerning the performance of Linux pipes. Please head to [the blog post](https://mazzo.li/posts/fast-pipes.html) to understand what this code is about.

## Building and running

```
% make
% ./write | ./read
4.5GiB/s, 256KiB buffer, 40960 iterations (10GiB piped)
```

`./read` reads 10GiB (by default). Use `--csv` for machine-readable output with this schema:

```
gigabytes_per_second,bytes_to_pipe,buf_size,pipe_size,busy_loop,poll,huge_page,check_huge_page,write_with_vmsplice,read_with_splice,gift,lock_memory,dont_touch_pages,same_buffer
```

Where the first four are numbers and the rest are booleans. All the fields apart from `gigabytes_per_seconds` (which is the main output of the program) are configurable on the command line. Check out `parse_options` in `common.hpp`.

`measure.py` can be ran to automatically produce the data shown in the graph at the top of the blog post. It requires `taskset`, and various python libraries. If you have nix:

```
% nix-shell
% python3 measure.py
```

Additionally, `get-user-pages.cpp` contains a small benchmark using `/sys/kernel/debug/gup_test`. To run it, you need to compile your kernel with `CONFIG_GUP_TEST y`. Also, the file and flag were recently renamed, prior to kernel version 5.17 they were called `gup_benchmark` and `CONFIG_GUP_BENCHMARK`, respectively.
