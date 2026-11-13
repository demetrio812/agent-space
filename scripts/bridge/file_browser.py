"""Account-permitted browsing and atomic, no-replace uploads; never terminal input."""
from contextlib import contextmanager
import base64
import ctypes
import errno
import sys
import hashlib
import itertools
import json
import os
from pathlib import Path
import re
import secrets
import stat
import threading
import time
try:
    from .protocol import BridgeRejected
    from .project_files import digest, revision, safe_name, MAX_FILE
except ImportError:
    from protocol import BridgeRejected
    from project_files import digest, revision, safe_name, MAX_FILE

MAX_UPLOAD=32*1024*1024;MAX_CHUNK=256*1024
HASH=re.compile(r'^[0-9a-f]{64}$');TOKEN=re.compile(r'^[0-9a-f]{32}$')

def name_ok(name):
    return isinstance(name,str) and name not in ('','.','..') and '/' not in name and safe_name(name) and len(name.encode())<=255

def path_ok(path,initial=False):
    return isinstance(path,str) and (initial and path in ('','~') or path.startswith('/')) and len(path.encode('utf-8',errors='replace'))<=4096 and not any(ord(c)<32 or 127<=ord(c)<160 or 0xd800<=ord(c)<=0xdfff for c in path)

def validate_payload(op,p):
    fields={'fs.list':{'path'},'fs.read':{'path','scope','name','revision'},'fs.begin':{'path','scope','name','size','sha256'},
            'fs.chunk':{'token','offset','bytes'},'fs.finish':{'token'},'fs.cancel':{'token'}}
    if not isinstance(p,dict) or op not in fields or set(p)!=fields[op]:raise BridgeRejected('invalid_request')
    if op in ('fs.list','fs.read','fs.begin'):
        if not path_ok(p['path'],op=='fs.list'):raise BridgeRejected('invalid_request')
        if op!='fs.list' and (not name_ok(p['name']) or not isinstance(p['scope'],str) or not HASH.fullmatch(p['scope'])):raise BridgeRejected('invalid_request')
        if op=='fs.read' and (not isinstance(p['revision'],str) or not HASH.fullmatch(p['revision'])):raise BridgeRejected('invalid_request')
        if op=='fs.begin' and (type(p['size']) is not int or not 0<=p['size']<=MAX_UPLOAD or not isinstance(p['sha256'],str) or not HASH.fullmatch(p['sha256'])):raise BridgeRejected('invalid_request')
    else:
        if not isinstance(p['token'],str) or not TOKEN.fullmatch(p['token']):raise BridgeRejected('invalid_request')
        if op=='fs.chunk':
            if type(p['offset']) is not int or not 0<=p['offset']<=MAX_UPLOAD or not isinstance(p['bytes'],str) or not 1<=len(p['bytes'])<=349528:raise BridgeRejected('invalid_request')
            try:data=base64.b64decode(p['bytes'],validate=True)
            except (ValueError,TypeError):raise BridgeRejected('invalid_request')
            if not 1<=len(data)<=MAX_CHUNK or base64.b64encode(data).decode()!=p['bytes']:raise BridgeRejected('invalid_request')
    return p

def open_directory(path):
    search=getattr(os,'O_SEARCH',0x40000000 if sys.platform=='darwin' else getattr(os,'O_PATH',os.O_RDONLY))
    fd=os.open('/',search|os.O_DIRECTORY)
    try:
        for index,part in enumerate(path.parts[1:]):
            access=os.O_RDONLY if index==len(path.parts)-2 else search
            new=os.open(part,access|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd);os.close(fd);fd=new
        if len(path.parts)==1:
            os.close(fd);fd=os.open('/',os.O_RDONLY|os.O_DIRECTORY)
        return fd
    except BaseException:os.close(fd);raise

def same_inode(info,expected):return stat.S_ISREG(info.st_mode) and (info.st_dev,info.st_ino)==expected

def unlink_owned(directory,name,identity):
    try:
        if same_inode(os.stat(name,dir_fd=directory,follow_symlinks=False),identity):os.unlink(name,dir_fd=directory)
    except FileNotFoundError:pass

def publish_exclusive(source_dir,source,destination_dir,destination):
    # Native exclusive rename also supports writable FAT/exFAT destinations
    # that cannot hard-link. Never fall back to an overwriting rename.
    libc=ctypes.CDLL(None,use_errno=True)
    name='renameatx_np' if sys.platform=='darwin' else 'renameat2'
    function=getattr(libc,name,None)
    if function is not None:
        function.argtypes=[ctypes.c_int,ctypes.c_char_p,ctypes.c_int,ctypes.c_char_p,ctypes.c_uint];function.restype=ctypes.c_int
        result=function(source_dir,os.fsencode(source),destination_dir,os.fsencode(destination),4 if sys.platform=='darwin' else 1)
        if result==0:return
        code=ctypes.get_errno()
        if code not in (errno.ENOSYS,errno.ENOTSUP,errno.EINVAL):raise OSError(code,os.strerror(code))
    try:os.link(source,destination,src_dir_fd=source_dir,dst_dir_fd=destination_dir,follow_symlinks=False)
    except OSError as error:
        if error.errno in (errno.ENOTSUP,errno.ENOSYS,errno.EPERM):raise BridgeRejected('file_upload_unsupported')
        raise

class FileBrowser:
    def __init__(self,api):self.api=api;self.pending={};self.lock=threading.RLock();self.closed=False
    @contextmanager
    def context(self,route,raw):
        fd=None
        try:
            row=self.api.member(route)
            cwd=row.get('foreground_cwd') or row.get('cwd')
            if not path_ok(cwd):raise BridgeRejected('file_unavailable')
            cwd=str(Path(cwd).resolve(strict=True))
            path=Path(cwd if raw=='' else Path.home() if raw=='~' else raw).resolve(strict=True)
            if not path_ok(str(path)):raise BridgeRejected('file_unavailable')
            fd=open_directory(path);info=os.fstat(fd)
            scope=digest([route,cwd,str(path),info.st_dev,info.st_ino])
            yield path,fd,scope
        except PermissionError:raise BridgeRejected('file_permission')
        except (OSError,ValueError,RuntimeError):raise BridgeRejected('file_unavailable')
        finally:
            if fd is not None:os.close(fd)
    def _check(self,route,path,scope):
        with self.context(route,str(path)) as current:
            if current[2]!=scope:raise BridgeRejected('file_changed')
    def listing(self,route,p):
        with self.context(route,p['path']) as (path,fd,scope):
            rows=[];limited=False;budget=0;deadline=time.monotonic()+4
            with os.scandir(fd) as scan:names=[e.name for e in itertools.islice(scan,4097)]
            if len(names)>4096:limited=True
            for name in names[:4096]:
                if time.monotonic()>deadline:limited=True;break
                if not name_ok(name) or name.startswith('.agentspace-upload-'):continue
                try:info=os.stat(name,dir_fd=fd,follow_symlinks=False)
                except OSError:continue
                kind='directory' if stat.S_ISDIR(info.st_mode) else 'file' if stat.S_ISREG(info.st_mode) else 'link' if stat.S_ISLNK(info.st_mode) else 'other'
                row={'name':name,'kind':kind,'size':max(0,min(info.st_size,2**53-1)),'revision':revision(info)}
                encoded=len(json.dumps(row,ensure_ascii=True).encode())
                if len(rows)>=1000 or budget+encoded>480*1024:limited=True;continue
                budget+=encoded;rows.append(row)
            self._check(route,path,scope)
            return {'path':str(path),'home':str(Path.home().resolve()),'scope':scope,'entries':sorted(rows,key=lambda r:(r['kind']!='directory',r['name'].casefold())),'limited':limited}
    def read(self,route,p):
        with self.context(route,p['path']) as (path,fd,scope):
            if p['scope']!=scope:raise BridgeRejected('file_changed')
            suffix=Path(p['name']).suffix.lower()
            if suffix not in ('.md','.markdown','.html','.htm'):raise BridgeRejected('unsupported')
            try:source=os.open(p['name'],os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=fd)
            except PermissionError:raise BridgeRejected('file_permission')
            except OSError:raise BridgeRejected('file_unavailable')
            with os.fdopen(source,'rb') as stream:
                before=os.fstat(stream.fileno())
                if not stat.S_ISREG(before.st_mode) or revision(before)!=p['revision']:raise BridgeRejected('file_changed')
                if before.st_size>MAX_FILE:raise BridgeRejected('file_too_large')
                data=stream.read(MAX_FILE+1)
                if len(data)>MAX_FILE:raise BridgeRejected('file_too_large')
                if revision(os.fstat(stream.fileno()))!=p['revision'] or revision(os.stat(p['name'],dir_fd=fd,follow_symlinks=False))!=p['revision']:raise BridgeRejected('file_changed')
            try:text=data.decode('utf-8-sig')
            except UnicodeError:raise BridgeRejected('file_encoding')
            self._check(route,path,scope);identifier=digest([scope,p['name']])
            result={'file':{'id':identifier,'name':p['name'],'path':p['name'],'kind':'html' if suffix in ('.html','.htm') else 'markdown','section':'files','feature':'','revision':p['revision']},
                    'document':{'scope':scope,'file':identifier,'revision':p['revision'],'text':text}}
            if len(json.dumps(result,ensure_ascii=True).encode())>1024*1024:raise BridgeRejected('file_too_large')
            return result
    def discard(self,token):
        item=self.pending.pop(token,None)
        if item:
            try:
                unlink_owned(item['stage'],item['temp'],item['identity'])
                try:
                    info=os.stat(item['stage_name'],dir_fd=item['dir'],follow_symlinks=False)
                    if stat.S_ISDIR(info.st_mode) and (info.st_dev,info.st_ino)==item['stage_identity']:os.rmdir(item['stage_name'],dir_fd=item['dir'])
                except (FileNotFoundError,OSError):pass
            finally:
                for key in ('fd','stage','dir'):os.close(item[key])
    def reap(self):
        with self.lock:
            for token,item in list(self.pending.items()):
                if time.monotonic()-item['last']>=300:self.discard(token)
    def operation(self,op,route,p):
        validate_payload(op,p)
        if self.closed:raise BridgeRejected('offline')
        if op=='fs.list':return self.listing(route,p)
        if op=='fs.read':return self.read(route,p)
        with self.lock:
            if self.closed:raise BridgeRejected('offline')
            self.reap()
            if op=='fs.begin':
                if len(self.pending)>=4 or sum(i['size'] for i in self.pending.values())+p['size']>64*1024*1024:raise BridgeRejected('busy')
                with self.context(route,p['path']) as (path,fd,scope):
                    if p['scope']!=scope:raise BridgeRejected('file_changed')
                    try:os.stat(p['name'],dir_fd=fd,follow_symlinks=False)
                    except FileNotFoundError:pass
                    else:raise BridgeRejected('file_exists')
                    token=secrets.token_hex(16);stage_name='.agentspace-upload-'+token;temp='content.part'
                    os.mkdir(stage_name,0o700,dir_fd=fd)
                    stage=os.open(stage_name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd)
                    try:source=os.open(temp,os.O_RDWR|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=stage)
                    except BaseException:os.close(stage);os.rmdir(stage_name,dir_fd=fd);raise
                    info=os.fstat(source);stage_info=os.fstat(stage)
                    self.pending[token]={**p,'route':dict(route),'path':str(path),'dir':os.dup(fd),'stage':stage,'stage_name':stage_name,'stage_identity':(stage_info.st_dev,stage_info.st_ino),'fd':source,'temp':temp,'identity':(info.st_dev,info.st_ino),'offset':0,'hash':hashlib.sha256(),'last':time.monotonic()}
                    return {'token':token,'offset':0}
            token=p['token'];item=self.pending.get(token)
            if item is None and op=='fs.cancel':return {'cancelled':True}
            if item is None or item['route']!=route:raise BridgeRejected('route_changed')
            if op=='fs.cancel':self.discard(token);return {'cancelled':True}
            published=False
            try:
                self._check(route,item['path'],item['scope'])
                opened=os.fstat(item['fd']);named=os.stat(item['temp'],dir_fd=item['stage'],follow_symlinks=False)
                if not stat.S_ISREG(named.st_mode) or (opened.st_dev,opened.st_ino)!=(named.st_dev,named.st_ino):raise BridgeRejected('file_changed')
                if op=='fs.chunk':
                    data=base64.b64decode(p['bytes'],validate=True)
                    if p['offset']!=item['offset'] or item['offset']+len(data)>item['size']:raise BridgeRejected('invalid_request')
                    view=memoryview(data)
                    while view:
                        count=os.write(item['fd'],view)
                        if count<=0:raise OSError('Short write')
                        view=view[count:]
                    item['hash'].update(data);item['offset']+=len(data);item['last']=time.monotonic()
                    return {'offset':item['offset']}
                if item['offset']!=item['size'] or item['hash'].hexdigest()!=item['sha256']:raise BridgeRejected('invalid_request')
                os.fsync(item['fd'])
                before=os.fstat(item['fd']);actual=hashlib.sha256();offset=0
                if before.st_size!=item['size']:raise BridgeRejected('file_changed')
                while offset<item['size']:
                    data=os.pread(item['fd'],min(MAX_CHUNK,item['size']-offset),offset)
                    if not data:raise BridgeRejected('file_changed')
                    actual.update(data);offset+=len(data)
                if actual.hexdigest()!=item['sha256'] or revision(before)!=revision(os.fstat(item['fd'])):raise BridgeRejected('file_changed')
                self._check(route,item['path'],item['scope'])
                if not same_inode(os.stat(item['temp'],dir_fd=item['stage'],follow_symlinks=False),item['identity']):raise BridgeRejected('file_changed')
                try:publish_exclusive(item['stage'],item['temp'],item['dir'],item['name'])
                except FileExistsError:raise BridgeRejected('file_exists')
                published=True
                final=os.stat(item['name'],dir_fd=item['dir'],follow_symlinks=False)
                if not stat.S_ISREG(final.st_mode) or (opened.st_dev,opened.st_ino)!=(final.st_dev,final.st_ino):
                    raise BridgeRejected('file_changed')
                result={'uploaded':True,'path':str(Path(item['path'])/item['name']),'size':item['size'],'sha256':item['sha256']}
                self.discard(token);return result
            except Exception as error:
                self.discard(token)
                if published:raise BridgeRejected('upload_uncertain')
                if isinstance(error,PermissionError):raise BridgeRejected('file_permission')
                if isinstance(error,OSError):raise BridgeRejected('file_unavailable')
                raise
    def close(self):
        with self.lock:
            self.closed=True
            for token in list(self.pending):self.discard(token)
