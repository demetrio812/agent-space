"""Read-only documents anchored to verified directory descriptors for each operation."""
from contextlib import contextmanager
from dataclasses import dataclass
import base64
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
SPEC_DOCUMENTS = {'requirements.md','design.md','tasks.md','bugfix.md'}


def validate_payload(op, payload):
    if not isinstance(payload,dict): raise BridgeRejected('invalid_request')
    if op=='files.list':
        if payload: raise BridgeRejected('invalid_request')
    elif op in ('files.read','files.download'):
        if set(payload)!={'scope','file'} or any(not isinstance(v,str) or not HEX.fullmatch(v) for v in payload.values()):
            raise BridgeRejected('invalid_request')
    else: raise BridgeRejected('invalid_request')


def digest(value):
    return hashlib.sha256(json.dumps(value,ensure_ascii=True,separators=(',',':')).encode()).hexdigest()


def revision(info):
    return digest([info.st_dev,info.st_ino,info.st_size,info.st_mtime_ns,info.st_ctime_ns])


def safe_name(value):
    try:
        return '\\' not in value and len(value.encode('utf-8'))<=512 and not any(ord(c)<32 or 127<=ord(c)<160 for c in value)
    except UnicodeError: return False


@dataclass(frozen=True)
class _Root:
    path: Path
    fd: int


def _open_absolute(path):
    # O_NOFOLLOW on only the last component does not protect ancestors.
    fd=os.open('/',os.O_RDONLY|os.O_DIRECTORY)
    try:
        for part in path.parts[1:]:
            new=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd)
            os.close(fd);fd=new
        if os.fstat(fd).st_uid!=os.getuid(): raise OSError('Unowned root')
        return fd
    except BaseException:
        os.close(fd);raise


class ProjectFiles:
    def __init__(self, api): self.api=api

    @staticmethod
    def _project_root(cwd):
        fd=os.dup(cwd.fd);path=cwd.path
        try:
            for _ in range(64):
                try: marker=os.stat('.git',dir_fd=fd,follow_symlinks=False)
                except OSError: marker=None
                if marker and (stat.S_ISDIR(marker.st_mode) or stat.S_ISREG(marker.st_mode)):
                    if path==cwd.path: return None
                    if os.fstat(fd).st_uid!=os.getuid(): raise OSError('Unowned project')
                    result=_Root(path,fd);fd=-1;return result
                if path.parent==path: break
                parent=os.open('..',os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd)
                os.close(fd);fd=parent;path=path.parent
            return None
        finally:
            if fd>=0: os.close(fd)

    @contextmanager
    def _context(self, route):
        roots=[]
        try:
            row=self.api.member(route);raw=row.get('foreground_cwd') or row.get('cwd')
            if not isinstance(raw,str) or not raw.startswith('/') or len(raw)>4096:
                raise BridgeRejected('file_unavailable')
            cwd=Path(raw).resolve(strict=True)
            if not safe_name(cwd.name or '/'): raise BridgeRejected('file_unavailable')
            roots.append(_Root(cwd,_open_absolute(cwd)))
            project=self._project_root(roots[0])
            if project is not None: roots.append(project)
            identities=[]
            for root in roots:
                info=os.fstat(root.fd);identities.append([str(root.path),info.st_dev,info.st_ino])
            scope=digest([str(cwd),identities,[route.get(k) for k in ('machine','session','targetHash','generation')]])
            yield scope,cwd,roots
        except (OSError,ValueError,RuntimeError): raise BridgeRejected('file_unavailable')
        finally:
            for root in roots: os.close(root.fd)

    @staticmethod
    def _directory(root,parts):
        fd=os.dup(root.fd)
        try:
            for part in parts:
                new=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd)
                os.close(fd);fd=new
                if os.fstat(fd).st_uid!=os.getuid(): raise OSError('Unowned folder')
            return fd
        except BaseException:
            os.close(fd);raise

    def _revalidate(self, route, scope):
        with self._context(route) as current:
            if current[0]!=scope: raise BridgeRejected('file_changed')

    def _discover(self, context):
        scope,cwd,roots=context;deadline=time.monotonic()+4
        items=[];locations={};seen=set();feature_ids=set();limited=False
        def check():
            if time.monotonic()>deadline: raise BridgeRejected('file_unavailable')
        def names(root,parts):
            nonlocal limited
            check()
            try: fd=self._directory(root,parts)
            except OSError: return []
            try:
                with os.scandir(fd) as scan: result=[entry.name for entry in itertools.islice(scan,2049)]
                if len(result)>2048: limited=True
                return sorted(n for n in result[:2048] if safe_name(n))
            finally: os.close(fd)
        def add(root,parts,section='files',feature=''):
            nonlocal limited
            check();suffix=Path(parts[-1]).suffix.lower()
            if suffix not in ('.md','.markdown','.html','.htm'): return
            try:
                folder=self._directory(root,parts[:-1])
                try: info=os.stat(parts[-1],dir_fd=folder,follow_symlinks=False)
                finally: os.close(folder)
            except OSError: return
            if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid(): return
            identity=(info.st_dev,info.st_ino)
            if identity in seen:return
            path='/'.join(parts)
            if root.path!=cwd:path='project/'+path
            if len(path.encode('utf-8'))>2048:limited=True;return
            if len(items)>=128:limited=True;return
            seen.add(identity);identifier=digest([scope,str(root.path),parts])
            items.append({'id':identifier,'name':parts[-1],'path':path,'kind':'html' if suffix in ('.html','.htm') else 'markdown',
                          'section':section,'feature':feature,'revision':revision(info)})
            locations[identifier]=(root,parts,revision(info))
        def docs(root,parts,depth):
            nonlocal limited
            for name in names(root,parts):
                if len(items)>=128:limited=True;break
                add(root,(*parts,name))
                if depth<3 and not name.startswith('.'):docs(root,(*parts,name),depth+1)
        # Canonical spec documents take precedence even if cwd is inside a spec.
        for root in roots:
            for base in [('.kiro','specs'),('.specs',)]:
                for feature in names(root,base):
                    try: folder=self._directory(root,(*base,feature))
                    except OSError: continue
                    try:
                        info=os.fstat(folder);identity=(info.st_dev,info.st_ino)
                    finally:os.close(folder)
                    if identity in feature_ids:continue
                    if len(feature_ids)>=64:limited=True;continue
                    feature_ids.add(identity)
                    for name in names(root,(*base,feature)):
                        if name in SPEC_DOCUMENTS:add(root,(*base,feature,name),'specs',feature)
        for root in roots:
            for name in names(root,()):add(root,(name,))
            docs(root,('docs',),1)
        check()
        return {'scope':scope,'folder':cwd.name or '/','files':sorted(items,key=lambda i:(i['section'],i['feature'],i['path'].lower())),
                'limited':limited},locations

    def listing(self, route):
        with self._context(route) as context:
            page,_=self._discover(context);self._revalidate(route,page['scope']);return page

    def _read_file(self, root, parts, expected, raw=False):
        directory=self._directory(root,parts[:-1])
        try:fd=os.open(parts[-1],os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=directory)
        finally:os.close(directory)
        with os.fdopen(fd,'rb') as source:
            info=os.fstat(source.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid():raise BridgeRejected('file_unavailable')
            if revision(info)!=expected:raise BridgeRejected('file_changed')
            if info.st_size>MAX_FILE:raise BridgeRejected('file_too_large')
            data=source.read(MAX_FILE+1)
            if len(data)>MAX_FILE:raise BridgeRejected('file_too_large')
            if revision(os.fstat(source.fileno()))!=expected:raise BridgeRejected('file_changed')
        if raw:return data
        try:return data.decode('utf-8-sig')
        except UnicodeError:raise BridgeRejected('file_encoding')

    def read(self, route, payload, download=False):
        validate_payload('files.read',payload)
        with self._context(route) as context:
            page,locations=self._discover(context)
            if payload['scope']!=page['scope']:raise BridgeRejected('file_changed')
            location=locations.get(payload['file'])
            if location is None:raise BridgeRejected('file_unavailable')
            try:
                text=self._read_file(*location,raw=True) if download else self._read_file(*location)
                _,after=self._discover(context)
                if after.get(payload['file'])!=location:raise BridgeRejected('file_changed')
                self._revalidate(route,page['scope'])
            except OSError:raise BridgeRejected('file_unavailable')
            result={'scope':page['scope'],'file':payload['file'],'revision':location[2]}
            result.update({'bytes':base64.b64encode(text).decode()} if download else {'text':text})
            if len(json.dumps(result,ensure_ascii=True).encode())>1024*1024:raise BridgeRejected('file_too_large')
            return result
