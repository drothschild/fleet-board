import pathlib
import sys
import time

counter = pathlib.Path(sys.argv[1])
with counter.open('a', encoding='utf-8') as stream:
    stream.write('invoked\n')
    stream.flush()
time.sleep(float(sys.argv[2]))
