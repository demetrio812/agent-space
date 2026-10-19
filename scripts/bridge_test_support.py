"""Disposable real UNIX API and CLI children for bridge boundary tests."""
import base64
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import threading
import time


class FakeHerdr:
    def __init__(self, root):
        self.root = Path(root)
        self.socket_path = str(self.root / 'herdr.sock')
        self.calls = []
        self._lose_ack = False
        self.input_reply = None
        self.lose_management_ack = False
        self.management_result = None
        self.mutation_calls = []
        self.pane_labels = {}
        self.extra_panes = []
        self.workspaces = [{"workspace_id":"w1","label":"Workbench"}]
        self.agents = [{'terminal_id': 't1', 'pane_id': 'p1', 'workspace_id': 'w1',
                        'tab_id': 'tab1', 'terminal_title': 'Disposable'}]
        self._listeners = []
        self._threads = []
        self.cli = self.root / 'herdr'
        self.cli.write_text('''#!/usr/bin/env python3
import base64,json,os,signal,sys,time
from pathlib import Path
root=Path(os.environ['HERDR_SOCKET_PATH']).parent
with (root/'cli-calls').open('a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')
if sys.argv[1:]==['terminal','session','--help']:
 print('observe' if (root/'older-herdr').exists() else 'control\\nobserve'); sys.exit()
if '--help' in sys.argv and sys.argv[1] in ('pane','tab','workspace'):
 print('Usage: label pane_id workspace cwd focus'); sys.exit()
if sys.argv[1:3]==['machine','list']:
 print((root/'machines.json').read_text() if (root/'machines.json').exists() else '[]'); sys.exit()
if (root/'ignore-term').exists(): signal.signal(signal.SIGTERM, signal.SIG_IGN)
seq=0; scroll_offset=0
cols=int(sys.argv[sys.argv.index('--cols')+1]) if '--cols' in sys.argv else 90
rows=int(sys.argv[sys.argv.index('--rows')+1]) if '--rows' in sys.argv else 30
def frame():
 print(json.dumps({'type':'terminal.frame','encoding':'ansi','width':cols,'height':rows,'seq':seq,'full':True,'bytes':base64.b64encode(('fixture history offset='+str(scroll_offset)).encode()).decode()}),flush=True)
frame()
if sys.argv[3]=='control':
 for line in sys.stdin:
  value=json.loads(line)
  if value['type']=='terminal.scroll':
   amount=1 if (root/'mouse-report').exists() else value['lines']
   scroll_offset=max(0,min(100,scroll_offset+(amount if value['direction']=='up' else -amount)))
  elif value['type']=='terminal.mouse':
   with (root/'mouse-controls').open('a') as f: f.write(json.dumps(value)+'\\n')
   if value['action']=='up': scroll_offset=0
  else: cols,rows=value['cols'],value['rows']
  seq+=1; frame()
else:
 while True: time.sleep(.1)
''')
        self.cli.chmod(0o700)

    def _listen(self):
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(self.socket_path); listener.listen(); listener.settimeout(.1)
        self._listeners.append(listener)
        def accept():
            while listener in self._listeners:
                try: client, _ = listener.accept()
                except socket.timeout: continue
                except OSError: return
                thread = threading.Thread(target=self._serve, args=(client,), daemon=True)
                thread.start(); self._threads.append(thread)
        thread = threading.Thread(target=accept, daemon=True); thread.start()
        self._threads.append(thread)

    def _serve(self, client):
        with client:
            client.settimeout(3)
            with client.makefile('rb') as reader:
                line = reader.readline(2 * 1024 * 1024)
            if not line: return
            row = json.loads(line); self.calls.append(row)
            method = row['method']
            result = {'agent.list': {'agents': self.agents},
                      'workspace.list': {'workspaces': self.workspaces},
                      'tab.list': {'tabs': []},
                      'pane.list': {'panes': [{**a, 'label': self.pane_labels.get(a['pane_id'])} for a in self.agents] + self.extra_panes},
                      'pane.layout': {'layout': {'panes':[{'pane_id':'p1','rect':{'width':90,'height':30}}]}}}.get(method, {'type':'ok'})
            if method in ('pane.rename','pane.close','tab.create','workspace.create'):
                self.mutation_calls.append(row)
                params=row['params']
                if method=='pane.rename':
                    for agent in self.agents:
                        if agent['pane_id']==params['pane_id']:
                            self.pane_labels[agent['pane_id']]=params['label']
                            result={'type':'pane_info','pane':{**agent,'label':params['label']}}
                elif method=='pane.close':
                    self.agents=[a for a in self.agents if a['pane_id']!=params['pane_id']]
                else:
                    workspace={'workspace_id':'new-workspace','label':params.get('label') or 'Workspace'} if method=='workspace.create' else None
                    if workspace: self.workspaces.append(workspace)
                    wid=workspace['workspace_id'] if workspace else params['workspace_id']
                    agent={'terminal_id':'new-terminal','pane_id':'new-pane','workspace_id':wid,
                           'tab_id':'new-tab','title':params.get('label') or 'Shell','agent':None}
                    self.agents.append(agent)
                    result={'type':'workspace_created' if workspace else 'tab_created','tab':{'tab_id':'new-tab','workspace_id':wid},
                            'root_pane':agent}
                    if workspace: result['workspace']=workspace
                if self.lose_management_ack:
                    self.lose_management_ack=False; return
                if self.management_result is not None: result=self.management_result
            if method.startswith('pane.send') and self._lose_ack:
                self._lose_ack = False; return
            if method.startswith('pane.send') and self.input_reply is not None:
                client.sendall(self.input_reply); return
            client.sendall((json.dumps({'id':row['id'],'result':result})+'\n').encode())

    def __enter__(self): self._listen(); return self
    def __exit__(self, *_):
        listeners, self._listeners = self._listeners, []
        for listener in listeners: listener.close()
        for thread in self._threads: thread.join(timeout=.3)
    def replace_socket(self):
        Path(self.socket_path).rename(self.root / 'old.sock'); self._listen()
    def lose_next_input_ack(self): self._lose_ack = True


def worker_config(herdr, lane, nonce='b' * 32):
    return {'role':'local','lane':lane,'herdr':str(herdr.cli),'socket':herdr.socket_path,
            'generationStyle':'peer','nonce':nonce,'digest':'a'*64,'allowInput':True}


class WorkerHarness:
    def __init__(self, root, lane):
        self.root, self.lane = Path(root), lane
    def __enter__(self):
        from bridge.package import build_package
        self.herdr = FakeHerdr(self.root).__enter__()
        package = self.root / 'bridge.pyz'
        package.write_bytes(build_package(Path(__file__).with_name('catalog-gate.py')))
        config = worker_config(self.herdr, self.lane)
        self.process = subprocess.Popen([sys.executable,'-B',str(package),base64.b64encode(json.dumps(config).encode()).decode()],
                                        stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        self.records = []
        self.hello = json.loads(self.process.stdout.readline())
        self.owned_pids = []
        self.counter = 0
        return self
    def request(self, op, payload, route=None):
        self.counter += 1
        if route is None:
            route={'generation':self.hello['generation'],'terminal':'t1','pane':'p1'}
        row={'type':'request','protocol':'agentspace-bridge-v2','nonce':'b'*32,
             'lane':self.lane,'id':str(self.counter),'op':op,'payload':payload,'route':route}
        self.process.stdin.write((json.dumps(row)+'\n').encode()); self.process.stdin.flush()
        while True:
            line=self.process.stdout.readline()
            if not line: raise RuntimeError(self.process.stderr.read().decode())
            response=json.loads(line); self.records.append(response)
            if response['type']=='reply' and response['id']==str(self.counter):
                if op=='observe' and response.get('ok'):
                    self.owned_pids.append(response['result']['pid'])
                return response
    def close_stdin(self): self.process.stdin.close()
    def wait_frame(self, subscription):
        for row in self.records:
            if row.get('id')==subscription and row.get('event')=='frame': return row
        while True:
            row=json.loads(self.process.stdout.readline()); self.records.append(row)
            if row.get('id')==subscription and row.get('event')=='frame': return row
    def wait_closed(self, timeout): self.process.wait(timeout=timeout)
    def __exit__(self, *_):
        if not self.process.stdin.closed: self.close_stdin()
        try: self.wait_closed(4)
        except subprocess.TimeoutExpired: self.process.kill(); self.process.wait()
        self.process.stdout.close(); self.process.stderr.close()
        self.herdr.__exit__()
