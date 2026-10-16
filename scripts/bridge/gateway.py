"""One-hop saved-machine gateway; independent bounded peer workers per lane."""
import base64
from collections import OrderedDict
from contextlib import contextmanager
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
import hashlib
import io
import json
import os
from pathlib import Path
import queue
import re
import secrets
import shlex
import subprocess
import sys
import threading
import time
import zipfile

try:
    from .image_transfers import validate_image_payload
    from .session_actions import MANAGEMENT, SessionActions, validate_management_route, validate_action, check_worker_origin
    from .launcher import launch_command
    from .worker import LocalWorker, stop_process
    from .protocol import PROTOCOL, BridgeRejected, DeliveryUncertain, read_record, write_record
    from .gate_rules import gate
except ImportError:
    from image_transfers import validate_image_payload
    from session_actions import MANAGEMENT, SessionActions, validate_management_route, validate_action, check_worker_origin
    from launcher import launch_command
    from worker import LocalWorker, stop_process
    from protocol import PROTOCOL, BridgeRejected, DeliveryUncertain, read_record, write_record
    from gate_rules import gate

MACHINE_ID = re.compile(r'^[0-9a-f]{32}$')
SESSION = re.compile(r'^[A-Za-z0-9_.-]{1,64}$')
TARGET = re.compile(r'^[A-Za-z0-9_.@:/\[\]%+-]{1,1024}$')


@dataclass(frozen=True)
class Machine:
    id: str
    label: str
    target: str
    session: str
    enabled: bool
    error: str = ''

    @property
    def target_hash(self):
        return hashlib.sha256(json.dumps([self.target,self.session],separators=(',',':'),ensure_ascii=True).encode()).hexdigest()


def validate_machine(machine):
    if (not isinstance(machine.id,str) or not MACHINE_ID.fullmatch(machine.id)
            or not isinstance(machine.target,str) or not TARGET.fullmatch(machine.target)
            or machine.target.startswith('-') or not isinstance(machine.session,str)
            or not SESSION.fullmatch(machine.session) or machine.session in ('.','..')
            or not isinstance(machine.label,str) or len(machine.label.encode())>128
            or any(ord(c)<32 or 127<=ord(c)<160 for c in machine.label)
            or type(machine.enabled) is not bool):
        raise BridgeRejected('invalid_request')
    return machine


def ssh_arguments(machine, bootstrap):
    validate_machine(machine)
    command=launch_command(bootstrap)
    return ['ssh','-T','-o','BatchMode=yes','-o','NumberOfPasswordPrompts=0',
            '-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=8','-o','ConnectionAttempts=1',
            '-o','ServerAliveInterval=15','-o','ServerAliveCountMax=4','--',machine.target,command]


class MachineRegistry:
    def __init__(self,binary,env): self.binary,self.env=binary,env
    def read(self):
        try:
            data=gate.bounded_catalog(self.binary,self.env,('machine','list','--json'))
            rows=json.loads(data)
            if not isinstance(rows,list) or len(rows)>64: raise ValueError('Invalid machines')
            result=[]; identifiers=set()
            for row in rows:
                if not isinstance(row,dict): raise ValueError('Invalid machine')
                identifier=row.get('id')
                if not isinstance(identifier,str) or not MACHINE_ID.fullmatch(identifier) or identifier in identifiers:
                    raise ValueError('Invalid or duplicate machine identity')
                identifiers.add(identifier)
                try: machine=validate_machine(Machine(identifier,row['label'],row['target'],row['session'],row['enabled']))
                except (BridgeRejected,KeyError,TypeError,UnicodeError):
                    label=row.get('label','Saved computer')
                    if not isinstance(label,str): label='Saved computer'
                    label=''.join(c for c in label if ord(c)>=32 and not 127<=ord(c)<160).encode()[:128].decode('utf-8','ignore')
                    target=row.get('target',''); session=row.get('session','default')
                    if not isinstance(target,str) or len(target)>1024: target=''
                    if not isinstance(session,str) or not SESSION.fullmatch(session): session='default'
                    machine=Machine(identifier,label,target,session,row.get('enabled') is not False,'unsupported')
                result.append(machine)
            return result
        except BridgeRejected: raise
        except (OSError,ValueError,KeyError,TypeError,RuntimeError): raise BridgeRejected('setup_required')

    def require(self,route):
        if not isinstance(route,dict): raise BridgeRejected('invalid_request')
        matches=[m for m in self.read() if m.id==route.get('machine')]
        if len(matches)!=1: raise BridgeRejected('route_changed')
        machine=matches[0]
        if machine.error: raise BridgeRejected(machine.error)
        if (not machine.enabled or machine.session!=route.get('session')
                or machine.target_hash!=route.get('targetHash')):
            raise BridgeRejected('route_changed')
        return machine


class PeerWorker:
    def __init__(self,process,machine,lane,package,config,on_close=lambda _:None):
        self.process,self.machine,self.lane=process,machine,lane
        self.nonce=config['nonce']; self.closed=threading.Event(); self.lock=threading.RLock()
        self.pending={}; self.callbacks={}; self._counter=0; self._ready=queue.Queue(maxsize=2)
        self._errors=bytearray(); self._on_close=on_close; self._active=0
        self._reader=threading.Thread(target=self._read,daemon=True)
        self._stderr=threading.Thread(target=self._drain,daemon=True)
        self._reader.start(); self._stderr.start()
        try:
            bootstrap={'type':'bootstrap','protocol':PROTOCOL,'digest':config['digest'],
                       'nonce':self.nonce,'config':{k:v for k,v in config.items() if k not in ('nonce','digest')}}
            write_record(process.stdin,bootstrap)
            cache=self._ready.get(timeout=12)
            if not isinstance(cache,dict) or cache.get('type')!='cache' or cache.get('digest')!=config['digest']:
                raise BridgeRejected(self.failure_code())
            if type(cache.get('needed')) is not bool: raise BridgeRejected('unsupported')
            if cache['needed']:
                write_record(process.stdin,{'type':'package','digest':config['digest'],'bytes':base64.b64encode(package).decode()})
            hello=self._ready.get(timeout=12)
            if (not isinstance(hello,dict) or hello.get('type')!='hello' or hello.get('protocol')!=PROTOCOL
                    or hello.get('nonce')!=self.nonce or hello.get('lane')!=lane
                    or hello.get('digest')!=config['digest'] or not isinstance(hello.get('capabilities'),dict)):
                raise BridgeRejected('unsupported')
            self.hello=hello
        except queue.Empty:
            self.close(); raise BridgeRejected('timeout')
        except Exception:
            self.close(); raise

    @property
    def busy(self):
        with self.lock: return self._active>0 or bool(self.callbacks)

    def failure_code(self):
        text=bytes(self._errors).lower()
        if b'host key' in text or b'host identification' in text: return 'host_key'
        if b'permission denied' in text or b'authentication' in text: return 'auth_required'
        if b'python3' in text and (b'not found' in text or b'no such' in text): return 'setup_required'
        return 'offline'

    def _drain(self):
        try:
            while True:
                chunk=os.read(self.process.stderr.fileno(),8192)
                if not chunk: return
                self._errors.extend(chunk)
                if len(self._errors)>65536:
                    del self._errors[65536:]; self.close(); return
        except (OSError,ValueError): return

    def _read(self):
        try:
            while not self.closed.is_set():
                row=read_record(self.process.stdout)
                if row is None: break
                if row.get('type') in ('cache','hello','bootstrap_error'):
                    try: self._ready.put_nowait(row)
                    except queue.Full: break
                    continue
                if row.get('nonce')!=self.nonce or row.get('lane')!=self.lane: break
                with self.lock:
                    pending=self.pending.get(row.get('id')); callback=self.callbacks.get(row.get('id'))
                if row.get('type')=='reply' and pending is not None:
                    try: pending.put_nowait(row)
                    except queue.Full: break
                elif row.get('type')=='event' and callback is not None:
                    callback(row)
                    if row.get('event')=='closed':
                        with self.lock: self.callbacks.pop(row['id'],None)
                else: break
        except (OSError,ValueError): pass
        finally:
            if self._stderr is not threading.current_thread(): self._stderr.join(timeout=.2)
            try: self._ready.put_nowait(None)
            except queue.Full: pass
            self.close()

    def request(self,row,on_event=None,timeout=6):
        op=row['op']; submitted=False
        with self.lock:
            if self.closed.is_set(): raise BridgeRejected('offline')
            if len(self.pending)>=32: raise BridgeRejected('busy')
            self._counter+=1; identifier=str(self._counter)
            response=queue.Queue(maxsize=1); self.pending[identifier]=response; self._active+=1
            if on_event is not None: self.callbacks[identifier]=on_event
            wire={**row,'type':'request','protocol':PROTOCOL,'nonce':self.nonce,'lane':self.lane,'id':identifier}
            try:
                submitted=True; write_record(self.process.stdin,wire)
            except (OSError,ValueError):
                self.pending.pop(identifier,None); self.callbacks.pop(identifier,None); self._active-=1
                if op in ('input','send','click') or op in MANAGEMENT: raise DeliveryUncertain()
                raise BridgeRejected('offline')
        success=False
        try:
            reply=response.get(timeout=timeout)
            if (not isinstance(reply,dict) or reply.get('id')!=identifier
                    or reply.get('nonce')!=self.nonce or reply.get('lane')!=self.lane
                    or type(reply.get('ok')) is not bool): raise ValueError('Missing acknowledgement')
            if not reply['ok']:
                error=reply.get('error')
                if not isinstance(error,dict) or type(error.get('dispatched')) is not bool:
                    raise ValueError('Invalid rejection')
                if (op in ('input','send','click') or op in MANAGEMENT) and error['dispatched']: raise DeliveryUncertain()
                raise BridgeRejected(error.get('code','offline'),error['dispatched'])
            result=reply.get('result')
            if not isinstance(result,dict): raise ValueError('Invalid result')
            if op in ('input','send','click') and result.get('sent') is not True: raise ValueError('Missing sent acknowledgement')
            if op in MANAGEMENT and result.get('applied') is not True: raise ValueError('Missing management acknowledgement')
            success=True
            return result
        except (queue.Empty,ValueError):
            self.close()
            if submitted and (op in ('input','send','click') or op in MANAGEMENT): raise DeliveryUncertain()
            raise BridgeRejected('timeout')
        finally:
            with self.lock:
                self.pending.pop(identifier,None); self._active-=1
                if not success: self.callbacks.pop(identifier,None)

    def close(self):
        with self.lock:
            if self.closed.is_set(): return
            self.closed.set(); pending=list(self.pending.values()); callbacks=list(self.callbacks.values()); self.callbacks.clear()
        for target in pending:
            try: target.put_nowait(None)
            except queue.Full: pass
        for callback in callbacks:
            callback({'type':'event','event':'closed','value':{'reason':'Computer disconnected.'}})
        stop_process(self.process); self._on_close(self.process)


class PeerConnector:
    def __init__(self,package,bootstrap,allow_input=True,allow_management=False,allow_images=False):
        self.package,self.bootstrap=package,bootstrap
        self.allow_images=allow_images and allow_input
        self.allow_input=allow_input; self.allow_management=allow_management and allow_input
        self.digest=hashlib.sha256(package).hexdigest()
        self.closed=threading.Event(); self.lock=threading.Lock(); self.processes=set()
    def open(self,machine,lane):
        args=ssh_arguments(machine,self.bootstrap)
        config={'role':'local','lane':lane,'herdr':'','socket':'','herdrSession':machine.session,
                'generationStyle':'peer','allowImages':self.allow_images,'allowInput':self.allow_input,'allowManagement':self.allow_management,
                'machine':machine.id,'targetHash':machine.target_hash,'nonce':secrets.token_hex(16),'digest':self.digest}
        with self.lock:
            if self.closed.is_set(): raise BridgeRejected('offline')
            process=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
            self.processes.add(process)
        try:
            worker=PeerWorker(process,machine,lane,self.package,config,on_close=self.retire)
            if self.closed.is_set(): worker.close(); raise BridgeRejected('offline')
            return worker
        except Exception:
            stop_process(process); self.retire(process); raise
    def retire(self,process):
        with self.lock: self.processes.discard(process)
    def close(self):
        with self.lock: self.closed.set(); processes=list(self.processes)
        closers=[threading.Thread(target=stop_process,args=(p,),daemon=True) for p in processes]
        for thread in closers: thread.start()
        for thread in closers: thread.join(timeout=2.2)


class _Opening:
    def __init__(self): self.ready=threading.Event(); self.worker=None; self.error=None


class PeerPool:
    def __init__(self,connector,limit=16):
        self.connector,self.limit=connector,limit
        self.lock=threading.RLock(); self.closed=False
        self.workers=OrderedDict(); self.opening={}; self.reservations={}; self.starts=threading.BoundedSemaphore(4)
    @contextmanager
    def lease(self,machine,lane,protected):
        key=(machine.id,machine.target_hash,machine.session,lane)
        worker=self.acquire(machine,lane,protected,_reserve=True)
        try: yield worker
        finally:
            with self.lock:
                count=self.reservations.get(key,0)-1
                if count>0: self.reservations[key]=count
                else: self.reservations.pop(key,None)

    def acquire(self,machine,lane,protected,_reserve=False):
        key=(machine.id,machine.target_hash,machine.session,lane); victim=None; owner=False
        with self.lock:
            if self.closed: raise BridgeRejected('offline')
            worker=self.workers.get(key)
            if worker is not None:
                if worker.closed.is_set(): self.workers.pop(key)
                else:
                    self.workers.move_to_end(key)
                    if _reserve: self.reservations[key]=self.reservations.get(key,0)+1
                    return worker
            slot=self.opening.get(key)
            if slot is None:
                if len(self.workers)+len(self.opening)>=self.limit:
                    candidates=[k for k,w in self.workers.items() if not w.busy and not self.reservations.get(k) and k[0] not in protected]
                    if not candidates: raise BridgeRejected('busy')
                    victim=self.workers.pop(candidates[0])
                slot=_Opening(); self.opening[key]=slot; owner=True
        if not owner:
            if not slot.ready.wait(25): raise BridgeRejected('timeout')
            if slot.error: raise slot.error
            return self.acquire(machine,lane,protected,_reserve=_reserve)
        try:
            if victim: victim.close()
            with self.starts:
                with self.lock:
                    if self.closed: raise BridgeRejected('offline')
                worker=self.connector.open(machine,lane)
            with self.lock:
                if self.closed:
                    worker.close(); raise BridgeRejected('offline')
                self.workers[key]=worker; slot.worker=worker
                if _reserve: self.reservations[key]=self.reservations.get(key,0)+1
            return worker
        except Exception as error:
            slot.error=error; raise
        finally:
            with self.lock: self.opening.pop(key,None); slot.ready.set()
    def close(self):
        with self.lock:
            self.closed=True; workers=list(self.workers.values()); self.workers.clear()
        self.connector.close()
        for worker in workers: worker.close()


class GatewayWorker(LocalWorker):
    def __init__(self,config,output,registry=None,connector=None):
        super().__init__(config,output)
        self.registry=registry or MachineRegistry(config['herdr'],dict(os.environ,HERDR_SOCKET_PATH=config['socket']))
        if connector is None:
            # On macOS /dev/fd opens share the inherited descriptor offset;
            # zipimport has already sought in it. pread reads immutable bytes
            # from zero without disturbing imports or following another path.
            if re.fullmatch(r'/dev/fd/[0-9]+',sys.argv[0]):
                package=os.pread(int(sys.argv[0].rsplit('/',1)[1]),512*1024+1,0)
            else:
                with open(sys.argv[0],'rb') as source: package=source.read(512*1024+1)
            if len(package)>512*1024 or hashlib.sha256(package).hexdigest()!=config['digest']:
                raise BridgeRejected('setup_required')
            with zipfile.ZipFile(io.BytesIO(package)) as archive: bootstrap=archive.read('bootstrap.py').decode()
            connector=PeerConnector(package,bootstrap,allow_input=config.get('allowInput',True),allow_management=config.get('allowManagement',False),allow_images=config.get('allowImages',False))
        self.pool=PeerPool(connector); self.priority=set(); self._catalog_epoch=-1
        self._peer_streams={}
        self._transfers={}; self._image_starts=0; self._transfer_lock=threading.RLock()
        threading.Thread(target=self._reap_peer_images,daemon=True).start()

    def hello(self):
        row=super().hello(); row['capabilities'].update(network=True,machines=True); return row

    def computer(self,identifier,row,machine=None,catalog=None,state='live',code=''):
        value={'machine':'gateway' if machine is None else machine.id,
               'label':'Connected computer' if machine is None else machine.label,
               'session':'default' if machine is None else machine.session,
               'targetHash':hashlib.sha256(b'gateway').hexdigest() if machine is None else machine.target_hash,
               'state':state,'code':code,'generation':catalog['serverIdentity'] if catalog else ''}
        if catalog is not None:
            if not self.config.get('allowInput',True):
                catalog={**catalog,'inputEnabled':False,'terminalInputEnabled':False,'terminalViewportEnabled':False}
            if not self.config.get('allowManagement',False) or not self.config.get('allowInput',True):
                catalog={**catalog,'sessionManagementEnabled':False}
            if not self.config.get('allowImages',False) or not self.config.get('allowInput',True):
                catalog={**catalog,'imageTransferEnabled':False}
            value['catalog']=catalog
        if row['payload']['epoch']!=self._catalog_epoch or self.closed.is_set(): return
        if not self.emit({'type':'event','id':identifier,'event':'computer','epoch':self._catalog_epoch,'value':value}):
            raise BridgeRejected('busy')

    def discover(self,row):
        payload=row['payload']; epoch=payload.get('epoch')
        priority=payload.get('priorityMachines',[])
        if (type(epoch) is not int or not 0<=epoch<=2**53-1 or set(payload)-{'epoch','priorityMachines'}
                or not isinstance(priority,list) or len(priority)>16
                or any(not isinstance(p,str) or not MACHINE_ID.fullmatch(p) for p in priority)):
            raise BridgeRejected('invalid_request')
        with self.lock:
            if epoch<=self._catalog_epoch: raise BridgeRejected('invalid_request')
            self._catalog_epoch=epoch; self.priority=set(priority)
        try: catalog=super().operation({'op':'catalog','payload':{}})
        except BridgeRejected as error: self.computer(row['id'],row,state='offline',code=error.code)
        else: self.computer(row['id'],row,catalog=catalog)
        try: machines=self.registry.read()
        except BridgeRejected as error:
            self.emit({'type':'event','id':row['id'],'event':'network_error','epoch':epoch,'value':{'code':error.code}})
            return {'complete':True,'epoch':epoch}
        enabled=[]
        for machine in machines:
            self.computer(row['id'],row,machine=machine,state=('attention' if machine.error else 'connecting') if machine.enabled else 'disabled',code=machine.error)
            if machine.enabled and not machine.error: enabled.append(machine)
        enabled.sort(key=lambda m:m.id not in self.priority)
        def collect(machine):
            if self.closed.is_set() or self._catalog_epoch!=epoch: return
            try:
                with self.pool.lease(machine,'discovery',self.priority) as worker:
                    catalog=worker.request({'op':'catalog','payload':{}})
                # A saved target may have changed while connection/setup was pending.
                self.registry.require({'machine':machine.id,'session':machine.session,'targetHash':machine.target_hash})
                self.computer(row['id'],row,machine=machine,catalog=catalog)
            except BridgeRejected as error:
                attention=error.code in ('auth_required','host_key','setup_required','unsupported','route_changed')
                self.computer(row['id'],row,machine=machine,state='attention' if attention else 'offline',code=error.code)
            except Exception: self.computer(row['id'],row,machine=machine,state='offline',code='offline')
        with ThreadPoolExecutor(max_workers=4) as executor:
            futures=[executor.submit(collect,machine) for machine in enabled]
            for future in as_completed(futures): future.result()
        return {'complete':True,'epoch':epoch}

    def dispatch(self,route,payload,reviewed=False):
        if self.closed.is_set(): raise BridgeRejected('offline')
        if isinstance(route,dict) and route.get('machine')=='gateway':
            if not self.compatible(): raise BridgeRejected('unsupported')
            return self.api.dispatch(route,payload,reviewed=reviewed,cancelled=self.closed.is_set)
        machine=self.registry.require(route)
        with self.pool.lease(machine,'input',self.priority|{machine.id}) as worker:
            self.registry.require(route)
            if self.closed.is_set(): raise BridgeRejected('offline')
            return worker.request({'op':'send' if reviewed else 'input','route':route,'payload':payload})

    def manage(self,op,route,payload):
        if not self.config.get('allowManagement',False) or not self.config.get('allowInput',True):
            raise BridgeRejected('unsupported')
        validate_management_route(op,route); validate_action(op,payload)
        if self.closed.is_set(): raise BridgeRejected('offline')
        if route['machine']=='gateway':
            check_worker_origin(self.config,route)
            if not self.management_enabled(): raise BridgeRejected('unsupported')
            return SessionActions(self.api).mutate(op,route,payload,self.closed.is_set)
        machine=self.registry.require(route)
        with self.pool.lease(machine,'input',self.priority|{machine.id}) as worker:
            self.registry.require(route)
            if self.closed.is_set(): raise BridgeRejected('offline')
            return worker.request({'op':op,'route':route,'payload':payload})

    def _release_image(self,token,cancel=True):
        with self._transfer_lock:item=self._transfers.pop(token,None)
        if item:
            worker,lease,route,private,last=item
            try:
                if cancel:worker.request({'op':'image.cancel','route':route,'payload':{'token':private}},timeout=1)
            except Exception:pass
            finally:lease.__exit__(None,None,None)

    def _reap_peer_images(self):
        while not self.closed.wait(30):
            with self._transfer_lock:expired=[token for token,item in self._transfers.items() if time.monotonic()-item[4]>=300]
            for token in expired:self._release_image(token)

    def image_operation(self,op,route,payload):
        if not self.config.get('allowImages',False) or not self.config.get('allowInput',True):raise BridgeRejected('unsupported')
        validate_image_payload(op,payload);validate_management_route('rename',route)
        with self._transfer_lock:
            if self.closed.is_set():raise BridgeRejected('offline')
            if op=='image.begin' and len(self._transfers)+self._image_starts+(self.images.active_count if self.images else 0)>=4:raise BridgeRejected('busy')
            if route['machine']=='gateway':return super().operation({'op':op,'route':route,'payload':payload})
            if op=='image.begin':self._image_starts+=1
        if op=='image.begin':
            lease=None;private=None
            try:
                machine=self.registry.require(route)
                acquisition=self.pool.lease(machine,'transfer',self.priority|{machine.id});worker=acquisition.__enter__();lease=acquisition
                self.registry.require(route)
                result=worker.request({'op':op,'route':route,'payload':payload})
                private=result.get('token')
                if not isinstance(private,str) or not re.fullmatch('[0-9a-f]{32}',private) or result.get('offset')!=0:raise BridgeRejected('invalid_request')
                self.registry.require(route)
                with self._transfer_lock:
                    if self.closed.is_set():raise BridgeRejected('offline')
                    public=secrets.token_hex(16)
                    self._transfers[public]=(worker,lease,dict(route),private,time.monotonic())
                    lease=None
                return {'token':public,'offset':0}
            except Exception:
                if lease is not None:
                    try:
                        if isinstance(private,str) and re.fullmatch('[0-9a-f]{32}',private):worker.request({'op':'image.cancel','route':route,'payload':{'token':private}},timeout=1)
                    except Exception:pass
                    lease.__exit__(None,None,None)
                raise
            finally:
                with self._transfer_lock:self._image_starts-=1
        token=payload['token']
        with self._transfer_lock:item=self._transfers.get(token)
        if item is None and op=='image.cancel':return {'cancelled':True}
        if item is None or item[2]!=route:raise BridgeRejected('route_changed')
        if op=='image.cancel':self._release_image(token);return {'cancelled':True}
        worker,lease,origin,private,last=item
        try:
            self.registry.require(route)
            result=worker.request({'op':op,'route':origin,'payload':{**payload,'token':private}})
            self.registry.require(route)
            with self._transfer_lock:
                if self.closed.is_set() or token not in self._transfers:raise BridgeRejected('offline')
                if op!='image.finish':self._transfers[token]=(worker,lease,origin,private,time.monotonic())
            if op=='image.finish':self._release_image(token,cancel=False)
            return result
        except Exception:self._release_image(token);raise

    def operation(self,row):
        op=row['op']; route=row.get('route')
        if op.startswith('image.'):return self.image_operation(op,route,row['payload'])
        if op in MANAGEMENT: return self.manage(op,route,row['payload'])
        if op=='catalog': return self.discover(row)
        if op=='machines': return {'machines':[m.__dict__ for m in self.registry.read()]}
        if op in ('input','send'):
            if not self.config.get('allowInput',True): raise BridgeRejected('unsupported')
            return self.dispatch(route,row['payload'],reviewed=op=='send')
        if op=='observe' and isinstance(route,dict) and route.get('machine')!='gateway':
            if row['payload'].get('mode')=='viewport' and not self.config.get('allowInput',True): raise BridgeRejected('unsupported')
            self.reserve_stream(row['id'])
            try:
                machine=self.registry.require(route)
                with self.pool.lease(machine,'streams',self.priority|{machine.id}) as worker:
                    self.registry.require(route)
                    with self.lock:
                        if self.closed.is_set() or row['id'] in self._cancelled: raise BridgeRejected('offline')
                    def relay(event):
                        with self.lock:
                            if row['id'] in self._cancelled: return
                        forwarded=self.emit({'type':'event','id':row['id'],'event':event.get('event','closed'),'value':event.get('value',{})})
                        ended=event.get('event')=='closed' or not forwarded
                        if ended:
                            with self.lock:
                                self._peer_streams.pop(row['id'],None); self._stream_slots.discard(row['id'])
                        if not forwarded:
                            with self.lock: self._cancelled.append(row['id'])
                            self.emit({'type':'event','id':row['id'],'event':'closed','value':{'reason':'Terminal output exceeded its limit.'}})
                            # The peer reader invokes relay; cancellation must not
                            # wait for an acknowledgement on that same reader.
                            def cancel_overflow():
                                try: worker.request({'op':'cancel','payload':{'subscription':event['id']}})
                                except (BridgeRejected,KeyError): pass
                            threading.Thread(target=cancel_overflow,daemon=True).start()
                    result=worker.request({'op':'observe','route':route,'payload':row['payload']},on_event=relay)
                    with self.lock:
                        cancelled=self.closed.is_set() or row['id'] in self._cancelled or row['id'] not in self._stream_slots
                        if not cancelled: self._peer_streams[row['id']]=(worker,result['subscription'])
                    if cancelled:
                        worker.request({'op':'cancel','payload':{'subscription':result['subscription']}})
                        raise BridgeRejected('offline')
                return {'subscription':row['id']}
            except Exception:
                with self.lock: self._stream_slots.discard(row['id'])
                raise
        if op in ('resize','scroll','click') and not self.config.get('allowInput',True): raise BridgeRejected('unsupported')
        if op in ('resize','scroll','click','cancel'):
            identifier=row['payload'].get('subscription')
            with self.lock: peer=self._peer_streams.get(identifier)
            if peer is not None:
                worker,subscription=peer
                result=worker.request({'op':op,'payload':{**row['payload'],'subscription':subscription}})
                if op=='cancel':
                    self.cancel_stream(identifier)
                    with self.lock: self._peer_streams.pop(identifier,None)
                return result
        return super().operation(row)

    def close(self):
        super().close()
        if hasattr(self,'_transfer_lock'):
            with self._transfer_lock:tokens=list(self._transfers)
            for token in tokens:self._release_image(token)
        if hasattr(self,'pool'): self.pool.close()
