"""Read-only project documents derived from an exact Herdr pane, never client paths."""
import hashlib
import itertools
import json
import os
from pathlib import Path
import re
import stat
import time

try:
    from .protocol import BridgeRejected
except ImportError:
    from protocol import BridgeRejected

HEX = re.compile(r'^[0-9a-f]{64}$')
MAX_FILE = 256 * 1024


def validate_payload(op, payload):
    if not isinstance(payload, dict): raise BridgeRejected('invalid_request')
    if op == 'files.list':
        if payload: raise BridgeRejected('invalid_request')
    elif op == 'files.read':
        if set(payload) != {'scope','file'} or any(not isinstance(v,str) or not HEX.fullmatch(v) for v in payload.values()):
            raise BridgeRejected('invalid_request')
    else: raise BridgeRejected('invalid_request')


def digest(value):
    return hashlib.sha256(json.dumps(value,ensure_ascii=True,separators=(',',':')).encode()).hexdigest()


def revision(info):
    return digest([info.st_dev,info.st_ino,info.st_size,info.st_mtime_ns,info.st_ctime_ns])


def safe_name(value):
    try: return len(value.encode('utf-8')) <= 512 and not any(ord(c)<32 or 127<=ord(c)<160 for c in value)
    except UnicodeError: return False


class ProjectFiles:
    def __init__(self, api): self.api = api

    def _context(self, route):
        row = self.api.member(route)
        raw = row.get('foreground_cwd') or row.get('cwd')
        if not isinstance(raw,str) or not raw.startswith('/') or len(raw)>4096:
            raise BridgeRejected('file_unavailable')
        try:
            cwd = Path(raw).resolve(strict=True)
            if not cwd.is_dir(): raise OSError('Not a folder')
            project = cwd
            for candidate in itertools.islice((cwd,*cwd.parents),64):
                if (candidate/'.git').exists(): project=candidate; break
            roots = [cwd] if project==cwd else [cwd,project]
            identities=[]
            for root in roots:
                fd=self._directory(root,())
                try:
                    info=os.fstat(fd); identities.append([str(root),info.st_dev,info.st_ino])
                finally: os.close(fd)
            return digest([str(cwd),identities]),cwd,roots
        except (OSError,ValueError,RuntimeError): raise BridgeRejected('file_unavailable')

    @staticmethod
    def _directory(root, parts):
        fd=os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
        try:
            if os.fstat(fd).st_uid != os.getuid(): raise OSError('Unowned folder')
            for part in parts:
                new=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd)
                os.close(fd); fd=new
                if os.fstat(fd).st_uid != os.getuid(): raise OSError('Unowned folder')
            return fd
        except BaseException:
            os.close(fd); raise

    def _discover(self, route):
        deadline=time.monotonic()+4
        scope,cwd,roots=self._context(route)
        items=[]; locations={}; seen=set(); limited=False
        def names(root,parts):
            nonlocal limited
            if time.monotonic()>deadline: raise BridgeRejected('file_unavailable')
            try: fd=self._directory(root,parts)
            except OSError: return []
            try:
                with os.scandir(fd) as scan:
                    result=[entry.name for entry in itertools.islice(scan,2049)]
                if len(result)>2048: limited=True
                return sorted(n for n in result[:2048] if safe_name(n))
            finally: os.close(fd)
        def add(root,parts,section='files',feature=''):
            nonlocal limited
            suffix=Path(parts[-1]).suffix.lower()
            if suffix not in ('.md','.markdown','.html','.htm'): return
            if section=='specs' and suffix not in ('.md','.markdown'): return
            try:
                folder=self._directory(root,parts[:-1])
                try: info=os.stat(parts[-1],dir_fd=folder,follow_symlinks=False)
                finally: os.close(folder)
            except OSError: return
            if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid(): return
            identity=(info.st_dev,info.st_ino)
            if identity in seen: return
            seen.add(identity)
            if len(items)>=128: limited=True; return
            path='/'.join(parts)
            if root!=cwd: path='project/'+path
            identifier=digest([scope,str(root),parts])
            items.append({'id':identifier,'name':parts[-1],'path':path,
                          'kind':'html' if suffix in ('.html','.htm') else 'markdown',
                          'section':section,'feature':feature,'revision':revision(info)})
            locations[identifier]=(root,parts,revision(info))
        def docs(root,parts,depth):
            for name in names(root,parts):
                if len(items)>=128:
                    nonlocal_limited[0]=True; break
                add(root,(*parts,name))
                if depth<3 and not name.startswith('.'):
                    # Opening directory descriptors rejects files and symlinks.
                    docs(root,(*parts,name),depth+1)
        nonlocal_limited=[False]
        for root in roots:
            for name in names(root,()): add(root,(name,))
            docs(root,('docs',),1)
            for base in [('.kiro','specs'),('.specs',)]:
                features=names(root,base)
                if len(features)>64: limited=True
                for feature in features[:64]:
                    for name in names(root,(*base,feature)):
                        add(root,(*base,feature,name),'specs',feature)
        if self._context(route)[0]!=scope: raise BridgeRejected('file_changed')
        if time.monotonic()>deadline: raise BridgeRejected('file_unavailable')
        return {'scope':scope,'folder':cwd.name or '/',
                'files':sorted(items,key=lambda i:(i['section'],i['feature'],i['path'].lower())),
                'limited':limited or nonlocal_limited[0]},locations

    def listing(self, route):
        try: return self._discover(route)[0]
        except OSError: raise BridgeRejected('file_unavailable')

    def _read_file(self, root, parts, expected):
        directory=self._directory(root,parts[:-1])
        try: fd=os.open(parts[-1],os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=directory)
        finally: os.close(directory)
        with os.fdopen(fd,'rb') as source:
            info=os.fstat(source.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid(): raise BridgeRejected('file_unavailable')
            if revision(info)!=expected: raise BridgeRejected('file_changed')
            if info.st_size>MAX_FILE: raise BridgeRejected('file_too_large')
            data=source.read(MAX_FILE+1)
            if len(data)>MAX_FILE: raise BridgeRejected('file_too_large')
            if revision(os.fstat(source.fileno()))!=expected: raise BridgeRejected('file_changed')
        try: return data.decode('utf-8-sig')
        except UnicodeError: raise BridgeRejected('file_encoding')

    def read(self, route, payload):
        validate_payload('files.read',payload)
        page,locations=self._discover(route)
        if payload['scope']!=page['scope']: raise BridgeRejected('file_changed')
        location=locations.get(payload['file'])
        if location is None: raise BridgeRejected('file_unavailable')
        try:
            text=self._read_file(*location)
            refreshed,locations_after=self._discover(route)
            if refreshed['scope']!=page['scope'] or locations_after.get(payload['file'])!=location:
                raise BridgeRejected('file_changed')
        except OSError: raise BridgeRejected('file_unavailable')
        result={'scope':page['scope'],'file':payload['file'],'revision':location[2],'text':text}
        if len(json.dumps(result,ensure_ascii=True).encode())>1024*1024: raise BridgeRejected('file_too_large')
        return result
