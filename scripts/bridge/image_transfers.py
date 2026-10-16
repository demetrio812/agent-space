"""Bounded, route-owned image staging. No client supplied filesystem paths."""
import base64
import hashlib
import os
from pathlib import Path
import re
import secrets
import stat
import threading
import time
try:
    from .bootstrap import _tree
    from .protocol import BridgeRejected
    from .session_actions import validate_management_route
except ImportError:
    from bootstrap import _tree
    from protocol import BridgeRejected
    from session_actions import validate_management_route

TOKEN=re.compile(r'^[0-9a-f]{32}$'); DIGEST=re.compile(r'^[0-9a-f]{64}$')
OWNED=re.compile(r'^ag-image-[0-9a-f]{32}\.(png|jpg|jpeg|gif|webp|bmp|part)$')
EXTENSIONS={'png','jpg','jpeg','gif','webp','bmp'}
MAX_IMAGE=16*1024*1024; MAX_CHUNK=256*1024

def validate_image_payload(op,payload):
    fields={'image.begin':{'extension','size','sha256'},'image.chunk':{'token','offset','bytes'},
            'image.finish':{'token'},'image.cancel':{'token'}}
    if not isinstance(payload,dict) or op not in fields or set(payload)!=fields[op]:raise BridgeRejected('invalid_request')
    if op=='image.begin':
        if (not isinstance(payload['extension'],str) or payload['extension'] not in EXTENSIONS
                or type(payload['size']) is not int or not 1<=payload['size']<=MAX_IMAGE
                or not isinstance(payload['sha256'],str) or not DIGEST.fullmatch(payload['sha256'])):raise BridgeRejected('invalid_request')
    else:
        if not isinstance(payload['token'],str) or not TOKEN.fullmatch(payload['token']):raise BridgeRejected('invalid_request')
        if op=='image.chunk':
            if type(payload['offset']) is not int or not 0<=payload['offset']<=MAX_IMAGE:raise BridgeRejected('invalid_request')
            value=payload['bytes']
            if not isinstance(value,str) or not 1<=len(value)<=4*((MAX_CHUNK+2)//3):raise BridgeRejected('invalid_request')
            try:data=base64.b64decode(value,validate=True)
            except (ValueError,TypeError):raise BridgeRejected('invalid_request')
            if not 1<=len(data)<=MAX_CHUNK or base64.b64encode(data).decode()!=value:raise BridgeRejected('invalid_request')
    return payload

def image_signature(data,extension):
    if extension=='png':return data.startswith(b'\x89PNG\r\n\x1a\n')
    if extension in ('jpg','jpeg'):return data.startswith(b'\xff\xd8\xff')
    if extension=='gif':return data.startswith((b'GIF87a',b'GIF89a'))
    if extension=='webp':return len(data)>=12 and data[:4]==b'RIFF' and data[8:12]==b'WEBP'
    if extension=='bmp':return data.startswith(b'BM')
    return False

class ImageTransfers:
    def __init__(self,api,root,clock=time.monotonic):
        self.api,self.root,self.clock=api,Path(root).absolute(),clock
        self.fd=_tree(self.root); self.pending={}; self.lock=threading.RLock(); self.closed=False
        self.reap()
    @property
    def active_count(self):
        with self.lock:return len(self.pending)
    def _member(self,route):
        validate_management_route('rename',route)
        if self.api.generation()!=route['generation']:raise BridgeRejected('generation_changed')
        self.api.member(route)
    def _discard(self,token):
        item=self.pending.pop(token,None)
        if item:
            os.close(item['fd'])
            try:os.unlink(item['name'],dir_fd=self.fd)
            except FileNotFoundError:pass
    def reap(self):
        with self.lock:
            if self.closed:return
            for token,item in list(self.pending.items()):
                if self.clock()-item['last']>=300:self._discard(token)
            active={v['name'] for v in self.pending.values()}
            for name in os.listdir(self.fd):
                if not OWNED.fullmatch(name) or name in active:continue
                try:
                    info=os.stat(name,dir_fd=self.fd,follow_symlinks=False)
                    ttl=300 if name.endswith('.part') else 86400
                    if stat.S_ISREG(info.st_mode) and info.st_uid==os.getuid() and time.time()-info.st_mtime>=ttl:os.unlink(name,dir_fd=self.fd)
                except FileNotFoundError:pass
    def operation(self,op,route,payload):
        validate_image_payload(op,payload); validate_management_route('rename',route)
        with self.lock:
            if self.closed:raise BridgeRejected('offline')
            self.reap()
            if op=='image.begin':
                self._member(route)
                if len(self.pending)>=4 or sum(v['size'] for v in self.pending.values())+payload['size']>64*1024*1024:raise BridgeRejected('busy')
                token=secrets.token_hex(16); name='ag-image-'+token+'.part'
                fd=os.open(name,os.O_RDWR|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=self.fd)
                os.fchmod(fd,0o600)
                self.pending[token]={**payload,'route':dict(route),'fd':fd,'name':name,'offset':0,'hash':hashlib.sha256(),'last':self.clock()}
                return {'token':token,'offset':0}
            token=payload['token']; item=self.pending.get(token)
            if item is None and op=='image.cancel':return {'cancelled':True}
            if item is None or item['route']!=route:raise BridgeRejected('route_changed')
            if op=='image.cancel':self._discard(token); return {'cancelled':True}
            try:
                self._member(route)
                info=os.stat(item['name'],dir_fd=self.fd,follow_symlinks=False); opened=os.fstat(item['fd'])
                if not stat.S_ISREG(info.st_mode) or (info.st_ino,info.st_dev)!=(opened.st_ino,opened.st_dev):raise BridgeRejected('invalid_request')
                if op=='image.chunk':
                    data=base64.b64decode(payload['bytes'],validate=True)
                    if payload['offset']!=item['offset'] or item['offset']+len(data)>item['size']:raise BridgeRejected('invalid_request')
                    view=memoryview(data)
                    while view:
                        count=os.write(item['fd'],view)
                        if count<=0:raise OSError('Short image write')
                        view=view[count:]
                    item['hash'].update(data); item['offset']+=len(data); item['last']=self.clock()
                    return {'offset':item['offset']}
                if item['offset']!=item['size'] or item['hash'].hexdigest()!=item['sha256']:raise BridgeRejected('invalid_request')
                if not image_signature(os.pread(item['fd'],12,0),item['extension']):raise BridgeRejected('invalid_request')
                self._member(route); os.utime(item['fd'],None); os.fsync(item['fd'])
                name='ag-image-'+secrets.token_hex(16)+'.'+item['extension']
                # Atomic no-replace publication, same directory and inode.
                os.link(item['name'],name,src_dir_fd=self.fd,dst_dir_fd=self.fd,follow_symlinks=False)
                committed=os.stat(name,dir_fd=self.fd,follow_symlinks=False)
                if not stat.S_ISREG(committed.st_mode) or (committed.st_ino,committed.st_dev)!=(opened.st_ino,opened.st_dev):
                    os.unlink(name,dir_fd=self.fd); raise BridgeRejected('invalid_request')
                result={'path':str(self.root/name),'size':item['size'],'sha256':item['sha256']}
                self._discard(token); return result
            except Exception:
                self._discard(token); raise
    def close(self):
        with self.lock:
            if self.closed:return
            for token in list(self.pending):self._discard(token)
            self.closed=True; os.close(self.fd)
