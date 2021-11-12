from dataclasses import dataclass
import subprocess
import os
import numpy as np
import pandas

@dataclass
class Options:
  iterations: int = 5
  read_size: int = 1 << 30 # 1GiB

@dataclass
class CompileOptions:
  busy_loop: bool = True
  huge_page: bool = True
  # 128KiB by default (half of my L2 cache)
  buf_size: int = 1 << 17
  write_with_vmsplice: bool = True
  read_with_splice: bool = True
  gift: bool = True
  poll: bool = True

def build_cflags(compile_options):
  cflags = ""
  for field in compile_options.__dataclass_fields__:
    value = getattr(compile_options, field)
    if value == True:
      cflags += f" -D{field.upper()}=1"
    elif value == False:
      cflags += f" -D{field.upper()}=0"
    elif isinstance(value, int):
      cflags += f" -D{field.upper()}={value}"
  return cflags

def run(options, compile_options):
  print("building binaries ...", end="", flush=True)
  subprocess.run(("make", "clean"), check=True, stdout=subprocess.DEVNULL)
  env = os.environ.copy()
  env["OPTIONS_CFLAGS"] = build_cflags(compile_options)
  subprocess.run(
    ("make", "write", "read"),
    check=True,
    stdout=subprocess.DEVNULL,
    env=env,
  )
  with subprocess.Popen(
    ("taskset", "1", "./write"),
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
  ) as write:
    print(" done.")
    print("running test ...", end="", flush=True)
    result = subprocess.run(
      ("taskset", "2", "./read", str(options.read_size)),
      check=True,
      capture_output=True,
      stdin=write.stdout,
    )
    print(" done.")
    return result.stdout.decode('utf-8')

def run_all(options):
  result = ""
  for shift in [15, 17, 20, 23]:
    compile_options = CompileOptions(
      buf_size=(1 << shift),
      write_with_vmsplice=False,
      read_with_splice=False,
      huge_page=False,
      busy_loop=False,
      gift=False,
      poll=False,
    )
    compile_options.write_with_vmsplice = True
    result += run(options, compile_options)
    compile_options.read_with_splice = True
    result += run(options, compile_options)
    compile_options.huge_page = True
    result += run(options, compile_options)
    compile_options.busy_loop = True
    result += run(options, compile_options)
  return result

# 10 iterations, 10GB each
options = Options(iterations=10, read_size=(10 << 30))
result_dtype = [
  ("bytes_per_second", np.double),
  ("read_size", np.uint),
  ("buf_size", np.uint),
  ("write_with_vmsplice", np.bool_),
  ("read_with_splice", np.bool_),
  ("huge_page", np.bool_),
  ("busy_loop", np.bool_),
  ("poll", np.bool_),
  ("gift", np.bool_),
]
result_csv = "bytes_per_second,read_size,buf_size,write_with_vmsplice,read_with_splice,huge_page,busy_loop,poll,gift\n"
for _ in range(options.iterations):
  result_csv += run_all(options)
with open("raw-data.csv", "w") as f:
  f.write(result_csv)
result = pandas.read_csv("raw-data.csv", dtype=result_dtype)
result.groupby(["read_size", "buf_size", "write_with_vmsplice", "read_with_splice", "huge_page", "busy_loop", "poll", "gift"]).mean().to_csv("data.csv")
