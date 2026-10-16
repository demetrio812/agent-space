"""Disposable SSH protocol fixture. No real accounts, keys or agent processes."""
import base64
import hashlib
import json
import os
import shlex
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

import paramiko

root = Path(sys.argv[1])
key = paramiko.RSAKey.generate(2048)
identity = 'a' * 64
lock = threading.Lock()

def record(event):
    with lock:
        with (root / 'events.jsonl').open('a') as file:
            file.write(json.dumps(event) + '\n')

def execute(channel, command):
    # Let Paramiko acknowledge the exec request before writing and closing.
    time.sleep(.05)
    record({'command': 'python3 bridge bootstrap' if not command.startswith('agentspace-') else command})
    if command == 'agentspace-catalog-v1' and (root / 'gate-denied').exists():
        channel.send_stderr(b'Herdr unavailable or session identity changed.\n')
        channel.send_exit_status(1)
        channel.close()
        return
    if (root / 'normal-shell').exists():
        if command.startswith('agentspace-'):
            channel.send_stderr(('zsh:1: command not found: ' + command.split()[0] + '\n').encode())
            channel.send_exit_status(127)
            channel.close()
            return
        env = dict(os.environ, HOME=str(root), PATH=str(Path(sys.executable).parent)+':'+os.environ['PATH'])
        if (root/'broken-python').exists():
            broken=root/'broken-bin'; broken.mkdir(exist_ok=True)
            (broken/'python3').write_text('#!/bin/sh\nexit 72\n'); (broken/'python3').chmod(0o700)
            env['PATH']=str(broken)+':'+env['PATH']
        with subprocess.Popen(['/bin/sh', '-c', command], env=env,
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
            def copy_input():
                pending=b''
                try:
                    while True:
                        chunk = channel.recv(32768)
                        if not chunk:
                            break
                        process.stdin.write(chunk)
                        process.stdin.flush()
                        pending+=chunk
                        while b'\n' in pending:
                            line,pending=pending.split(b'\n',1)
                            try: value=json.loads(line)
                            except (ValueError,UnicodeError): continue
                            if value.get('type')=='package': record({'upload':value.get('digest')})
                            if value.get('type')=='request': record({'bridgeRequest':value.get('op')})
                        if len(pending)>2*1024*1024: raise ValueError('Fixture input exceeds bound')
                except (OSError, EOFError):
                    pass
                finally:
                    try:
                        process.stdin.close()
                    except OSError:
                        pass
            def copy_error():
                while True:
                    chunk = os.read(process.stderr.fileno(), 32768)
                    if not chunk:
                        return
                    with (root/'bridge-errors.log').open('ab') as output: output.write(chunk[:65536])
                    channel.send_stderr(chunk)
            threading.Thread(target=copy_input, daemon=True).start()
            errors = threading.Thread(target=copy_error, daemon=True)
            errors.start()
            try:
                while True:
                    chunk = os.read(process.stdout.fileno(), 32768)
                    if not chunk:
                        break
                    channel.sendall(chunk)
                channel.send_exit_status(process.wait(timeout=5))
                errors.join(timeout=1)
                channel.shutdown_write()
            finally:
                if process.poll() is None:
                    process.terminate()
                channel.close()
        return
    if command == 'agentspace-catalog-v1':
        result = {'serverIdentity': identity, 'inputEnabled': True, 'terminalInputEnabled': True, 'terminalViewportEnabled': True,
                  'catalog': {'result': {'agents': [{'terminal_id': 't1', 'pane_id': 'p1',
                   'workspace_id': 'w1', 'tab_id': 'tab1', 'terminal_title': 'SSH fixture',
                   'agent_status': 'idle'}]}}}
        channel.sendall(json.dumps(result) + '\n')
    elif command.startswith('agentspace-control-v1 '):
        pieces=command.split(); width,height=int(pieces[3]),int(pieces[4]); seq=0
        def frame():
            channel.sendall(json.dumps({'type':'terminal.frame','encoding':'ansi','width':width,'height':height,'seq':seq,'full':True,'bytes':base64.b64encode(b'viewport fixture').decode()})+'\n')
        frame()
        pending=b''
        while True:
            chunk=channel.recv(256)
            if not chunk: return
            pending+=chunk
            while b'\n' in pending:
                line,pending=pending.split(b'\n',1); row=json.loads(line)
                record({'resize':row})
                width,height=row['cols'],row['rows']; seq+=1; frame()
    elif command.startswith('agentspace-observe-v1 '):
        frame = {'type': 'terminal.frame', 'encoding': 'ansi', 'width': 175, 'height': 55,
                 'seq': 0, 'full': True, 'bytes': base64.b64encode(b'\x1b[55;1Hremote bottom menu').decode()}
        channel.sendall(json.dumps(frame) + '\n')
        channel.sendall(json.dumps({'type': 'terminal.closed', 'reason': 'Fixture complete'}) + '\n')
    elif command.startswith(('agentspace-send-v1 ', 'agentspace-input-v1 ')):
        if not (root / 'uncertain').exists():
            channel.sendall('{"sent":true}\n')
    else:
        channel.send_exit_status(2)
        channel.close()
        return
    channel.send_exit_status(0)
    channel.shutdown_write()
    channel.close()

class FixtureServer(paramiko.ServerInterface):
    def check_auth_password(self, username, password):
        record({'authentication': username})
        return paramiko.AUTH_SUCCESSFUL if username == 'fixture' and password == 'disposable' else paramiko.AUTH_FAILED
    def get_allowed_auths(self, username):
        return 'password'
    def check_channel_request(self, kind, chanid):
        return paramiko.OPEN_SUCCEEDED if kind == 'session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
    def check_channel_exec_request(self, channel, command):
        if command == b'agentspace-catalog-v1' and (root / 'hold-catalog-exec').exists():
            record({'command': command.decode(), 'held': True})
            time.sleep(30)
            return True
        if command.startswith(b'agentspace-send-v1 ') and (root / 'hold-exec').exists():
            record({'command': command.decode()})
            time.sleep(30)  # Simulate a server that never acknowledges exec.
            return True
        if command.startswith(b'agentspace-send-v1 ') and (root / 'early-close').exists():
            record({'command': command.decode()})
            channel.close()
            return True
        threading.Thread(target=execute, args=(channel, command.decode()), daemon=True).start()
        return True

def connection(client):
    transport = paramiko.Transport(client)
    transport.add_server_key(key)
    channels = []
    try:
        transport.start_server(server=FixtureServer())
        while transport.is_active():
            channel = transport.accept(1)
            if channel is not None:
                channels.append(channel)
    except (EOFError, paramiko.SSHException):
        pass
    finally:
        transport.close()

listener = socket.socket()
listener.bind(('127.0.0.1', 0))
listener.listen()
fingerprint = 'SHA256:' + base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip('=')
print(json.dumps({'port': listener.getsockname()[1], 'fingerprint': fingerprint}), flush=True)
while True:
    client, _ = listener.accept()
    threading.Thread(target=connection, args=(client,), daemon=True).start()
