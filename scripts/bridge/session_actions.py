"""Three fixed Herdr mutations, validated before a single submission."""
import hashlib
import os
from pathlib import Path
import re
import time
try:
    from .protocol import BridgeRejected, DeliveryUncertain, IDENTITY, GENERATION, validate_route
    from .local_api import failed
except ImportError:
    from protocol import BridgeRejected, DeliveryUncertain, IDENTITY, GENERATION, validate_route
    from local_api import failed

MANAGEMENT = frozenset(('rename','close','create'))
COMPUTER_FIELDS = {'machine','session','targetHash','generation'}

def validate_computer_route(route):
    if not isinstance(route,dict) or set(route)!=COMPUTER_FIELDS:
        raise BridgeRejected('invalid_request')
    if (not isinstance(route['machine'],str) or not (route['machine']=='gateway' or re.fullmatch('[0-9a-f]{32}',route['machine']))
            or not isinstance(route['session'],str) or not re.fullmatch('[A-Za-z0-9_.-]{1,64}',route['session'])
            or route['session'] in ('.','..')
            or any(not isinstance(route[n],str) or not GENERATION.fullmatch(route[n]) for n in ('targetHash','generation'))):
        raise BridgeRejected('invalid_request')
    return route


def validate_management_route(op,route):
    if op=='create': return validate_computer_route(route)
    if not isinstance(route,dict) or set(route)!=COMPUTER_FIELDS|{'terminal','pane'}:
        raise BridgeRejected('invalid_request')
    validate_computer_route({k:route[k] for k in COMPUTER_FIELDS})
    return validate_route(route)


def text(value,limit):
    if (not isinstance(value,str) or len(value.encode('utf-8'))>limit
            or any(ord(c)<32 or 127<=ord(c)<160 for c in value)):
        raise BridgeRejected('invalid_request')
    return value


def validate_action(op,payload):
    if not isinstance(payload,dict): raise BridgeRejected('invalid_request')
    fields={'rename':{'title'},'close':set(),'create':{'workspace','title','cwd'}}
    if op not in fields or set(payload)!=fields[op]: raise BridgeRejected('invalid_request')
    if op!='close': text(payload['title'],128)
    if op=='create':
        if not isinstance(payload['workspace'],str) or not IDENTITY.fullmatch(payload['workspace']): raise BridgeRejected('invalid_request')
        cwd=text(payload['cwd'],4096)
        if cwd and not (cwd.startswith('/') or cwd.startswith('~/')): raise BridgeRejected('invalid_request')
    return payload


def check_worker_origin(config,route):
    if (route['machine']!=config.get('machine','gateway') or route['session']!=config.get('herdrSession','default')
            or route['targetHash']!=config.get('targetHash',hashlib.sha256(b'gateway').hexdigest())):
        raise BridgeRejected('route_changed')


class SessionActions:
    def __init__(self,api): self.api=api
    def mutate(self,op,route,payload,cancelled=lambda:False):
        validate_management_route(op,route); validate_action(op,payload)
        submitted=False
        def check():
            if cancelled(): raise BridgeRejected('invalid_request')
            if self.api.generation()!=route['generation']: raise BridgeRejected('generation_changed')
        def before_send():
            nonlocal submitted
            check(); submitted=True
        with self.api._dispatch_lock:
            check()
            if op=='create':
                workspaces=self.api.call('workspace.list',{},time.monotonic()+4).get('result',{}).get('workspaces')
                if not isinstance(workspaces,list) or len(workspaces)>4096: raise BridgeRejected('invalid_request')
                if sum(isinstance(w,dict) and w.get('workspace_id')==payload['workspace'] for w in workspaces)!=1:
                    raise BridgeRejected('workspace_missing')
                cwd=payload['cwd']
                if cwd.startswith('~/'): cwd=str(Path.home()/cwd[2:])
                params={'workspace_id':payload['workspace'],'label':payload['title'] or None,'cwd':cwd or None,'focus':False,'env':{}}
            else:
                self.api.member(route)
                params={'pane_id':route['pane']}
                if op=='rename': params['label']=payload['title'] or None
            try:
                response=self.api.call({'rename':'pane.rename','close':'pane.close','create':'tab.create'}[op],
                                       params,time.monotonic()+4,before_send).get('result')
                if failed(response): raise ValueError('Missing action acknowledgement')
                if op=='close':
                    if response.get('type')!='ok': raise ValueError('Missing close acknowledgement')
                elif op=='rename':
                    pane=response.get('pane',{})
                    if (response.get('type')!='pane_info' or not isinstance(pane,dict) or pane.get('pane_id')!=route['pane']
                            or pane.get('terminal_id')!=route['terminal']): raise ValueError('Invalid rename acknowledgement')
                else:
                    pane=response.get('root_pane',{}); tab=response.get('tab',{})
                    if response.get('type')!='tab_created' or not isinstance(pane,dict) or not isinstance(tab,dict): raise ValueError('Invalid create acknowledgement')
                    ids={'terminal':pane.get('terminal_id'),'pane':pane.get('pane_id'),
                         'workspace':pane.get('workspace_id'),'tab':tab.get('tab_id')}
                    if any(not isinstance(v,str) or not IDENTITY.fullmatch(v) for v in ids.values()): raise ValueError('Missing created identity')
                    if ids['workspace']!=payload['workspace'] or tab.get('workspace_id')!=ids['workspace'] or pane.get('tab_id')!=ids['tab']:
                        raise ValueError('Different created destination')
                    member=self.api.member({**route,'terminal':ids['terminal'],'pane':ids['pane']})
                    if member.get('workspace_id')!=ids['workspace'] or member.get('tab_id')!=ids['tab']:
                        raise ValueError('Created terminal unavailable')
                    check()
                    return {'applied':True,'created':ids}
                check()
                return {'applied':True}
            except Exception:
                if submitted: raise DeliveryUncertain()
                raise
