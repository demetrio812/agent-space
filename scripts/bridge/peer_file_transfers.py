"""Pin each peer upload to one worker lease and opaque route-owned token."""
import re
import secrets
import threading
import time
try:
    from .protocol import BridgeRejected
except ImportError:
    from protocol import BridgeRejected

class PeerFileTransfers:
    def __init__(self,gateway):self.gateway=gateway;self.items={};self.lock=threading.RLock()
    def _release(self,token,cancel=True):
        item=self.items.pop(token,None)
        if item:
            worker,lease,route,private,last=item
            try:
                if cancel:worker.request({'op':'fs.cancel','route':route,'payload':{'token':private}},timeout=1)
            except Exception:pass
            finally:lease.__exit__(None,None,None)
    def reap(self):
        with self.lock:
            for token,item in list(self.items.items()):
                if time.monotonic()-item[4]>=300:self._release(token)
    def operation(self,op,route,payload):
        g=self.gateway
        with self.lock:
            self.reap()
            if g.closed.is_set():raise BridgeRejected('offline')
            if op=='fs.begin':
                if len(self.items)>=4:raise BridgeRejected('busy')
                lease=None;private=None
                try:
                    machine=g.registry.require(route)
                    lease=g.pool.lease(machine,'transfer',g.priority|{machine.id});worker=lease.__enter__()
                    g.registry.require(route)
                    result=worker.request({'op':op,'route':route,'payload':payload},timeout=30);private=result.get('token')
                    if not isinstance(private,str) or not re.fullmatch('[0-9a-f]{32}',private) or result.get('offset')!=0:raise BridgeRejected('invalid_request')
                    g.registry.require(route)
                    if g.closed.is_set():raise BridgeRejected('offline')
                    token=secrets.token_hex(16);self.items[token]=(worker,lease,dict(route),private,time.monotonic());lease=None
                    return {'token':token,'offset':0}
                except Exception:
                    if lease is not None:
                        try:
                            if isinstance(private,str) and re.fullmatch('[0-9a-f]{32}',private):worker.request({'op':'fs.cancel','route':route,'payload':{'token':private}},timeout=1)
                        except Exception:pass
                        lease.__exit__(None,None,None)
                    raise
            token=payload['token'];item=self.items.get(token)
            if item is None and op=='fs.cancel':return {'cancelled':True}
            if item is None or item[2]!=route:raise BridgeRejected('route_changed')
            if op=='fs.cancel':self._release(token);return {'cancelled':True}
            worker,lease,origin,private,last=item
            try:
                g.registry.require(route)
                result=worker.request({'op':op,'route':origin,'payload':{**payload,'token':private}},timeout=30)
                g.registry.require(route)
                if g.closed.is_set():raise BridgeRejected('offline')
                if op=='fs.finish':self._release(token,cancel=False)
                else:self.items[token]=(worker,lease,origin,private,time.monotonic())
                return result
            except Exception:self._release(token);raise
    def close(self):
        with self.lock:
            for token in list(self.items):self._release(token)
