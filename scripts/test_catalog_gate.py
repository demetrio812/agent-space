import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('gate', Path(__file__).with_name('catalog-gate.py'))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class CatalogGateTest(unittest.TestCase):
    def test_catalog_can_include_workspace_names_without_changing_terminal_ids(self):
        with tempfile.TemporaryDirectory() as directory:
            socket = Path(directory, 'socket'); socket.touch()
            binary = Path(directory, 'herdr')
            binary.write_text("#!/usr/bin/env python3\nimport sys,json\nprint(json.dumps({'result': {'workspaces':[{'workspace_id':'w1','label':'Workbench'}]} if sys.argv[1]=='workspace' else {'agents':[{'terminal_id':'t1','workspace_id':'w1'}]}}))\n")
            binary.chmod(0o700)
            payload = gate.catalog(str(binary), str(socket), include_workspaces=True)
            self.assertEqual('Workbench', payload['workspaces'][0]['label'])
            self.assertEqual('t1', payload['catalog']['result']['agents'][0]['terminal_id'])

    def test_command_allowlist_is_exact_and_never_shell_parsed(self):
        identity = 'a' * 64
        self.assertEqual(('catalog',), gate.parse_command('agentspace-catalog-v1'))
        self.assertEqual(('observe', identity, 'terminal:1/%0'), gate.parse_command(f'agentspace-observe-v1 {identity} terminal:1/%0'))
        for command in ['', 'agentspace-catalog-v1\n', 'agentspace-catalog-v1 extra',
                        f'agentspace-observe-v1 {identity} -help', f'agentspace-observe-v1 {identity} a;id',
                        f'agentspace-observe-v1 {identity} a\nb', f'agentspace-observe-v1 {identity} a\n',
                        f'agentspace-observe-v1  {identity} a', f'agentspace-observe-v1 {identity}\ta',
                        f'agentspace-observe-v1 {identity} a extra', f'agentspace-observe-v1 stale a']:
            with self.subTest(command=command), self.assertRaises(ValueError):
                gate.parse_command(command)

    def test_gate_checks_current_generation_and_terminal_before_exec(self):
        with tempfile.TemporaryDirectory() as directory:
            socket = Path(directory, 'socket')
            socket.touch()
            binary = Path(directory, 'herdr')
            binary.write_text('#!/usr/bin/env python3\nimport json\nprint(json.dumps({"result":{"agents":[{"terminal_id":"t1"}]}}))\n')
            binary.chmod(0o700)
            payload = gate.catalog(str(binary), str(socket))
            identity = payload['serverIdentity']
            with patch.object(gate.os, 'execve') as execute, patch.object(gate.os, 'dup2'):
                gate.observe(str(binary), str(socket), identity, 't1')
                self.assertEqual([str(binary), 'terminal', 'session', 'observe', 't1'], execute.call_args.args[1])
                self.assertEqual(str(socket), execute.call_args.args[2]['HERDR_SOCKET_PATH'])
            for server, terminal in [('b' * 64, 't1'), (identity, 'missing')]:
                with self.subTest(server=server, terminal=terminal), patch.object(gate.os, 'execve') as execute:
                    with self.assertRaises(RuntimeError):
                        gate.observe(str(binary), str(socket), server, terminal)
                    execute.assert_not_called()
            old = socket.with_name('old-socket')
            socket.rename(old)
            socket.touch()
            with patch.object(gate.os, 'execve') as execute, self.assertRaises(RuntimeError):
                gate.observe(str(binary), str(socket), identity, 't1')
            execute.assert_not_called()

    def test_catalog_is_bounded_and_rejects_failed_envelopes(self):
        with tempfile.TemporaryDirectory() as directory:
            socket = Path(directory, 'socket')
            socket.touch()
            binary = Path(directory, 'herdr')
            for response in [{'error':'failure', 'result':{'agents':[]}}, {'result':{'agents':'bad'}}]:
                binary.write_text('#!/usr/bin/env python3\nprint(' + repr(json.dumps(response)) + ')\n')
                binary.chmod(0o700)
                with self.assertRaises(RuntimeError):
                    gate.catalog(str(binary), str(socket))


    def test_catalog_process_bounds_stdin_output_errors_and_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            socket = Path(directory, 'socket')
            socket.touch()
            binary = Path(directory, 'herdr')
            cases = [
                "import sys; sys.stdout.write('x' * 200)",
                "import sys; sys.stderr.write('x' * 200)",
                "import sys; sys.exit(7)",
            ]
            for source in cases:
                binary.write_text('#!/usr/bin/env python3\n' + source + '\n')
                binary.chmod(0o700)
                with self.subTest(source=source), patch.object(gate, 'MAX_CATALOG_BYTES', 100), patch.object(gate, 'MAX_ERROR_BYTES', 100):
                    with self.assertRaises(RuntimeError):
                        gate.catalog(str(binary), str(socket))
            binary.write_text("#!/usr/bin/env python3\nimport sys, json\nassert sys.stdin.read() == ''\nprint(json.dumps({'result':{'agents':[]}}))\n")
            self.assertEqual([], gate.catalog(str(binary), str(socket))['catalog']['result']['agents'])

    def test_restart_during_catalog_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            socket = Path(directory, 'socket')
            socket.touch()
            binary = Path(directory, 'herdr')
            binary.write_text("#!/usr/bin/env python3\nimport os, json\nfrom pathlib import Path\ns = Path(os.environ['HERDR_SOCKET_PATH'])\ns.rename(s.with_name('old'))\ns.touch()\nprint(json.dumps({'result':{'agents':[]}}))\n")
            binary.chmod(0o700)
            with self.assertRaisesRegex(RuntimeError, 'restarted'):
                gate.catalog(str(binary), str(socket))


if __name__ == '__main__':
    unittest.main()
