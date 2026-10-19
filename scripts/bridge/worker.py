"""Persistent typed local worker; each process owns only one lane."""
import base64
from collections import deque
import json
import os
from pathlib import Path
import queue
import signal
import shutil
import subprocess
import threading
import time

try:
    from .protocol import PROTOCOL, BridgeRejected, DeliveryUncertain, validate_request, read_record, write_record
    from .image_transfers import ImageTransfers
    from .git_metadata import GitMetadata
    from .local_api import LocalApi
    from .session_actions import SessionActions, MANAGEMENT, validate_management_route, check_worker_origin
    from .gate_rules import valid_viewport, gate
except ImportError:
    from protocol import PROTOCOL, BridgeRejected, DeliveryUncertain, validate_request, read_record, write_record
    from image_transfers import ImageTransfers
    from git_metadata import GitMetadata
    from local_api import LocalApi
    from session_actions import SessionActions, MANAGEMENT, validate_management_route, check_worker_origin
    from gate_rules import valid_viewport, gate


def stop_process(process):
    if process.poll() is None:
        try: os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError: pass
        except PermissionError:
            try: process.terminate()
            except ProcessLookupError: pass
        try: process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            except PermissionError:
                try: process.kill()
                except ProcessLookupError: pass
            process.wait(timeout=1)
    for pipe in (process.stdin, process.stdout, process.stderr):
        if pipe:
            try: pipe.close()
            except OSError: pass


class LocalWorker:
    def __init__(self, config, output):
        self.config = config; self.output = output
        self.lane, self.nonce = config['lane'], config['nonce']
        self.api = LocalApi(config['socket'], config['generationStyle'])
        self.closed = threading.Event(); self.lock = threading.RLock()
        self._ids = deque(maxlen=128); self._last_id = 0
        self.streams = {}; self._jobs = set(); self._cancelled = deque(maxlen=128); self._stream_slots = set()
        self._output = queue.Queue(maxsize=8); self._queued_streams = {}; self._closed_events = {}
        self._management_compatible = None; self._compatible = None; self._compatibility_lock = threading.Lock()
        self._writer = threading.Thread(target=self._write_loop, daemon=True)
        self.images = None
        self.git_metadata = GitMetadata(self.closed)
        self._writer.start()
        threading.Thread(target=self._reap_images,daemon=True).start()

    def _reap_images(self):
        while not self.closed.wait(30):
            try:
                if self.images: self.images.reap()
            except OSError: pass

    def image_enabled(self):
        return self.config.get('allowImages',False) and self.config.get('allowInput',True) and self.compatible()

    def _write_loop(self):
        try:
            while not self.closed.is_set():
                with self.lock:
                    row=self._closed_events.pop(next(iter(self._closed_events)),None) if self._closed_events else None
                if row is None:
                    try: row = self._output.get(timeout=.1)
                    except queue.Empty: continue
                write_record(self.output, row)
                if row['type'] == 'event' and row.get('event')=='frame':
                    with self.lock:
                        count=self._queued_streams.get(row['id'],1)-1
                        if count>0: self._queued_streams[row['id']]=count
                        else: self._queued_streams.pop(row['id'],None)
        except (OSError, ValueError): self.close()

    def emit(self, row):
        if self.closed.is_set(): return False
        row = {'nonce':self.nonce,'lane':self.lane,**row}
        if row['type']=='event' and self.lane=='streams':
            # Allow a short renderer burst to drain; sustained backpressure
            # still retires only this subscription and remains memory bounded.
            deadline=time.monotonic()+.25
            while not self.closed.is_set():
                with self.lock:
                    if row.get('event')=='closed':
                        if row['id'] not in self._closed_events and len(self._closed_events)>=16:
                            self.close(); return False
                        self._closed_events[row['id']]=row; return True
                    count=self._queued_streams.get(row['id'],0)
                    if count<4:
                        try:self._output.put_nowait(row)
                        except queue.Full:pass
                        else:self._queued_streams[row['id']]=count+1;return True
                if time.monotonic()>=deadline:return False
                self.closed.wait(.002)
            return False
        deadline=time.monotonic()+4
        while not self.closed.is_set():
            try:
                self._output.put(row,timeout=min(.1,max(.001,deadline-time.monotonic())))
                return True
            except queue.Full:
                if time.monotonic()>=deadline: return False
        return False

    def compatible(self):
        with self._compatibility_lock:
            if self._compatible is None:
                try:
                    text=gate.bounded_catalog(self.config['herdr'],dict(os.environ,HERDR_SOCKET_PATH=self.config['socket']),
                                              ('terminal','session','--help'))
                    text=bytes(text).decode('utf-8')
                    commands={line.strip().split()[0] for line in text.splitlines() if line.strip()}
                    self._compatible={'control','observe'}<=commands
                except (OSError,ValueError,RuntimeError): self._compatible=False
            return self._compatible

    def management_enabled(self):
        if not self.config.get('allowManagement',False) or not self.config.get('allowInput',True): return False
        if self._management_compatible is None:
            try:
                env=dict(os.environ,HERDR_SOCKET_PATH=self.config['socket'])
                for args in [('pane','rename','--help'),('pane','close','--help'),('tab','create','--help'),('workspace','create','--help')]:
                    data=gate.bounded_catalog(self.config['herdr'],env,args)
                    if not data: raise ValueError('Missing capabilities')
                self._management_compatible=True
            except (OSError,ValueError,RuntimeError): self._management_compatible=False
        return self._management_compatible

    def hello(self):
        try: generation = self.api.generation()
        except BridgeRejected: generation = None
        compatible=self.compatible()
        return {'type':'hello','protocol':PROTOCOL,'digest':self.config['digest'],
                'nonce':self.nonce,'lane':self.lane,'generation':generation,
                'capabilities':{'management':self.management_enabled(),'catalog':True,'machines':False,'network':False,'observe':compatible,
                                'images':self.image_enabled(),'input':compatible and self.config.get('allowInput',True),'viewport':compatible and self.config.get('allowInput',True)}}

    def handle(self, row):
        identifier = row.get('id','0') if isinstance(row,dict) else '0'
        try:
            validate_request(row, self.nonce, self.lane)
            with self.lock:
                if self.closed.is_set(): return
                number = int(identifier)
                if number <= self._last_id or identifier in self._ids:
                    raise BridgeRejected('invalid_request')
                self._last_id = number; self._ids.append(identifier)
                if len(self._jobs) >= 32: raise BridgeRejected('busy')
                job = threading.Thread(target=self._run, args=(row,), daemon=True)
                self._jobs.add(job); job.start()
        except BridgeRejected as error: self.reply_error(identifier,error)

    def reply_error(self, identifier, error):
        self.emit({'type':'reply','id':identifier,'ok':False,
                   'error':{'code':error.code,'dispatched':error.dispatched}})

    def _run(self, row):
        try:
            result = self.operation(row)
            if not self.emit({'type':'reply','id':row['id'],'ok':True,'result':result}): self.close()
        except BridgeRejected as error: self.reply_error(row['id'],error)
        except (ValueError, TypeError, KeyError, UnicodeError): self.reply_error(row['id'],BridgeRejected('invalid_request'))
        except Exception: self.reply_error(row['id'],BridgeRejected('offline'))
        finally:
            with self.lock: self._jobs.discard(threading.current_thread())

    def operation(self, row):
        op, payload = row['op'], row['payload']
        if op == 'health': return {'alive':True}
        if op in ('catalog','input','send','observe','resize') and not self.compatible(): raise BridgeRejected('unsupported')
        if op == 'catalog':
            result = self.git_metadata.enrich(self.api.catalog())
            result.update(inputEnabled=self.config.get('allowInput',True),
                          terminalInputEnabled=self.config.get('allowInput',True),
                          terminalViewportEnabled=self.config.get('allowInput',True),
                          sessionManagementEnabled=self.management_enabled(),imageTransferEnabled=self.image_enabled())
            return result
        if op in MANAGEMENT:
            if not self.management_enabled(): raise BridgeRejected('unsupported')
            route=validate_management_route(op,row.get('route')); check_worker_origin(self.config,route)
            return SessionActions(self.api).mutate(op,route,payload,self.closed.is_set)
        if op.startswith('image.'):
            if not self.image_enabled(): raise BridgeRejected('unsupported')
            route=validate_management_route('rename',row.get('route')); check_worker_origin(self.config,route)
            with self.lock:
                if self.closed.is_set(): raise BridgeRejected('offline')
                if self.images is None: self.images=ImageTransfers(self.api,Path.home()/'.cache/agentspace/attachments')
                return self.images.operation(op,route,payload)
        if op == 'machines': raise BridgeRejected('unsupported')
        if op in ('input','send'):
            if not self.config.get('allowInput',True): raise BridgeRejected('unsupported')
            return self.api.dispatch(row.get('route'),payload,reviewed=op=='send',cancelled=self.closed.is_set)
        if op == 'observe': return self.start_stream(row)
        if op == 'scroll':
            if not self.config.get('allowInput',True): raise BridgeRejected('unsupported')
            if (set(payload) != {'subscription','direction','steps'}
                    or not isinstance(payload['subscription'],str)
                    or payload['direction'] not in ('up','down')
                    or type(payload['steps']) is not int or not 1<=payload['steps']<=40):
                raise BridgeRejected('invalid_request')
            with self.lock:
                entry=self.streams.get(payload['subscription'])
                if entry is None or entry['mode']!='viewport': raise BridgeRejected('unsupported')
                if self.closed.is_set() or entry['process'].poll() is not None: raise BridgeRejected('offline')
                # Mouse-reporting applications consume one wheel event per record,
                # ignoring lines. Preserve each notch while batching SSH traffic.
                for _ in range(payload['steps']):
                    write_record(entry['process'].stdin, {'type':'terminal.scroll','direction':payload['direction'],
                                                         'lines':3,'source':'wheel'})
            return {'scrolled':True}
        if op == 'click':
            if not self.config.get('allowInput',True): raise BridgeRejected('unsupported')
            if (set(payload) != {'subscription','column','row'} or not isinstance(payload['subscription'],str)
                    or type(payload['column']) is not int or type(payload['row']) is not int):
                raise BridgeRejected('invalid_request')
            with self.lock:
                entry=self.streams.get(payload['subscription'])
                if entry is None or entry['mode']!='viewport': raise BridgeRejected('unsupported')
                if not (0<=payload['column']<entry['cols'] and 0<=payload['row']<entry['rows']):
                    raise BridgeRejected('invalid_request')
                if self.closed.is_set() or entry['process'].poll() is not None: raise BridgeRejected('offline')
                try:
                    for action in ('down','up'):
                        write_record(entry['process'].stdin, {'type':'terminal.mouse','action':action,'button':'left',
                                                             'column':payload['column'],'row':payload['row']})
                except (OSError,ValueError): raise DeliveryUncertain()
            return {'sent':True}
        if op == 'resize':
            if set(payload) != {'subscription','cols','rows'} or not valid_viewport(payload['cols'],payload['rows']):
                raise BridgeRejected('invalid_request')
            with self.lock:
                entry = self.streams.get(payload['subscription'])
                if entry is None or entry['mode'] != 'viewport': raise BridgeRejected('unsupported')
                if self.closed.is_set() or entry['process'].poll() is not None: raise BridgeRejected('offline')
                write_record(entry['process'].stdin, {'type':'terminal.resize','cols':payload['cols'],'rows':payload['rows']})
                entry.update(cols=payload['cols'],rows=payload['rows'])
            return {'resized':True}
        if op == 'cancel':
            if set(payload) != {'subscription'} or not isinstance(payload['subscription'],str): raise BridgeRejected('invalid_request')
            self.cancel_stream(payload['subscription']); return {'cancelled':True}
        raise BridgeRejected('unsupported')

    def reserve_stream(self, identifier):
        with self.lock:
            if self.closed.is_set() or identifier in self._cancelled: raise BridgeRejected('offline')
            if len(self._stream_slots)>=16: raise BridgeRejected('busy')
            self._stream_slots.add(identifier)

    def start_stream(self, row):
        self.reserve_stream(row['id'])
        try: return self._start_stream(row)
        except Exception:
            with self.lock: self._stream_slots.discard(row['id'])
            raise

    def _start_stream(self, row):
        payload, route = row['payload'], row.get('route')
        if (set(payload)-{'mode','cols','rows'} or payload.get('mode') not in ('preview','viewport')
                or not valid_viewport(payload.get('cols',120),payload.get('rows',40))):
            raise BridgeRejected('invalid_request')
        mode = payload['mode']
        if mode == 'viewport' and not self.config.get('allowInput',True): raise BridgeRejected('unsupported')
        self.api.member(route)
        cols, rows = payload.get('cols',120), payload.get('rows',40)
        if mode == 'preview':
            try:
                layout = self.api.call('pane.layout', {'pane_id':route['pane']}, time.monotonic()+4)
                panes = layout.get('result',{}).get('layout',{}).get('panes',[])
                rects = [p.get('rect',{}) for p in panes if isinstance(p,dict) and p.get('pane_id')==route['pane']]
                if len(rects)==1 and valid_viewport(rects[0].get('width'),rects[0].get('height')):
                    cols,rows=rects[0]['width'],rects[0]['height']
            except (BridgeRejected, TypeError, AttributeError): pass
        args = [self.config['herdr'],'terminal','session','control' if mode=='viewport' else 'observe',
                route['terminal'],'--cols',str(cols),'--rows',str(rows)]
        env = dict(os.environ, HERDR_SOCKET_PATH=self.config['socket'])
        with self.lock:
            if self.closed.is_set() or row['id'] in self._cancelled: raise BridgeRejected('offline')
            if len(self.streams)>=16: raise BridgeRejected('busy')
            if self.api.generation()!=route['generation']: raise BridgeRejected('generation_changed')
            child = subprocess.Popen(args,env=env,stdin=subprocess.PIPE if mode=='viewport' else subprocess.DEVNULL,
                                     stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
            self.streams[row['id']] = {'process':child,'mode':mode,'cols':cols,'rows':rows}
        threading.Thread(target=self._read_stream,args=(row['id'],child),daemon=True).start()
        threading.Thread(target=self._drain_error,args=(row['id'],child),daemon=True).start()
        return {'subscription':row['id'],'pid':child.pid}

    def _read_stream(self, identifier, child):
        try:
            while not self.closed.is_set():
                frame = read_record(child.stdout)
                if frame is None: break
                if frame.get('type') not in ('terminal.frame','terminal.closed'): raise ValueError('Invalid terminal record')
                if not self.emit({'type':'event','id':identifier,'event':'frame','value':frame}): break
        except (OSError,ValueError): pass
        finally:
            self.cancel_stream(identifier)
            self.emit({'type':'event','id':identifier,'event':'closed','value':{'reason':'Terminal stream ended.'}})

    def _drain_error(self, identifier, child):
        count=0
        try:
            while not self.closed.is_set():
                chunk=os.read(child.stderr.fileno(),8192)
                if not chunk: return
                count+=len(chunk)
                if count>65536: self.cancel_stream(identifier); return
        except (OSError,ValueError): pass

    def cancel_stream(self, identifier):
        with self.lock:
            self._cancelled.append(identifier); self._stream_slots.discard(identifier)
            entry = self.streams.pop(identifier,None)
        if entry: stop_process(entry['process'])

    def close(self):
        with self.lock:
            self.closed.set();
            if self.images: self.images.close()
            entries=list(self.streams.values()); self.streams.clear()
        # Stop in parallel so closing sixteen views remains bounded.
        closers=[threading.Thread(target=stop_process,args=(e['process'],),daemon=True) for e in entries]
        for thread in closers: thread.start()
        for thread in closers: thread.join(timeout=2.2)


def discover_config(config):
    config = dict(config)
    if not config.get('herdr'):
        candidates=[Path.home()/'.local/bin/herdr',Path.home()/'.cargo/bin/herdr',shutil.which('herdr'),Path('/opt/homebrew/bin/herdr'),Path('/usr/local/bin/herdr')]
        for candidate in candidates:
            if not candidate: continue
            path=Path(candidate)
            if path.is_file() and os.access(path,os.X_OK): config['herdr']=str(path); break
    if not config.get('herdr'): raise BridgeRejected('setup_required')
    if not Path(config['herdr']).is_file() or not os.access(config['herdr'],os.X_OK):
        raise BridgeRejected('setup_required')
    if not config.get('socket'):
        session=config.get('herdrSession','default')
        import re
        if not isinstance(session,str) or not re.fullmatch('[A-Za-z0-9_.-]{1,64}',session) or session in ('.','..'):
            raise BridgeRejected('invalid_request')
        folder=Path.home()/'.config/herdr'
        if session!='default': folder=folder/'sessions'/session
        config['socket']=str(folder/'herdr.sock')
    return config
