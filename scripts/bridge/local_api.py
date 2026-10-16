"""Herdr JSON API: one local socket per bounded correlated request."""
import hashlib
import json
import os
from pathlib import Path
import socket
import stat
import threading
import time

try:
    from .protocol import BridgeRejected, DeliveryUncertain, read_record, validate_route
    from .gate_rules import validate_input, validate_send
except ImportError:
    from protocol import BridgeRejected, DeliveryUncertain, read_record, validate_route
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

    def catalog(self):
        generation = self.generation(); deadline = time.monotonic()+4
        response = self.call('agent.list', {}, deadline)
        agents = response.get('result', {}).get('agents')
        if not isinstance(agents, list) or len(agents) > 4096: raise BridgeRejected('invalid_request')
        extras = {}
        for method, field in [('workspace.list','workspaces'),('tab.list','tabs')]:
            try:
                result = self.call(method, {}, deadline).get('result', {}).get(field, [])
                extras[field] = result if isinstance(result, list) and len(result) <= 4096 else []
            except BridgeRejected: extras[field] = []
        # pane.rename changes the manual label, which agent.list omits on
        # supported Herdr versions. Join by the full local identity; never
        # treat a pane number alone as proof that it is the same terminal.
        try:
            panes = self.call('pane.list', {}, deadline).get('result', {}).get('panes', [])
            if isinstance(panes, list) and len(panes) <= 4096:
                fields = ('terminal_id', 'pane_id', 'workspace_id', 'tab_id')
                labels = {}; seen = set()
                for pane in panes:
                    if not isinstance(pane, dict): continue
                    key = tuple(pane.get(field) for field in fields)
                    if not all(isinstance(value, str) and value for value in key): continue
                    if key in seen:
                        labels.pop(key, None)
                        continue
                    seen.add(key)
                    label = pane.get('label')
                    if isinstance(label, str) and label.strip(): labels[key] = label
                for agent in agents:
                    if not isinstance(agent, dict): continue
                    key = tuple(agent.get(field) for field in fields)
                    if all(isinstance(value, str) for value in key) and key in labels:
                        agent['title'] = labels[key]
        except BridgeRejected:
            pass  # Older servers can still provide their automatic titles.
        if generation != self.generation(): raise BridgeRejected('generation_changed')
        return {'serverIdentity':generation,'catalog':response,**extras}

    def member(self, route):
        validate_route(route)
        if self.generation() != route['generation']: raise BridgeRejected('generation_changed')
        listing = self.call('agent.list', {}, time.monotonic()+4)
        agents = listing.get('result', {}).get('agents')
        if not isinstance(agents, list) or len(agents) > 4096: raise BridgeRejected('invalid_request')
        matches = [a for a in agents if isinstance(a, dict) and a.get('terminal_id') == route['terminal']]
        if len(matches) != 1 or matches[0].get('pane_id') != route['pane']:
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
