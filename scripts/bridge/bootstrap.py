"""Self-contained trusted stdin installer. Standard library only."""
import base64
import errno
import hashlib
import io
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import stat
import sys
import zipfile

PROTOCOL = 'agentspace-bridge-v2'
MAX_PACKAGE_BYTES = 512 * 1024
MAX_RECORD_BYTES = 2 * 1024 * 1024
MODULES = {'git_metadata.py', '__main__.py', 'worker.py', 'protocol.py', 'local_api.py', 'bootstrap.py',
           'session_actions.py', 'image_transfers.py', 'gateway.py', 'launcher.py', 'gate_rules.py', 'catalog_gate.py', 'package.py'}
REQUIRED = {'__main__.py', 'worker.py', 'protocol.py', 'local_api.py', 'bootstrap.py', 'gate_rules.py', 'catalog_gate.py'}


def _unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result: raise ValueError('Duplicate JSON field')
        result[key] = value
    return result


def read_record(stream, limit=MAX_RECORD_BYTES):
    line = stream.readline(limit + 1)
    if not line: return None
    if len(line) > limit or not line.endswith(b'\n'):
        raise ValueError('Bridge record exceeds limit or is incomplete')
    try:
        value = json.loads(line.decode('utf-8', 'strict'), object_pairs_hook=_unique,
                           parse_constant=lambda _: (_ for _ in ()).throw(ValueError('Invalid number')))
    except RecursionError as error:
        raise ValueError('Bridge JSON nesting exceeds limit') from error
    if not isinstance(value, dict): raise ValueError('Bridge record must be an object')
    return value


def write_record(stream, value):
    raw = json.dumps(value, ensure_ascii=True, separators=(',', ':'), allow_nan=False).encode() + b'\n'
    if len(raw) > MAX_RECORD_BYTES: raise ValueError('Bridge record exceeds limit')
    stream.write(raw); stream.flush()


def validate_package(data, digest):
    if (not isinstance(digest, str) or not re.fullmatch('[0-9a-f]{64}', digest)
            or len(data) > MAX_PACKAGE_BYTES or hashlib.sha256(data).hexdigest() != digest):
        raise ValueError('Invalid bridge package')
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            entries = archive.infolist(); names = [entry.filename for entry in entries]
            if len(names) != len(set(names)) or set(names) - MODULES or not REQUIRED <= set(names):
                raise ValueError('Invalid bridge modules')
            if sum(e.file_size for e in entries) > MAX_PACKAGE_BYTES:
                raise ValueError('Bridge source exceeds limit')
            for entry in entries:
                mode = entry.external_attr >> 16
                if (entry.compress_type != zipfile.ZIP_STORED or entry.is_dir()
                        or stat.S_IFMT(mode) not in (0, stat.S_IFREG) or entry.flag_bits & 1):
                    raise ValueError('Unsafe bridge member')
                archive.read(entry)
    except (zipfile.BadZipFile, RuntimeError, EOFError) as error:
        raise ValueError('Invalid bridge archive') from error


def _tree(path, create=True):
    path = Path(path).absolute()
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for index, part in enumerate(path.parts[1:]):
            if part in ('', '.', '..'): raise ValueError('Unsafe cache path')
            try: child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            except FileNotFoundError:
                if not create: return None
                try: os.mkdir(part, 0o700, dir_fd=fd)
                except FileExistsError: pass
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            attributes = os.fstat(child)
            allowed_owner = attributes.st_uid in (0, os.getuid())
            writable = attributes.st_mode & 0o022
            sticky_system = attributes.st_uid == 0 and attributes.st_mode & stat.S_ISVTX
            if not allowed_owner or (writable and not sticky_system):
                os.close(child); raise ValueError('Unsafe cache ancestor')
            if index == len(path.parts) - 2 and (attributes.st_uid != os.getuid() or attributes.st_mode & 0o077):
                os.close(child); raise ValueError('Cache must be private to this account')
            os.close(fd); fd = child
        result, fd = fd, None
        return result
    except OSError as error:
        raise ValueError('Unsafe cache path') from error
    finally:
        if fd is not None: os.close(fd)


def _read_verified(parent, digest):
    if not re.fullmatch('[0-9a-f]{64}', digest): raise ValueError('Invalid package digest')
    try: folder = os.open(digest, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
    except FileNotFoundError: return None
    except OSError as error: raise ValueError('Unsafe package directory') from error
    try:
        info = os.fstat(folder)
        if info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError('Unsafe package permissions')
        if os.listdir(folder) != ['bridge.pyz']: raise ValueError('Unexpected cached files')
        try: fd = os.open('bridge.pyz', os.O_RDONLY | os.O_NOFOLLOW, dir_fd=folder)
        except OSError as error: raise ValueError('Unsafe package file') from error
        try:
            info = os.fstat(fd)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or info.st_mode & 0o077 or info.st_size > MAX_PACKAGE_BYTES):
                raise ValueError('Unsafe package file')
            with os.fdopen(os.dup(fd), 'rb') as source: data = source.read(MAX_PACKAGE_BYTES + 1)
            validate_package(data, digest)
            os.lseek(fd, 0, os.SEEK_SET)
            result, fd = fd, None
            return result
        finally:
            if fd is not None: os.close(fd)
    finally: os.close(folder)


def cached_package(cache_root, digest):
    parent = _tree(cache_root, create=False)
    if parent is None: return None
    try:
        fd = _read_verified(parent, digest)
        if fd is None: return None
        os.close(fd)
        return Path(cache_root) / digest / 'bridge.pyz'
    finally: os.close(parent)


def install_package(cache_root, data, digest):
    validate_package(data, digest)
    parent = _tree(cache_root)
    staging = '.install-' + secrets.token_hex(16)
    stage = None
    try:
        existing = _read_verified(parent, digest)
        if existing is not None:
            os.close(existing); return Path(cache_root) / digest / 'bridge.pyz'
        os.mkdir(staging, 0o700, dir_fd=parent)
        stage = os.open(staging, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
        fd = os.open('bridge.pyz', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=stage)
        with os.fdopen(fd, 'wb') as target:
            target.write(data); target.flush(); os.fsync(target.fileno())
        os.fsync(stage)
        try: os.rename(staging, digest, src_dir_fd=parent, dst_dir_fd=parent)
        except OSError as error:
            if error.errno not in (errno.EEXIST, errno.ENOTEMPTY): raise
        os.fsync(parent)
        verified = _read_verified(parent, digest)
        if verified is None: raise ValueError('Bridge was not published')
        os.close(verified)
        return Path(cache_root) / digest / 'bridge.pyz'
    finally:
        if stage is not None:
            # Remove only our still-named staging directory, using its open fd.
            try:
                check = os.stat(staging, dir_fd=parent, follow_symlinks=False)
                if check.st_ino == os.fstat(stage).st_ino:
                    os.unlink('bridge.pyz', dir_fd=stage); os.rmdir(staging, dir_fd=parent)
            except FileNotFoundError: pass
            os.close(stage)
        os.close(parent)


def validate_config(config):
    allowed = {'role','lane','herdr','socket','generationStyle','allowInput','allowManagement','allowImages','herdrSession','machine','targetHash'}
    if not isinstance(config, dict) or set(config) - allowed:
        raise ValueError('Invalid bridge configuration')
    config=dict(config)
    if config.get('role') not in ('gateway','local') or config.get('lane') not in ('discovery','input','streams','transfer'):
        raise ValueError('Invalid bridge lane or role')
    if config.get('generationStyle') not in ('ssh','native','peer'):
        raise ValueError('Invalid generation style')
    for name in ('herdr','socket'):
        value = config.get(name, '')
        if isinstance(value,str) and value.startswith('~/'):
            value=str(Path.home()/value[2:]); config[name]=value
        if not isinstance(value, str) or len(value.encode()) > 4096 or '\0' in value or (value and not value.startswith('/')):
            raise ValueError('Invalid Herdr path')
    if type(config.get('allowInput', True)) is not bool: raise ValueError('Invalid input capability')
    if type(config.get('allowImages',False)) is not bool: raise ValueError('Invalid image capability')
    if config.get('allowImages',False) and not config.get('allowInput',True): raise ValueError('Images require write permission')
    if type(config.get('allowManagement',False)) is not bool: raise ValueError('Invalid management capability')
    if config.get('allowManagement',False) and not config.get('allowInput',True): raise ValueError('Management requires write permission')
    if 'machine' in config and (not isinstance(config['machine'],str) or not re.fullmatch('[0-9a-f]{32}',config['machine'])): raise ValueError('Invalid machine')
    if 'targetHash' in config and (not isinstance(config['targetHash'],str) or not re.fullmatch('[0-9a-f]{64}',config['targetHash'])): raise ValueError('Invalid target')
    session=config.get('herdrSession','default')
    if not isinstance(session,str) or not re.fullmatch('[A-Za-z0-9_.-]{1,64}',session) or session in ('.','..'):
        raise ValueError('Invalid Herdr session')
    return dict(config)


def main():
    source, output = sys.stdin.buffer, sys.stdout.buffer
    try:
        row = read_record(source)
        if (row is None or set(row) != {'type','protocol','digest','nonce','config'}
                or row['type'] != 'bootstrap' or row['protocol'] != PROTOCOL
                or not re.fullmatch('[0-9a-f]{64}', row['digest'])
                or not re.fullmatch('[0-9a-f]{32}', row['nonce'])):
            raise ValueError('Invalid bootstrap')
        config = validate_config(row['config']); digest = row['digest']
        cache = Path.home() / '.cache' / 'agentspace' / 'bridges'
        needed = cached_package(cache, digest) is None
        write_record(output, {'type':'cache','digest':digest,'needed':needed})
        if needed:
            package = read_record(source)
            if (package is None or set(package) != {'type','digest','bytes'}
                    or package['type'] != 'package' or package['digest'] != digest
                    or not isinstance(package['bytes'], str) or len(package['bytes']) > 699052):
                raise ValueError('Incomplete bridge upload')
            data = base64.b64decode(package['bytes'], validate=True)
            install_package(cache, data, digest)
        parent = _tree(cache, create=False)
        try: fd = _read_verified(parent, digest)
        finally: os.close(parent)
        if fd is None: raise ValueError('Missing bridge package')
        os.set_inheritable(fd, True)
        config.update(nonce=row['nonce'], digest=digest)
        # Execute the verified open archive rather than re-opening a replaceable path.
        encoded = base64.b64encode(json.dumps(config, separators=(',', ':')).encode()).decode()
        os.execv(sys.executable, [sys.executable, '-B', f'/dev/fd/{fd}', encoded])
    except Exception:
        write_record(output, {'type':'bootstrap_error','code':'setup_required'})
        return 1
    return 0


if __name__ == '__main__': sys.exit(main())
