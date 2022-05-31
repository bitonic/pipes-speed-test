from tqdm import tqdm
import dataclasses
import numpy as np
import os
import pandas
import subprocess
import random

@dataclasses.dataclass
class RunOptions:
  name: str = ''
  busy_loop: bool = True
  bytes_to_pipe: int = 1 << 30 # 1GiB
  huge_page: bool = True
  # 256KiB by default (L2 cache size)
  buf_size: int = 1 << 18
  write_with_vmsplice: bool = True
  read_with_splice: bool = True
  gift: bool = True
  poll: bool = True
  pipe_size: int = 0
  csv: bool = True

def build_flags(run_options):
  flags = []
  for field in run_options.__dataclass_fields__:
    value = getattr(run_options, field)
    if value == True:
      flags.append(f'--{field}')
    elif value == False:
      pass
    elif isinstance(value, int):
      flags.append(f'--{field}={value}')
  return flags

def run(run_options):
  flags = build_flags(run_options)
  with subprocess.Popen(
    ['taskset', '1', './write'] + flags,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
  ) as write:
    result = subprocess.run(
      ['taskset', '2', './read'] + flags,
      check=True,
      capture_output=True,
      stdin=write.stdout,
    )
    return run_options.name + ',' + result.stdout.decode('utf-8')

class TestCaseGenerator:
  def __init__(self):
    self.iterations = 10
    self.run_options = []
    options = RunOptions(
      bytes_to_pipe=(10 << 30),
      write_with_vmsplice=False,
      read_with_splice=False,
      huge_page=False,
      busy_loop=False,
      gift=False,
      poll=False,
    )
    self.run_options.append(dataclasses.replace(options, name='write_read'))
    options.huge_page = True
    self.run_options.append(dataclasses.replace(options, name='write_read_huge'))
    options.huge_page = False
    options.write_with_vmsplice = True
    self.run_options.append(dataclasses.replace(options, name='vmsplice_read'))
    options.huge_page = True
    self.run_options.append(dataclasses.replace(options, name='vmsplice_read_huge'))
    options.huge_page = False
    options.read_with_splice = True
    self.run_options.append(dataclasses.replace(options, name='vmsplice_splice'))
    options.huge_page = True
    self.run_options.append(dataclasses.replace(options, name='vmsplice_splice_huge'))
    options.busy_loop = True
    self.run_options.append(dataclasses.replace(options, name='busy_loop_huge'))

  def __iter__(self):
    self.iteration = 0
    self.remaining_run_options = self.run_options[:]
    random.shuffle(self.remaining_run_options)
    return self

  def __next__(self):
    if not self.remaining_run_options:
      self.iteration += 1
      if self.iteration >= self.iterations:
        raise StopIteration
      self.remaining_run_options = self.run_options[:]
      random.shuffle(self.remaining_run_options)
    return self.remaining_run_options.pop()

result_dtype = [
  ('name', np.str_),
  ('gibibytes_per_second', np.double),
  ('buf_size', np.uint),
  ('bytes_to_pipe', np.uint),
  ('pipe_size', np.uint),
  ('busy_loop', np.bool_),
  ('poll', np.bool_),
  ('huge_page', np.bool_),
  ('check_huge_page', np.bool_),
  ('write_with_vmsplice', np.bool_),
  ('read_with_splice', np.bool_),
  ('gift', np.bool_),
  ('lock_memory', np.bool_),
  ('dont_touch_pages', np.bool_),
  ('same_buffer', np.bool_),
]
result_csv = 'name,gibibytes_per_second,bytes_to_pipe,buf_size,pipe_size,busy_loop,poll,huge_page,check_huge_page,write_with_vmsplice,read_with_splice,gift,lock_memory,dont_touch_pages,same_buffer\n'
test_cases = TestCaseGenerator()
for run_options in tqdm(test_cases, total=(len(test_cases.run_options) * test_cases.iterations)):
  result_csv += run(run_options)
with open('raw-data.csv', 'w') as f:
  f.write(result_csv)
result = pandas.read_csv('raw-data.csv', dtype=result_dtype)
result.groupby(
  list(filter(lambda x: x[0] != 'gibibytes_per_second', map(lambda x: x[0], result_dtype)))
).mean().to_csv('data.csv')

