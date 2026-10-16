import base64
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('gate', Path(__file__).with_name('catalog-gate.py'))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

class InputGateTest(unittest.TestCase):
    def fixture(self, directory):
        socket = Path(directory, 'socket'); socket.touch()
        binary = Path(directory, 'herdr')
        binary.write_text('''#!/usr/bin/env python3
import json,sys,os
from pathlib import Path
if sys.argv[1:3] == ['agent','list']:
 print(json.dumps({'result':{'agents':[{'terminal_id':'t1','pane_id':'p1'}]}}))
elif sys.argv[1:3] == ['pane','run']:
 Path(os.environ['HERDR_SOCKET_PATH']+'.received').write_text(json.dumps(sys.argv[1:]))
else:
 raise SystemExit(1)
''')
        binary.chmod(0o700)
        return str(binary), str(socket), gate.server_identity(socket)

    def test_explicit_permission_required_and_default_gate_is_read_only(self):
        with tempfile.TemporaryDirectory() as d:
            binary, socket, identity = self.fixture(d)
            with self.assertRaises(ValueError):
                gate.send_text(binary, socket, identity, 't1', 'aGVsbG8=')
            self.assertFalse(Path(socket+'.received').exists())

    def test_literal_unicode_multiline_and_enter_are_sent_once(self):
        with tempfile.TemporaryDirectory() as d:
            binary, socket, identity = self.fixture(d)
            text = '--hello; $(touch nothing)\ncafé'
            encoded = base64.b64encode(text.encode()).decode()
            self.assertEqual({'sent':True},gate.send_text(binary,socket,identity,'t1',encoded,True))
            self.assertEqual(['pane','run','p1',text],json.loads(Path(socket+'.received').read_text()))

    def test_bad_payload_stale_server_and_missing_terminal_never_send(self):
        with tempfile.TemporaryDirectory() as d:
            binary, socket, identity = self.fixture(d)
            for text in ['', ' ', 'a\x1bb', 'a\rb', 'a\x00b', 'é'*8193]:
                with self.subTest(text=text[:10]), self.assertRaises(ValueError):
                    gate.send_text(binary,socket,identity,'t1',base64.b64encode(text.encode()).decode(),True)
            for server, terminal in [('a'*64, 't1'), (identity,'missing')]:
                with self.assertRaises(RuntimeError):
                    gate.send_text(binary,socket,server,terminal,'aGVsbG8=',True)
            self.assertFalse(Path(socket+'.received').exists())

    def test_no_retry_after_uncertain_send_failure(self):
        with tempfile.TemporaryDirectory() as d:
            binary, socket, identity = self.fixture(d)
            original = gate.bounded_catalog
            sends = []
            def bounded(binary, env, arguments=('agent','list'), deadline=None):
                if arguments[0] == 'pane':
                    sends.append(arguments)
                    raise RuntimeError('lost acknowledgement')
                return original(binary,env,arguments,deadline)
            with patch.object(gate,'bounded_catalog',side_effect=bounded), self.assertRaises(RuntimeError):
                gate.send_text(binary,socket,identity,'t1','aGVsbG8=',True)
            self.assertEqual(1,len(sends))

    def test_send_allowlist_rejects_injected_command(self):
        identity = 'a'*64
        self.assertEqual(('send',identity,'t1','aGVsbG8='),gate.parse_command(f'agentspace-send-v1 {identity} t1 aGVsbG8='))
        for suffix in [';id',' extra','\n','$(id)']:
            with self.assertRaises(ValueError):gate.parse_command(f'agentspace-send-v1 {identity} t1 aGVsbG8={suffix}')

if __name__ == '__main__':unittest.main()
