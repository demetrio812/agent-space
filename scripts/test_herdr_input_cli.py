"""Optional integration test: real Herdr CLI against a disposable fake server, never live sessions."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import socket
import tempfile
import threading
import unittest

spec = importlib.util.spec_from_file_location('gate', Path(__file__).with_name('catalog-gate.py'))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

@unittest.skipUnless(os.environ.get('HERDR_TEST_BINARY'), 'Set HERDR_TEST_BINARY to run CLI integration')
class HerdrInputCliTest(unittest.TestCase):
    def test_gate_preserves_text_and_sends_enter_exactly_once(self):
        with tempfile.TemporaryDirectory() as directory:
            path = directory + '/fake.sock'
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            listener.bind(path); listener.listen(); listener.settimeout(.2)
            stopped = threading.Event(); requests = []; errors = []
            def server():
                while not stopped.is_set():
                    try: client, _ = listener.accept()
                    except socket.timeout: continue
                    except OSError: break
                    try:
                        with client:
                            client.settimeout(3)
                            stream = client.makefile('rwb')
                            while line := stream.readline():
                                request = json.loads(line); requests.append(request)
                                method = request['method']
                                if method == 'ping':
                                    result = {'type':'pong','version':'0.0.0','protocol':22}
                                elif method == 'agent.list':
                                    result = {'type':'agent_list','agents':[{'terminal_id':'t1','pane_id':'p1','workspace_id':'w1','tab_id':'tab1','agent_status':'idle','focused':False,'revision':0}]}
                                elif method == 'pane.send_input': result = {'type':'ok'}
                                else: raise AssertionError('Unexpected method: '+method)
                                stream.write((json.dumps({'id':request['id'],'result':result})+'\n').encode()); stream.flush()
                    except Exception as error: errors.append(error)
            worker = threading.Thread(target=server, daemon=True); worker.start()
            try:
                text = '--literal café; $(echo harmless)\nsecond line'
                result = gate.send_text(os.environ['HERDR_TEST_BINARY'],path,gate.server_identity(path),'t1',base64.b64encode(text.encode()).decode(),True)
                self.assertEqual({'sent':True},result)
                writes = [r for r in requests if r['method']=='pane.send_input']
                self.assertEqual(1,len(writes))
                self.assertEqual({'pane_id':'p1','text':text,'keys':['Enter']},writes[0]['params'])
                self.assertFalse(errors)
            finally:
                stopped.set(); listener.close(); worker.join(4)

if __name__ == '__main__': unittest.main()
