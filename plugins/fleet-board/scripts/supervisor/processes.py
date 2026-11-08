"""Conservative host process identities for detached attempts."""
import ctypes
from dataclasses import dataclass
import os
import sys


@dataclass(frozen=True)
class ProcessIdentity:
    boot_id: str
    pid: int
    started_at: str
    nonce: str


def _boot_id():
    if sys.platform.startswith('linux'):
        with open('/proc/sys/kernel/random/boot_id', encoding='ascii') as stream:
            return stream.read().strip()
    if sys.platform == 'darwin':
        libc = ctypes.CDLL(None, use_errno=True)
        value = ctypes.create_string_buffer(128)
        size = ctypes.c_size_t(len(value))
        if libc.sysctlbyname(b'kern.bootsessionuuid', value, ctypes.byref(size), None, 0) != 0:
            raise OSError('boot identity unavailable')
        boot_id = value.value.decode('ascii')
        if not boot_id or size.value > len(value):
            raise OSError('invalid boot identity')
        return boot_id
    raise OSError('unsupported host')


def _start(pid):
    if sys.platform.startswith('linux'):
        with open('/proc/{}/stat'.format(pid), encoding='ascii') as stream:
            data = stream.read()
        return data[data.rindex(')') + 2:].split()[19]
    if sys.platform == 'darwin':
        class BSDInfo(ctypes.Structure):
            _fields_ = [(name, ctypes.c_uint32) for name in ('flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid', 'ruid', 'rgid', 'svuid', 'svgid', 'reserved')]
            _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
            _fields_ += [(name, ctypes.c_uint32) for name in ('nfiles', 'pgid', 'pjobc', 'tdev', 'tpgid')]
            _fields_ += [('nice', ctypes.c_int32), ('start_sec', ctypes.c_uint64), ('start_usec', ctypes.c_uint64)]
        lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        lib.proc_pidinfo.restype = ctypes.c_int
        info = BSDInfo()
        if lib.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info) or info.pid != pid:
            raise OSError('process identity unavailable')
        return '{}.{}'.format(info.start_sec, info.start_usec)
    raise OSError('unsupported host')


def identity_for(pid, nonce):
    if type(pid) is not int or pid <= 0 or not isinstance(nonce, str) or not nonce:
        raise ValueError('invalid process identity')
    return ProcessIdentity(_boot_id(), pid, _start(pid), nonce)


def inspect_identity(identity):
    try:
        actual = identity_for(identity.pid, identity.nonce)
        return 'alive' if actual == identity else 'unknown'
    except (OSError, ValueError, IndexError):
        return 'unknown'
