#!/usr/bin/env python3
"""Disposable Herdr CLI for exercising the real in-memory SSH bridge."""
import base64
import json
import os
from pathlib import Path
import sys

root = Path(os.environ['HOME'])
args = sys.argv[1:]
with (root / 'herdr-calls.jsonl').open('a') as file:
    file.write(json.dumps(args) + '\n')

if args == ['terminal', 'session', '--help']:
    print('control\nobserve')
elif args == ['machine', 'list', '--json']:
    print('[]')
elif args == ['agent', 'list']:
    print(json.dumps({'result': {'agents': [{'terminal_id': 't1', 'pane_id': 'p1',
          'workspace_id': 'w1', 'tab_id': 'tab1', 'terminal_title': 'Normal SSH fixture'}]}}))
elif args == ['workspace', 'list']:
    print(json.dumps({'result': {'workspaces': [{'workspace_id': 'w1', 'label': 'Fixture workspace'}]}}))
elif args == ['tab', 'list']:
    print(json.dumps({'result': {'tabs': []}}))
elif args[:2] == ['pane', 'layout']:
    print(json.dumps({'result': {'layout': {'panes': [{'pane_id': 'p1', 'rect': {'width': 90, 'height': 30}}]}}}))
elif args[:2] in (['pane', 'run'], ['pane', 'send-text'], ['pane', 'send-keys']):
    if (root / 'fail-after-input').exists():
        sys.exit(5)
    print(json.dumps({'result': {'type': 'ok'}}))
elif args[:3] == ['terminal', 'session', 'observe']:
    print(json.dumps({'type': 'terminal.frame', 'encoding': 'ansi', 'width': 90,
          'height': 30, 'seq': 0, 'full': True, 'bytes': base64.b64encode(b'normal SSH preview').decode()}))
    print(json.dumps({'type': 'terminal.closed', 'reason': 'Fixture complete'}))
elif args[:3] == ['terminal', 'session', 'control']:
    cols, rows = int(args[args.index('--cols') + 1]), int(args[args.index('--rows') + 1])
    seq = 0
    def frame():
        print(json.dumps({'type': 'terminal.frame', 'encoding': 'ansi', 'width': cols,
              'height': rows, 'seq': seq, 'full': True, 'bytes': base64.b64encode(b'normal SSH viewport').decode()}), flush=True)
    frame()
    for line in sys.stdin:
        resize = json.loads(line)
        with (root / 'herdr-calls.jsonl').open('a') as file:
            file.write(json.dumps(['resize', resize]) + '\n')
        cols, rows = resize['cols'], resize['rows']
        seq += 1
        frame()
else:
    sys.exit(2)
