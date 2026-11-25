#!/usr/bin/env python3
"""Read one Darwin process start time, or list every pid with its process group, without executing the
setuid ps binary."""
import ctypes
import os
import sys
import time


def list_groups():
    """`ps -A -o pid= -o pgid=`, which supervisor/roles.py needs to find a session's process groups."""
    if sys.platform != 'darwin':
        return 2
    libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    libproc.proc_listallpids.argtypes = [ctypes.c_void_p, ctypes.c_int]
    libproc.proc_listallpids.restype = ctypes.c_int
    size = 1024
    while True:
        pids = (ctypes.c_int * size)()
        count = libproc.proc_listallpids(pids, ctypes.sizeof(pids))
        if count <= 0:
            return 1
        if count < size:
            break
        size *= 2  # a full buffer may be a truncated list
    for pid in pids[:count]:
        if pid <= 0:
            continue
        try:
            print(pid, os.getpgid(pid))
        except OSError:  # gone, or hidden by the sandbox
            continue
    return 0


def main():
    args = sys.argv[1:]
    if args == ['-A', '-o', 'pid=', '-o', 'pgid=']:
        return list_groups()
    if len(args) != 4 or set(args[::2]) != {'-p', '-o'}:
        return 2
    options = dict(zip(args[::2], args[1::2]))
    if options['-o'] != 'lstart=' or not options['-p'].isascii() or not options['-p'].isdigit():
        return 2
    pid = int(options['-p'])
    if not 0 < pid < 2**31 or sys.platform != 'darwin':
        return 2

    class BSDInfo(ctypes.Structure):
        _fields_ = [(name, ctypes.c_uint32) for name in (
            'flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid',
            'ruid', 'rgid', 'svuid', 'svgid', 'reserved')]
        _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
        _fields_ += [(name, ctypes.c_uint32) for name in (
            'nfiles', 'pgid', 'pjobc', 'tdev', 'tpgid')]
        _fields_ += [('nice', ctypes.c_int32), ('start_sec', ctypes.c_uint64),
                     ('start_usec', ctypes.c_uint64)]

    libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    libproc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                   ctypes.c_void_p, ctypes.c_int]
    libproc.proc_pidinfo.restype = ctypes.c_int
    info = BSDInfo()
    # PROC_PIDTBSDINFO; sandbox process-info restrictions remain enforced.
    size = libproc.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
    if size != ctypes.sizeof(info) or info.pid != pid:
        return 1
    print(time.strftime('%a %b %e %H:%M:%S %Y', time.localtime(info.start_sec)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
