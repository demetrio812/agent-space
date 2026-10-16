#!/usr/bin/env python3
"""SSH forced-command endpoint for discovery, observation and opt-in text input."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import signal
import threading
import sys
import time

MAX_CATALOG_BYTES = 2 * 1024 * 1024
MAX_ERROR_BYTES = 64 * 1024
MAX_INPUT_BYTES = 16384
SEND_COMMAND = re.compile(r'agentspace-send-v1 ([0-9a-f]{64}) ([A-Za-z0-9_.:@%+/][A-Za-z0-9_.:@%+/-]{0,255}) ([A-Za-z0-9+/=]{1,21848})', re.ASCII)
OBSERVE_COMMAND = re.compile(r'agentspace-observe-v1 ([0-9a-f]{64}) ([A-Za-z0-9_.:@%+/][A-Za-z0-9_.:@%+/-]{0,255})', re.ASCII)
INPUT_COMMAND = re.compile(r'agentspace-input-v1 ([0-9a-f]{64}) ([A-Za-z0-9_.:@%+/][A-Za-z0-9_.:@%+/-]{0,255}) ([A-Za-z0-9+/=]{1,87384})', re.ASCII)
CONTROL_COMMAND = re.compile(r'agentspace-control-v1 ([0-9a-f]{64}) ([A-Za-z0-9_.:@%+/][A-Za-z0-9_.:@%+/-]{0,255}) ([0-9]{1,3}) ([0-9]{1,3})', re.ASCII)
KEY_NAME = re.compile(r'(?:[a-z0-9]|up|down|left|right|enter|esc|tab|backspace|delete|insert|home|end|pageup|pagedown|space|f[1-9]|f1[0-2])', re.ASCII)


def parse_command(command):
    if command == 'agentspace-catalog-v1':
        return ('catalog',)
    match = OBSERVE_COMMAND.fullmatch(command)
    if match:
        return ('observe', match[1], match[2])
    match = SEND_COMMAND.fullmatch(command)
    if match:
        return ('send', match[1], match[2], match[3])
    match = INPUT_COMMAND.fullmatch(command)
    if match:
        return ('input', match[1], match[2], match[3])
    match = CONTROL_COMMAND.fullmatch(command)
    if match and valid_viewport(int(match[3]), int(match[4])):
        return ('control', match[1], match[2], int(match[3]), int(match[4]))
    raise ValueError('Unsupported AgentSpace command.')


def server_identity(socket_path):
    socket = Path(socket_path)
    stat = socket.stat()  # A missing server must never become an implicit launch.
    identity = f'{socket.resolve()}:{stat.st_dev}:{stat.st_ino}:{stat.st_birthtime}'
    return hashlib.sha256(identity.encode()).hexdigest()


def bounded_catalog(binary, env, arguments=('agent', 'list'), deadline=None):
    """Drain both pipes with size and wall-clock limits, including noisy failures."""
    with subprocess.Popen([binary, *arguments], env=env, stdin=subprocess.DEVNULL,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
        try:
            output = bytearray()
            error_bytes = 0
            deadline = deadline if deadline is not None else time.monotonic() + 4
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ, 'stdout')
                selector.register(process.stderr, selectors.EVENT_READ, 'stderr')
                while selector.get_map():
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise RuntimeError('Herdr catalog request timed out')
                    for key, _ in selector.select(remaining):
                        chunk = os.read(key.fileobj.fileno(), 8192)
                        if not chunk:
                            selector.unregister(key.fileobj)
                        elif key.data == 'stdout':
                            output.extend(chunk)
                            if len(output) > MAX_CATALOG_BYTES:
                                raise RuntimeError('Herdr catalog response exceeds limit')
                        else:
                            error_bytes += len(chunk)
                            if error_bytes > MAX_ERROR_BYTES:
                                raise RuntimeError('Herdr catalog error output exceeds limit')
                if process.wait(timeout=max(0.001, deadline - time.monotonic())):
                    raise RuntimeError('Herdr catalog request failed')
            return output
        except BaseException:
            process.kill()
            process.wait()
            raise


def catalog(binary, socket_path, include_workspaces=False):
    identity = server_identity(socket_path)
    env = os.environ.copy()
    env['HERDR_SOCKET_PATH'] = str(Path(socket_path))
    deadline = time.monotonic() + 4
    response = json.loads(bounded_catalog(binary, env, deadline=deadline))
    if (not isinstance(response, dict) or response.get('error') is not None
            or response.get('ok') is False or response.get('success') is False
            or not isinstance(response.get('result'), dict)
            or not isinstance(response['result'].get('agents'), list)):
        raise RuntimeError('Herdr did not return an agent catalog')
    workspaces = []
    tabs = []
    if include_workspaces:
        try:
            listing = json.loads(bounded_catalog(binary, env, ('workspace', 'list'), deadline))
            result = listing.get('result', {}).get('workspaces', [])
            if isinstance(result, list) and len(result) <= 4096 and not listing.get('error'):
                workspaces = result
        except (RuntimeError, ValueError, OSError, AttributeError):
            pass  # Older Herdr servers can still provide sessions without workspace labels.
    if include_workspaces:
        try:
            listing = json.loads(bounded_catalog(binary, env, ('tab', 'list'), deadline))
            result = listing.get('result', {}).get('tabs', [])
            if isinstance(result, list) and len(result) <= 4096 and not listing.get('error'):
                tabs = result
        except (RuntimeError, ValueError, OSError, AttributeError):
            pass
    if identity != server_identity(socket_path):
        raise RuntimeError('Herdr restarted during the catalog request')
    return {'serverIdentity': identity, 'catalog': response, 'workspaces': workspaces, 'tabs': tabs}


def observe(binary, socket_path, identity, terminal):
    # Validate even direct callers; neither argument ever reaches a shell.
    parse_command(f'agentspace-observe-v1 {identity} {terminal}')
    if server_identity(socket_path) != identity:
        raise RuntimeError('Herdr server identity changed')
    current = catalog(binary, socket_path)
    if current['serverIdentity'] != identity:
        raise RuntimeError('Herdr server identity changed')
    matches = [agent for agent in current['catalog']['result']['agents']
               if isinstance(agent, dict) and agent.get('terminal_id') == terminal]
    if len(matches) != 1:
        raise RuntimeError('Herdr terminal is no longer present')
    if server_identity(socket_path) != identity:
        raise RuntimeError('Herdr server identity changed')
    env = os.environ.copy()
    env['HERDR_SOCKET_PATH'] = str(Path(socket_path))
    dimensions = []
    pane = matches[0].get('pane_id', '')
    if isinstance(pane, str) and re.fullmatch(r'[A-Za-z0-9_.:@%+/][A-Za-z0-9_.:@%+/-]{0,255}', pane):
        try:
            listing = json.loads(bounded_catalog(binary, env, ('pane', 'layout', '--pane', pane)))
            panes = listing.get('result', {}).get('layout', {}).get('panes', [])
            rows = [row for row in panes if isinstance(row, dict) and row.get('pane_id') == pane]
            if len(rows) == 1 and not listing.get('error') and listing.get('ok') is not False:
                rect = rows[0].get('rect', {})
                width, height = rect.get('width'), rect.get('height')
                # Match Android ObserveProtocol bounds, including total cell count.
                if (type(width) is int and type(height) is int and 1 <= width <= 512
                        and 1 <= height <= 256 and width * height <= 65536):
                    dimensions = ['--cols', str(width), '--rows', str(height)]
        except (RuntimeError, ValueError, OSError, AttributeError, TypeError):
            pass  # Older Herdr versions can still use the default observer projection.
    if server_identity(socket_path) != identity:
        raise RuntimeError('Herdr server identity changed')
    with open(os.devnull, 'rb') as empty:
        os.dup2(empty.fileno(), 0)
    os.execve(binary, [binary, 'terminal', 'session', 'observe', terminal, *dimensions], env)


def validate_send(text):
    if (not isinstance(text, str) or not 1 <= len(text.encode('utf-8')) <= MAX_INPUT_BYTES
            or not text.strip() or any((ord(c) < 32 and c not in '\n\t') or 127 <= ord(c) < 160 for c in text)):
        raise ValueError('Input contains terminal control characters or exceeds its limit')
    return {'text': text, 'keys': ['Enter']}


def validate_input(value):
    if not isinstance(value, dict) or len(value) != 1:
        raise ValueError('Invalid terminal input')
    if set(value) in ({'text'}, {'paste'}):
        paste = 'paste' in value
        text = value['paste' if paste else 'text']
        if (not isinstance(text, str) or not 1 <= len(text.encode('utf-8')) <= MAX_INPUT_BYTES
                or any(ord(c) < 32 or 127 <= ord(c) < 160 for c in text)):
            raise ValueError('Invalid terminal text')
        return ('pane.send_input', {'text': text, 'keys': []}) if paste else ('pane.send_text', {'text': text})
    if set(value) == {'keys'}:
        keys = value['keys']
        if not isinstance(keys, list) or not 1 <= len(keys) <= 32:
            raise ValueError('Invalid terminal keys')
        for key in keys:
            if not isinstance(key, str) or len(key) > 40:
                raise ValueError('Invalid terminal key')
            parts = key.split('+'); name, modifiers = parts[-1], parts[:-1]
            if (len(set(modifiers)) != len(modifiers)
                    or any(m not in {'ctrl', 'alt', 'shift', 'cmd'} for m in modifiers)
                    or not KEY_NAME.fullmatch(name)):
                raise ValueError('Invalid terminal key')
        return 'pane.send_keys', {'keys': list(keys)}
    raise ValueError('Unsupported terminal input')


def send_text(binary, socket_path, identity, terminal, encoded, allow_input=False):
    if not allow_input:
        raise ValueError('Input is not enabled for this headset key.')
    parse_command(f'agentspace-send-v1 {identity} {terminal} {encoded}')
    raw = base64.b64decode(encoded, validate=True)
    if not 1 <= len(raw) <= MAX_INPUT_BYTES or base64.b64encode(raw).decode() != encoded:
        raise ValueError('Invalid input size or encoding')
    text = raw.decode('utf-8', errors='strict')
    validate_send(text)
    if server_identity(socket_path) != identity:
        raise RuntimeError('Herdr server identity changed')
    current = catalog(binary, socket_path)
    targets = [a for a in current['catalog']['result']['agents']
               if isinstance(a, dict) and a.get('terminal_id') == terminal]
    if current['serverIdentity'] != identity or len(targets) != 1:
        raise RuntimeError('Terminal unavailable')
    pane = targets[0].get('pane_id', '')
    if not isinstance(pane, str) or not re.fullmatch(r'[A-Za-z0-9_.:@%+/][A-Za-z0-9_.:@%+/-]{0,255}', pane):
        raise RuntimeError('Invalid pane identity')
    if server_identity(socket_path) != identity:
        raise RuntimeError('Herdr server identity changed')
    env = os.environ.copy()
    env['HERDR_SOCKET_PATH'] = str(Path(socket_path))
    # The Herdr run CLI consumes the remaining argv literally, including leading dashes.
    # No retries: a failed acknowledgement may still mean the terminal received the text.
    output = bounded_catalog(binary, env, ('pane', 'run', pane, text))
    # Current Herdr acknowledges successful pane.run with exit 0 and no stdout.
    response = json.loads(output) if output.strip() else {'result': {'type': 'ok'}}
    if (not isinstance(response, dict) or response.get('error') is not None
            or response.get('ok') is False or response.get('success') is False or 'result' not in response):
        raise RuntimeError('Herdr did not acknowledge input')
    return {'sent': True}


def terminal_input(binary, socket_path, identity, terminal, encoded, allow_input=False):
    if not allow_input:
        raise ValueError('Terminal input is not enabled for this client key.')
    parse_command(f'agentspace-input-v1 {identity} {terminal} {encoded}')
    raw = base64.b64decode(encoded, validate=True)
    if not 1 <= len(raw) <= 65536 or base64.b64encode(raw).decode() != encoded:
        raise ValueError('Invalid terminal input encoding')
    value = json.loads(raw.decode('utf-8', errors='strict'))
    method, params = validate_input(value)
    if method == 'pane.send_input':
        raise ValueError('Image paste requires a persistent connection')
    operation = ['send-text', params['text']] if method == 'pane.send_text' else ['send-keys', *params['keys']]
    if server_identity(socket_path) != identity:
        raise RuntimeError('Herdr server identity changed')
    current = catalog(binary, socket_path)
    targets = [a for a in current['catalog']['result']['agents']
               if isinstance(a, dict) and a.get('terminal_id') == terminal]
    if current['serverIdentity'] != identity or len(targets) != 1:
        raise RuntimeError('Terminal unavailable')
    pane = targets[0].get('pane_id', '')
    if not isinstance(pane, str) or not re.fullmatch(r'[A-Za-z0-9_.:@%+/][A-Za-z0-9_.:@%+/-]{0,255}', pane):
        raise RuntimeError('Invalid pane identity')
    if server_identity(socket_path) != identity:
        raise RuntimeError('Herdr server identity changed')
    env = os.environ.copy()
    env['HERDR_SOCKET_PATH'] = str(Path(socket_path))
    output = bounded_catalog(binary, env, ('pane', operation[0], pane, *operation[1:]))
    response = json.loads(output) if output.strip() else {'result': {'type': 'ok'}}
    if not isinstance(response, dict) or response.get('error') is not None or response.get('ok') is False or response.get('success') is False or 'result' not in response:
        raise RuntimeError('Herdr did not acknowledge terminal input')
    return {'sent': True}



def valid_viewport(cols, rows):
    return type(cols) is int and type(rows) is int and 1 <= cols <= 512 and 1 <= rows <= 256 and cols * rows <= 65536


def control_viewport(binary, socket_path, identity, terminal, cols, rows, allow_input, input_stream, output_stream, error_stream):
    if not allow_input or not valid_viewport(cols, rows):
        raise ValueError('Viewport control is not enabled or dimensions are invalid.')
    parse_command(f'agentspace-control-v1 {identity} {terminal} {cols} {rows}')
    if server_identity(socket_path) != identity:
        raise RuntimeError('Herdr server identity changed')
    current = catalog(binary, socket_path)
    targets = [a for a in current['catalog']['result']['agents']
               if isinstance(a, dict) and a.get('terminal_id') == terminal]
    if current['serverIdentity'] != identity or len(targets) != 1:
        raise RuntimeError('Terminal unavailable')
    if server_identity(socket_path) != identity:
        raise RuntimeError('Herdr server identity changed')
    env = os.environ.copy()
    env['HERDR_SOCKET_PATH'] = str(Path(socket_path))
    process = subprocess.Popen([binary, 'terminal', 'session', 'control', terminal,
                                '--cols', str(cols), '--rows', str(rows)], env=env,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    failures = []
    cancelled = threading.Event()
    input_eof = []
    def resize_reader():
        try:
            while True:
                line = input_stream.readline(257)
                if not line:
                    input_eof.append(time.monotonic())
                    break
                if len(line) > 256 or not line.endswith(b'\n'):
                    raise ValueError('Invalid resize record')
                value = json.loads(line)
                if (not isinstance(value, dict) or set(value) != {'type', 'cols', 'rows'}
                        or value['type'] != 'terminal.resize' or not valid_viewport(value['cols'], value['rows'])
                        or server_identity(socket_path) != identity):
                    raise ValueError('Invalid resize record')
                process.stdin.write((json.dumps(value, separators=(',', ':')) + '\n').encode())
                process.stdin.flush()
        except Exception:
            failures.append('Resize rejected')
            cancelled.set()
            process.terminate()
        finally:
            try:
                process.stdin.close()
            except OSError:
                pass
    thread = threading.Thread(target=resize_reader, daemon=True)
    thread.start()
    previous_signals = {}
    def cancel_controller(*_):
        cancelled.set()
        process.terminate()
    if threading.current_thread() is threading.main_thread():
        for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            previous_signals[sig] = signal.signal(sig, cancel_controller)
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ, 'stdout')
            selector.register(process.stderr, selectors.EVENT_READ, 'stderr')
            error_bytes = 0
            record_bytes = 0
            while selector.get_map():
                if cancelled.is_set() or (input_eof and time.monotonic() - input_eof[0] > 1):
                    raise RuntimeError('Viewport control cancelled')
                for key, _ in selector.select(0.25):
                    chunk = os.read(key.fileobj.fileno(), 32768)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    if key.data == 'stderr':
                        error_bytes += len(chunk)
                        if error_bytes > MAX_ERROR_BYTES:
                            raise RuntimeError('Controller error output exceeded its limit')
                        error_stream.write(chunk)
                        error_stream.flush()
                    else:
                        for part in chunk.splitlines(keepends=True):
                            record_bytes += len(part)
                            if record_bytes > MAX_CATALOG_BYTES:
                                raise RuntimeError('Controller record exceeded its limit')
                            if part.endswith(b'\n'):
                                record_bytes = 0
                        output_stream.write(chunk)
                        output_stream.flush()
            if process.wait(timeout=2) != 0 or failures:
                raise RuntimeError('Viewport control ended or resize was rejected')
    finally:
        for sig, handler in previous_signals.items():
            signal.signal(sig, handler)
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=1)
        for pipe in (process.stdin, process.stdout, process.stderr):
            try:
                pipe.close()
            except OSError:
                pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--herdr', required=True)
    parser.add_argument('--socket', required=True)
    parser.add_argument('--allow-input', action='store_true', help='Allow explicit text + Enter for validated catalog sessions')
    args = parser.parse_args()
    try:
        command = parse_command(os.environ.get('SSH_ORIGINAL_COMMAND', ''))
        if os.environ.get('SSH_TTY'):
            raise ValueError('AgentSpace observation does not permit a PTY.')
        if command[0] == 'catalog':
            payload = catalog(args.herdr, args.socket, include_workspaces=True)
            payload['inputEnabled'] = args.allow_input
            payload['terminalInputEnabled'] = args.allow_input
            payload['terminalViewportEnabled'] = args.allow_input
            print(json.dumps(payload, separators=(',', ':')))
        elif command[0] == 'send':
            print(json.dumps(send_text(args.herdr, args.socket, *command[1:], allow_input=args.allow_input)))
        elif command[0] == 'input':
            print(json.dumps(terminal_input(args.herdr, args.socket, *command[1:], allow_input=args.allow_input)))
        elif command[0] == 'control':
            control_viewport(args.herdr, args.socket, *command[1:], args.allow_input, sys.stdin.buffer, sys.stdout.buffer, sys.stderr.buffer)
        else:
            observe(args.herdr, args.socket, command[1], command[2])
    except ValueError:
        sys.exit('AgentSpace command rejected; input requires an explicitly enabled headset key.')
    except Exception:
        sys.exit('Herdr unavailable or session identity changed; refresh the selected server catalog.')


if __name__ == '__main__':
    main()
