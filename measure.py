import dataclasses
import subprocess
import os
import numpy as np
import pandas
from tqdm import tqdm

@dataclasses.dataclass
class RunOptions:
  busy_loop: bool = True
  bytes_to_pipe: int = 1 << 30 # 1GiB
  huge_page: bool = True
  # 128KiB by default (half of my L2 cache)
  buf_size: int = 1 << 17
  write_with_vmsplice: bool = True
  read_with_splice: bool = True
  gift: bool = True
  poll: bool = True

def build_flags(run_options):
  flags = []
  for field in run_options.__dataclass_fields__:
    value = getattr(run_options, field)
    if value == True:
      flags.append(f"--{field}")
    elif value == False:
      pass
    elif isinstance(value, int):
      flags.append(f"--{field}={value}")
  return flags

def run(run_options):
  flags = build_flags(run_options)
  with subprocess.Popen(
    ["sudo", "taskset", "1", "./write"] + flags,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
  ) as write:
    result = subprocess.run(
      ["sudo", "taskset", "2", "./read"] + flags,
      check=True,
      capture_output=True,
      stdin=write.stdout,
    )
    return result.stdout.decode('utf-8')

class TestCaseGenerator:
  def __init__(self):
    self.iterations = 10
    self.run_options = []
    for shift in [15, 17, 20, 23]:
      options = RunOptions(
        bytes_to_pipe=(10 << 30),
        buf_size=(1 << shift),
        write_with_vmsplice=False,
        read_with_splice=False,
        huge_page=False,
        busy_loop=False,
        gift=False,
        poll=False,
      )
      self.run_options.append(dataclasses.replace(options))
      options.write_with_vmsplice = True
      self.run_options.append(dataclasses.replace(options))
      options.read_with_splice = True
      self.run_options.append(dataclasses.replace(options))
      options.huge_page = True
      self.run_options.append(dataclasses.replace(options))
      options.busy_loop = True
      self.run_options.append(dataclasses.replace(options))

  def __iter__(self):
    self.iteration = 0
    self.remaining_run_options = self.run_options[:]
    return self

  def __next__(self):
    if not self.remaining_run_options:
      self.iteration += 1
      if self.iteration >= self.iterations:
        raise StopIteration
      self.remaining_run_options = self.run_options[:]
    return self.remaining_run_options.pop()

# 10 iterations
result_dtype = [
  ("gigabytes_per_second", np.double),
  ("read_bytes", np.uint),
  ("buf_size", np.uint),
  ("write_with_vmsplice", np.bool_),
  ("read_with_splice", np.bool_),
  ("huge_page", np.bool_),
  ("busy_loop", np.bool_),
  ("poll", np.bool_),
  ("gift", np.bool_),
]
result_csv = "gigabytes_per_second,bytes_to_pipe,buf_size,write_with_vmsplice,read_with_splice,huge_page,busy_loop,poll,gift\n"
test_cases = TestCaseGenerator()
for run_options in tqdm(test_cases, total=(len(test_cases.run_options) * test_cases.iterations)):
  result_csv += run(run_options)
with open("raw-data.csv", "w") as f:
  f.write(result_csv)
result = pandas.read_csv("raw-data.csv", dtype=result_dtype)
result.groupby(["bytes_to_pipe", "buf_size", "write_with_vmsplice", "read_with_splice", "huge_page", "busy_loop", "poll", "gift"]).mean().to_csv("data.csv")
