"""Bounded, read-only Git snapshots on the selected pane's computer."""
import difflib
import os
from pathlib import Path
import selectors
import signal
import stat
import subprocess
import time

try:
    from .protocol import BridgeRejected
    from .project_files import HEX, digest, revision, safe_name
    from .file_browser import open_directory
except ImportError:
    from protocol import BridgeRejected
    from project_files import HEX, digest, revision, safe_name
    from file_browser import open_directory

MAX_OUTPUT = 512 * 1024
MAX_PREVIEW = 256 * 1024


def validate_payload(op, payload):
    if op == 'changes.list' and isinstance(payload, dict) and not payload: return
    if (op == 'changes.read' and isinstance(payload, dict) and set(payload) == {'scope', 'file'}
            and all(isinstance(v, str) and HEX.fullmatch(v) for v in payload.values())): return
    raise BridgeRejected('invalid_request')


def _run(cwd, args, deadline=None):
    env = {k:v for k,v in os.environ.items() if not k.startswith('GIT_')}
    env.update(GIT_TERMINAL_PROMPT='0', GIT_OPTIONAL_LOCKS='0', GIT_LITERAL_PATHSPECS='1', GIT_NO_LAZY_FETCH='1', PAGER='cat', LC_ALL='C')
    command = ['git', '--no-pager', '-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null', *args]
    process = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
    data = bytearray(); deadline = min(time.monotonic() + 4, deadline or float('inf'))
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while True:
                remaining = deadline-time.monotonic()
                if remaining <= 0 or not selector.select(remaining): raise BridgeRejected('changes_timeout')
                chunk = os.read(process.stdout.fileno(), 8192)
                if not chunk: break
                data.extend(chunk)
                if len(data) > MAX_OUTPUT: raise BridgeRejected('changes_too_large')
        code = process.wait(timeout=max(.01, deadline-time.monotonic()))
        return code, bytes(data)
    except subprocess.TimeoutExpired: raise BridgeRejected('changes_timeout')
    finally:
        if process.poll() is None:
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass
        process.wait(); process.stdout.close()


class GitChanges:
    def __init__(self, api): self.api = api

    def _snapshot(self, route, deadline=None):
        deadline = deadline or time.monotonic() + 20
        row = self.api.member(route); raw = row.get('foreground_cwd') or row.get('cwd')
        if not isinstance(raw, str) or not raw.startswith('/') or not safe_name(raw) or len(raw) > 4096:
            raise BridgeRejected('file_unavailable')
        cwd = Path(raw).resolve(strict=True)
        code, root = _run(cwd, ['rev-parse', '--show-toplevel'], deadline)
        if code: return {'repository':False,'scope':digest([route,str(cwd)]),'folder':'','branch':'','entries':[],'limited':False}, None, []
        root = Path(os.fsdecode(root.rstrip(b'\n')))
        if not root.is_absolute(): raise BridgeRejected('file_unavailable')
        # Git status/diff can invoke configured clean filters. Disable every
        # configured filter before reading worktree state, not just textconv.
        _, keys = _run(root, ['config','--null','--name-only','--get-regexp',r'^filter\..*\.(clean|smudge|process|required)$'], deadline)
        overrides = []
        for key in keys.split(b'\0'):
            if key:
                name = key.decode('utf-8', 'strict')
                overrides.extend(['-c', name + ('=false' if name.endswith('.required') else '=')])
        def git(args): return _run(root, [*overrides, *args], deadline)
        code, raw_status = git(['status','--porcelain=v1','-z','--untracked-files=all','--ignore-submodules=all'])
        if code: raise BridgeRejected('changes_unavailable')
        _, branch = git(['symbolic-ref','-q','--short','HEAD'])
        _, head = git(['rev-parse','--verify','HEAD'])
        label = branch.decode('utf-8','replace').strip() or ('Detached '+head.decode('ascii','replace').strip()[:12])
        if not safe_name(label): label = 'Current branch'
        records = raw_status.split(b'\0'); entries = []; identities = []; limited = False; i = 0
        while i < len(records) and records[i]:
            record = records[i]; i += 1
            if len(record) < 4 or record[2:3] != b' ': raise BridgeRejected('changes_unavailable')
            xy = record[:2].decode('ascii'); name = os.fsdecode(record[3:]); old = ''
            if 'R' in xy or 'C' in xy:
                if i >= len(records): raise BridgeRejected('changes_unavailable')
                old = os.fsdecode(records[i]); i += 1
            if any(not safe_name(p) or len(p.encode('utf-8',errors='replace')) > 2048 or Path(p).is_absolute()
                   or any(c in ('', '.', '..') for c in p.split('/')) for p in [name, old] if p):
                limited = True; continue
            try: identity = revision(os.lstat(root/name))
            except FileNotFoundError: identity = 'missing'
            identities.append([name, old, xy, identity])
            groups = [('untracked','?')] if xy == '??' else [
                (section, code) for section,code in zip(('staged','unstaged'),xy) if code not in (' ', '?')]
            for section,status in groups:
                if len(entries) >= 500: limited = True; continue
                entries.append({'path':name,'oldPath':old,'section':section,'status':'U' if 'U' in xy or xy in ('AA','DD') else status})
        _, index_path = git(['rev-parse','--git-path','index'])
        index = Path(os.fsdecode(index_path.rstrip(b'\n')))
        if not index.is_absolute(): index = root/index
        try: index_id = revision(index.stat())
        except FileNotFoundError: index_id = 'missing'
        root_info = root.stat(); cwd_info = cwd.stat()
        scope = digest([route,str(cwd),cwd_info.st_dev,cwd_info.st_ino,str(root),root_info.st_dev,root_info.st_ino,
                        head.hex(),index_id,raw_status.hex(),identities])
        for entry in entries: entry['id'] = digest([scope,entry])
        return {'repository':True,'scope':scope,'folder':root.name,'branch':label[:256],
                'entries':entries,'limited':limited}, root, overrides

    def listing(self, route):
        try:
            page, _, _ = self._snapshot(route)
            self.api.member(route)
            return page
        except (OSError,ValueError,UnicodeError): raise BridgeRejected('changes_unavailable')

    def read(self, route, payload):
        validate_payload('changes.read', payload)
        deadline = time.monotonic() + 20
        try:
            page, root, overrides = self._snapshot(route, deadline)
            if page['scope'] != payload['scope']: raise BridgeRejected('changes_changed')
            entry = next((e for e in page['entries'] if e['id'] == payload['file']), None)
            if entry is None or root is None: raise BridgeRejected('changes_changed')
            notice = ''; data = b''
            path = root/entry['path']
            # Never follow symlinks in either the filename or its ancestors.
            try: directory = open_directory(path.parent) if entry['section'] != 'staged' else None
            except FileNotFoundError: directory = None
            try:
                try: info = os.stat(path.name, dir_fd=directory, follow_symlinks=False) if directory is not None else None
                except FileNotFoundError: info = None
                if info and not stat.S_ISREG(info.st_mode): notice = 'Preview unavailable for symbolic links or special files.'
                elif info and info.st_size > MAX_PREVIEW: notice = 'This file exceeds the 256 KiB diff preview limit.'
                elif entry['section'] == 'untracked':
                    source = os.open(path.name,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=directory)
                    with os.fdopen(source,'rb') as stream:
                        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode): raise BridgeRejected('changes_changed')
                        content = stream.read(MAX_PREVIEW+1)
                    if len(content) > MAX_PREVIEW: notice = 'This file exceeds the 256 KiB diff preview limit.'
                    elif b'\0' in content: notice = 'Binary file — no text diff available.'
                    else:
                        try: text = content.decode('utf-8')
                        except UnicodeError: notice = 'This file is not UTF-8 text.'
                        else: data = ''.join(difflib.unified_diff([],text.splitlines(keepends=True),fromfile='/dev/null',tofile='b/'+entry['path'])).encode()
                else:
                    args = ['diff','--no-ext-diff','--no-textconv','--no-color','--ignore-submodules=all']
                    if entry['section'] == 'staged': args.append('--cached')
                    args.extend(['--',entry['path']])
                    if entry['oldPath']: args.append(entry['oldPath'])
                    code, data = _run(root,[*overrides,*args], deadline)
                    if code: raise BridgeRejected('changes_unavailable')
            finally:
                if directory is not None: os.close(directory)
            if len(data) > MAX_PREVIEW: notice = 'This diff exceeds the 256 KiB preview limit.'; data = b''
            if b'\0' in data or any(line.startswith(b'Binary files ') and line.endswith(b' differ') for line in data.splitlines()):
                notice = 'Binary file — no text diff available.'; data = b''
            try: text = data.decode('utf-8')
            except UnicodeError: text = ''; notice = 'This diff is not UTF-8 text.'
            current, _, _ = self._snapshot(route, deadline)
            if current['scope'] != page['scope']: raise BridgeRejected('changes_changed')
            return {'scope':page['scope'],'file':entry['id'],'text':text,'notice':notice}
        except (OSError,ValueError,UnicodeError): raise BridgeRejected('changes_unavailable')
