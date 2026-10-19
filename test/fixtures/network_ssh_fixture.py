"""Real disposable gateway/OpenSSH peers; generated trust files stay in this HOME."""
import base64
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time

import paramiko
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'scripts'))
from bridge_test_support import FakeHerdr

root=Path(sys.argv[1]).resolve(); root.mkdir(parents=True,exist_ok=True)
lock=threading.RLock(); stopping=threading.Event(); processes=set(); transports=set()
events=[]; nodes={}; listeners=[]
client_key=paramiko.RSAKey.generate(2048)
sshdir=root/'gateway/.ssh'; sshdir.mkdir(parents=True,mode=0o700)
client_key.write_private_key_file(str(sshdir/'id_rsa')); (sshdir/'id_rsa').chmod(0o600)

def record(node,value):
    with lock: events.append({'node':node,**value})

class Node:
    def __init__(self,name,session='default'):
        self.name=name; self.home=root/name; self.home.mkdir(mode=0o700,exist_ok=True)
        folder=self.home/'.config/herdr'
        if session!='default': folder=folder/'sessions'/session
        folder.mkdir(parents=True)
        self.herdr=FakeHerdr(folder).__enter__()
        serve=self.herdr._serve
        def controlled_serve(connection):
            if (self.herdr.root/'stall-discovery').exists(): time.sleep(10)
            serve(connection)
        self.herdr._serve=controlled_serve
        cli=self.home/'.local/bin/herdr'; cli.parent.mkdir(parents=True)
        source=self.herdr.cli.read_text().replace(" print((root/'machines.json')", " if (root/'stall-discovery').exists(): time.sleep(10)\n print((root/'machines.json')")
        source=source.replace(" while True: time.sleep(.1)"," while True:\n  if (root/'flood').exists(): seq+=1; frame()\n  else: time.sleep(.1)")
        legacy_cli=r"""args=sys.argv[1:]
methods={('agent','list'):'agent.list',('workspace','list'):'workspace.list',('tab','list'):'tab.list',('pane','layout'):'pane.layout',('pane','send-text'):'pane.send_text',('pane','send-keys'):'pane.send_keys',('pane','run'):'pane.send_input'}
method=methods.get(tuple(args[:2]))
if method:
 import socket
 params={}
 if args[0]=='pane': params={'pane_id':args[2]}
 if method=='pane.send_text': params['text']=args[3]
 if method=='pane.send_keys': params['keys']=args[3:]
 if method=='pane.send_input': params.update(text=args[3],keys=['Enter'])
 with socket.socket(socket.AF_UNIX) as client:
  client.connect(os.environ['HERDR_SOCKET_PATH']); client.sendall((json.dumps({'id':'fixture-cli','method':method,'params':params})+'\n').encode())
  print(client.makefile('r').readline(),end='')
 sys.exit()
"""
        source=source.replace("if (root/'ignore-term').exists():",legacy_cli+"with (root/'observer-pids').open('a') as f: f.write(str(os.getpid())+'\\n')\n"+"if (root/'ignore-term').exists():")
        cli.write_text(source); cli.chmod(0o700)
        self.herdr.cli=cli
        self.key=paramiko.RSAKey.generate(2048)
        self.listener=socket.socket(); self.listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
        self.listener.bind(('127.0.0.1',0)); self.listener.listen(); self.listener.settimeout(.2)
        self.port=self.listener.getsockname()[1]; listeners.append(self.listener)
        self.fingerprint='SHA256:'+base64.b64encode(hashlib.sha256(self.key.asbytes()).digest()).decode().rstrip('=')
        threading.Thread(target=self.accept,daemon=True).start()
    def accept(self):
        while not stopping.is_set():
            try: client,_=self.listener.accept()
            except socket.timeout: continue
            except OSError: return
            threading.Thread(target=self.connection,args=(client,),daemon=True).start()
    def connection(self,client):
        transport=paramiko.Transport(client); transport.add_server_key(self.key); channels=[]
        with lock: transports.add(transport)
        try:
            transport.start_server(server=Server(self))
            while transport.is_active() and not stopping.is_set():
                channel=transport.accept(.2)
                if channel is not None: channels.append(channel)
        except (EOFError,paramiko.SSHException,OSError): pass
        finally:
            transport.close()
            with lock: transports.discard(transport)

class Server(paramiko.ServerInterface):
    def __init__(self,node): self.node=node
    def check_auth_password(self,user,password):
        return paramiko.AUTH_SUCCESSFUL if self.node.name=='gateway' and user=='fixture' and password=='disposable' else paramiko.AUTH_FAILED
    def check_auth_publickey(self,user,key):
        return paramiko.AUTH_SUCCESSFUL if user=='fixture' and key==client_key and not (self.node.home/'deny-auth').exists() else paramiko.AUTH_FAILED
    def get_allowed_auths(self,user): return 'password' if self.node.name=='gateway' else 'publickey'
    def check_channel_request(self,kind,chanid):
        return paramiko.OPEN_SUCCEEDED if kind=='session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
    def check_channel_exec_request(self,channel,command):
        threading.Thread(target=execute,args=(self.node,channel,command.decode()),daemon=True).start(); return True


def execute(node,channel,command):
    time.sleep(.015)
    record(node.name,{'exec':'bootstrap' if not command.startswith('agentspace-') else command,'commandBytes':len(command.encode())})
    if command.startswith('agentspace-'):
        channel.send_stderr(('command not found: '+command.split()[0]+'\n').encode()); channel.send_exit_status(127); channel.close(); return
    if (node.home/'missing-python').exists():
        channel.send_stderr(b'python3: command not found\n'); channel.send_exit_status(127); channel.close(); return
    env=dict(os.environ,HOME=str(node.home),PATH=str(root/'bin')+':'+str(Path(sys.executable).parent)+':'+os.environ['PATH'])
    process=subprocess.Popen(['/bin/sh','-c',command],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env)
    with lock: processes.add(process)
    lane=''; requests={}
    def copy_input():
        nonlocal lane
        pending=b''
        try:
            while True:
                chunk=channel.recv(32768)
                if not chunk: break
                pending+=chunk
                while b'\n' in pending:
                    line,pending=pending.split(b'\n',1); row=json.loads(line)
                    if row.get('type')=='bootstrap': lane=row['config']['lane']; record(node.name,{'lane':lane,'pid':process.pid})
                    if row.get('type')=='package': record(node.name,{'upload':row['digest']})
                    if row.get('type')=='request': requests[row['id']]=row['op']; record(node.name,{'request':row['op'],'lane':lane})
                    process.stdin.write(line+b'\n'); process.stdin.flush()
                if len(pending)>2*1024*1024: break
        except (OSError,EOFError,ValueError): pass
        finally:
            try: process.stdin.close()
            except OSError: pass
    def copy_error():
        try:
            while True:
                chunk=os.read(process.stderr.fileno(),8192)
                if not chunk: return
                with (node.home/'errors.log').open('ab') as f: f.write(chunk[:65536])
                channel.send_stderr(chunk)
        except (OSError,EOFError): pass
    threading.Thread(target=copy_input,daemon=True).start(); threading.Thread(target=copy_error,daemon=True).start()
    try:
        for line in process.stdout:
            if lane=='transfer':
                row=json.loads(line); operation=requests.get(row.get('id'))
                if row.get('type')=='reply' and operation in ('image.chunk','image.finish') and (node.home/('hold-'+operation)).exists():
                    record(node.name,{'held':operation})
                    deadline=time.monotonic()+20
                    while (node.home/('hold-'+operation)).exists() and not stopping.is_set() and time.monotonic()<deadline:time.sleep(.01)
            if node.name=='gateway' and lane=='input' and (node.home/'kill-after-dispatch').exists():
                row=json.loads(line)
                if row.get('type')=='reply' and row.get('ok') and requests.get(row.get('id')) in ('input','send','rename','close','create'):
                    (node.home/'kill-after-dispatch').unlink(); channel.close(); break
            channel.sendall(line)
        if process.poll() is None:
            try: process.wait(6)
            except subprocess.TimeoutExpired: process.terminate()
        if not channel.closed: channel.send_exit_status(process.wait(6))
    except (OSError,EOFError,subprocess.TimeoutExpired): pass
    finally:
        channel.close()
        if process.poll() is None:
            process.terminate()
            try: process.wait(6)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
        for pipe in (process.stdin,process.stdout,process.stderr):
            try: pipe.close()
            except OSError: pass
        with lock: processes.discard(process)

nodes['gateway']=Node('gateway'); nodes['a']=Node('a'); nodes['b']=Node('b','work')
machines=[{'id':c*32,'label':'Mac','target':'peer-'+c,'session':'default' if c=='a' else 'work','enabled':True} for c in ('a','b')]
def save_machines(): (nodes['gateway'].herdr.root/'machines.json').write_text(json.dumps(machines))
save_machines()
known=sshdir/'known_hosts'
known.write_text(''.join(f'[127.0.0.1]:{nodes[c].port} {nodes[c].key.get_name()} {nodes[c].key.get_base64()}\n' for c in ('a','b'))); known.chmod(0o600)
config=sshdir/'config'
config.write_text(''.join(f'Host peer-{c}\n HostName 127.0.0.1\n Port {nodes[c].port}\n User fixture\n IdentityFile {sshdir}/id_rsa\n IdentitiesOnly yes\n IdentityAgent none\n UserKnownHostsFile {known}\n GlobalKnownHostsFile /dev/null\n' for c in ('a','b'))); config.chmod(0o600)
(root/'bin').mkdir(mode=0o700)
wrapper=root/'bin/ssh'; wrapper.write_text('#!/bin/sh\nexec /usr/bin/ssh -F '+shlex.quote(str(config))+' "$@"\n'); wrapper.chmod(0o700)

control=socket.socket(); control.bind(('127.0.0.1',0)); control.listen(); control.settimeout(.2); listeners.append(control)
def alive(pid):
    try: os.kill(pid,0); return True
    except ProcessLookupError: return False

def handle_control(connection):
    with connection:
        row=json.loads(connection.makefile('rb').readline(65536)); op=row['op']; name=row.get('node','gateway'); node=nodes[name]
        if op=='stats':
            with lock:
                result={'events':list(events),'nodes':{n:{'api':list(v.herdr.calls),'cli':(v.herdr.root/'cli-calls').read_text().splitlines() if (v.herdr.root/'cli-calls').exists() else [],'mouse':[json.loads(x) for x in (v.herdr.root/'mouse-controls').read_text().splitlines()] if (v.herdr.root/'mouse-controls').exists() else [],'observers':[int(pid) for pid in (v.herdr.root/'observer-pids').read_text().splitlines() if alive(int(pid))] if (v.herdr.root/'observer-pids').exists() else [],'cache':list(map(str,(v.home/'.cache/agentspace/bridges').glob('*/bridge.pyz')))} for n,v in nodes.items()},'workers':[p.pid for p in processes]}
        elif op=='attachments':
            result={}
            for name,value in nodes.items():
                files=[]
                for path in sorted((value.home/'.cache/agentspace/attachments').glob('ag-image-*')):
                    if path.is_symlink() or not path.is_file():continue
                    data=path.read_bytes()
                    files.append({'path':str(path),'mode':path.stat().st_mode&0o777,'bytes':base64.b64encode(data).decode(),'sha256':hashlib.sha256(data).hexdigest()})
                result[name]=files
        elif op=='metadata':
            node.herdr.agents[0]['tokens']=row.get('tokens',{})
            result={'ok':True}
        elif op=='replace': node.herdr.replace_socket(); result={'ok':True}
        elif op=='route':
            next(m for m in machines if m['id']==row['machine']).update(row['changes']); save_machines(); result={'ok':True}
        elif op=='bad-host':
            lines=known.read_text().splitlines()
            lines[0]=f'[127.0.0.1]:{nodes["a"].port} {nodes["b"].key.get_name()} {nodes["b"].key.get_base64()}'
            known.write_text('\n'.join(lines)+'\n'); result={'ok':True}
        elif op=='flag':
            allowed={'deny-auth','missing-python','kill-after-dispatch','stall-discovery','flood','older-herdr','mouse-report','hold-image.chunk','hold-image.finish'}
            flag=row['flag']
            if flag not in allowed: raise ValueError('Unknown fixture control')
            directory=node.herdr.root if flag in ('stall-discovery','flood','older-herdr','mouse-report') else node.home
            path=directory/flag
            if row.get('enabled',True): path.touch()
            else: path.unlink(missing_ok=True)
            result={'ok':True}
        elif op=='lost-ack': node.herdr.lose_next_input_ack(); result={'ok':True}
        elif op=='lost-management-ack': node.herdr.lose_management_ack=True; result={'ok':True}
        else: raise ValueError('Unknown fixture operation')
        connection.sendall((json.dumps(result)+'\n').encode())
def controls():
    while not stopping.is_set():
        try: connection,_=control.accept()
        except socket.timeout: continue
        except OSError: return
        threading.Thread(target=handle_control,args=(connection,),daemon=True).start()
threading.Thread(target=controls,daemon=True).start()
def stop(*_): stopping.set()
signal.signal(signal.SIGTERM,stop); signal.signal(signal.SIGINT,stop)
print(json.dumps({'gateway':{'port':nodes['gateway'].port,'fingerprint':nodes['gateway'].fingerprint},'peers':[{'id':c*32,'port':nodes[c].port} for c in ('a','b')],'root':str(root),'controlPort':control.getsockname()[1]}),flush=True)
while not stopping.wait(.2): pass
for listener in listeners: listener.close()
with lock: active_transports=list(transports); active_processes=list(processes)
for transport in active_transports: transport.close()
for process in active_processes:
    try: process.wait(6)
    except subprocess.TimeoutExpired: process.terminate()
for node in nodes.values(): node.herdr.__exit__()
