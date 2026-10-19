"""Herdr JSON API: one local socket per bounded correlated request."""
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import socket
import stat
import threading
import time

try:
    from .protocol import BridgeRejected, DeliveryUncertain, read_record, validate_route, IDENTITY
    from .gate_rules import validate_input, validate_send
except ImportError:
    from protocol import BridgeRejected, DeliveryUncertain, read_record, validate_route, IDENTITY
    from gate_rules import validate_input, validate_send


def server_generation(socket_path, style):
    path = Path(socket_path).resolve(strict=True); info = path.stat()
    if not stat.S_ISSOCK(info.st_mode): raise BridgeRejected('offline')
    if style not in ('ssh','native','peer'): raise BridgeRejected('invalid_request')
    if hasattr(info, 'st_birthtime'):
        stamp = int(info.st_birthtime) if style == 'native' else info.st_birthtime
    else: stamp = info.st_ctime_ns
    canonical=str(path)
    if style=='native':
        # Foundation URL.resolvingSymlinksInPath presents Darwin's standard
        # /private aliases as /tmp, /var and /etc. Match the existing XPC key.
        for alias in ('/tmp','/var','/etc'):
            private='/private'+alias
            if canonical==private or canonical.startswith(private+'/'):
                candidate=canonical[len('/private'):]
                if Path(candidate).resolve()==path: canonical=candidate
                break
    return hashlib.sha256(f'{canonical}:{info.st_dev}:{info.st_ino}:{stamp}'.encode()).hexdigest()


def failed(row):
    return (not isinstance(row, dict) or row.get('error') is not None
            or row.get('ok') is False or row.get('success') is False)


class LocalApi:
    def __init__(self, socket_path, generation_style):
        self.socket_path, self.style = socket_path, generation_style
        self._counter = 0; self._lock = threading.Lock()
        self._dispatch_lock = threading.Lock()

    def generation(self):
        try: return server_generation(self.socket_path, self.style)
        except (OSError, ValueError): raise BridgeRejected('offline')

    def call(self, method, params, deadline, before_send=None):
        with self._lock:
            self._counter += 1; identifier = str(self._counter)
        request = json.dumps({'id':identifier,'method':method,'params':params}, separators=(',', ':')).encode()+b'\n'
        sent = False
        try:
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(max(.001, deadline - time.monotonic()))
                connection.connect(self.socket_path)
                if before_send: before_send()
                sent = True
                connection.sendall(request)
                connection.settimeout(max(.001, deadline - time.monotonic()))
                with connection.makefile('rb') as source: response = read_record(source)
                if (method=='workspace.close' and isinstance(response,dict) and response.get('id')==identifier
                        and isinstance(response.get('error'),dict)
                        and response['error'].get('code')=='workspace_group_close_required'):
                    # Herdr explicitly guarantees that no workspace in the group closed.
                    raise BridgeRejected('workspace_group_close_required')
                if response is None or response.get('id') != identifier or failed(response):
                    raise ValueError('Invalid Herdr response')
                if method.startswith('pane.send'):
                    result = response.get('result')
                    if failed(result) or result.get('type') != 'ok': raise ValueError('Missing input acknowledgement')
                return response
        except BridgeRejected: raise
        except (OSError, ValueError, TypeError):
            if sent and method.startswith('pane.send'): raise DeliveryUncertain()
            raise BridgeRejected('offline')

    def listing(self, method, field, deadline):
        response = self.call(method, {}, deadline)
        result = response.get('result')
        rows = result.get(field) if isinstance(result, dict) else None
        if not isinstance(rows, list) or len(rows) > 4096:
            raise BridgeRejected('invalid_request')
        return rows

    def panes(self, deadline):
        try:
            return self.listing('pane.list', 'panes', deadline)
        except BridgeRejected as error:
            # Older Herdr versions may not implement pane.list. Malformed
            # successful responses must not fall back to stale agent rows.
            if error.code != 'offline': raise
            return None

    @staticmethod
    def identity(row):
        if not isinstance(row, dict): return None
        key = tuple(row.get(field) for field in ('terminal_id', 'pane_id', 'workspace_id', 'tab_id'))
        return key if all(isinstance(value, str) and IDENTITY.fullmatch(value) for value in key) else None

    def catalog(self):
        generation = self.generation(); deadline = time.monotonic()+4
        panes = self.panes(deadline)
        try:
            agents = self.listing('agent.list', 'agents', deadline)
        except BridgeRejected:
            if panes is None: raise
            agents = []
        if panes is not None:
            # A shell survives its agent process. pane.list is authoritative;
            # agent.list only contributes metadata for the exact same terminal.
            identities = Counter(self.identity(row) for row in agents)
            metadata = {self.identity(row): row for row in agents
                        if self.identity(row) and identities[self.identity(row)] == 1}
            terminals = Counter(row.get('terminal_id') for row in panes
                                if isinstance(row, dict) and isinstance(row.get('terminal_id'), str))
            agents = []
            for pane in panes:
                key = self.identity(pane)
                if key is None or terminals[key[0]] != 1: continue
                row = {**metadata.get(key, {}), **pane}
                label = pane.get('label')
                if isinstance(label, str) and label.strip(): row['title'] = label
                agents.append(row)
        extras = {}
        for method, field in [('workspace.list','workspaces'),('tab.list','tabs')]:
            try: extras[field] = self.listing(method, field, deadline)
            except BridgeRejected: extras[field] = []
        if generation != self.generation(): raise BridgeRejected('generation_changed')
        return {'serverIdentity':generation,'catalog':{'result':{'agents':agents}},**extras}

    def member(self, route):
        validate_route(route)
        if self.generation() != route['generation']: raise BridgeRejected('generation_changed')
        deadline = time.monotonic()+4
        rows = self.panes(deadline)
        if rows is None: rows = self.listing('agent.list', 'agents', deadline)
        matches = [row for row in rows if isinstance(row, dict) and row.get('terminal_id') == route['terminal']]
        if (len(matches) != 1 or matches[0].get('pane_id') != route['pane']
                or self.identity(matches[0]) is None):
            raise BridgeRejected('terminal_missing')
        if self.generation() != route['generation']: raise BridgeRejected('generation_changed')
        return matches[0]

    def dispatch(self, route, payload, reviewed=False, cancelled=lambda:False):
        try:
            if reviewed:
                if set(payload) != {'text'}: raise ValueError('Invalid reviewed message')
                params = validate_send(payload['text']); method = 'pane.send_input'
            else: method, params = validate_input(payload)
        except (ValueError, TypeError, UnicodeError): raise BridgeRejected('invalid_request')
        with self._dispatch_lock:
            if cancelled(): raise BridgeRejected('invalid_request')
            self.member(route)
            def before_send():
                if cancelled(): raise BridgeRejected('invalid_request')
                if self.generation() != route['generation']: raise BridgeRejected('generation_changed')
            self.call(method, {'pane_id':route['pane'],**params}, time.monotonic()+4, before_send)
        return {'sent':True}
