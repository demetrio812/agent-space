"""Optional real-Herdr proof using an isolated server and a raw byte collector.

Never connects to a user's Herdr socket or starts an agent. The collector does
not interpret or execute its input, even when the request contains Enter.
"""
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest


@unittest.skipUnless(os.environ.get('HERDR_TEST_BINARY') and sys.platform != 'win32',
                     'Set HERDR_TEST_BINARY for isolated real-Herdr input tests')
class HerdrLargeInputTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='herdr-input-', dir='/tmp')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        config = self.root/'config'/'herdr'; config.mkdir(parents=True)
        self.socket = str(config/'herdr.sock')
        collector = self.root/'collector.py'
        collector.write_text('''import os,tty
from pathlib import Path
tty.setraw(0)
root=Path(__file__).parent
pane=os.environ['HERDR_PANE_ID']
with (root/(pane+'.received')).open('ab',buffering=0) as output:
 os.write(1,b'\\x1b[?2004hCOLLECTOR READY\\r\\n')
 while True:
  data=os.read(0,65536)
  if not data:break
  output.write(data)
''')
        launcher = self.root/'collector-shell'
        # Paths originate from Python itself and mkdtemp, never user input.
        import shlex
        launcher.write_text('#!/bin/sh\nexec '+shlex.quote(sys.executable)+' '+shlex.quote(str(collector))+'\n')
        launcher.chmod(0o700)
        (config/'config.toml').write_text('onboarding = false\n[terminal]\ndefault_shell = '+json.dumps(str(launcher))+'\nshell_mode = "non_login"\n')
        env = {k:v for k,v in os.environ.items() if not k.startswith('HERDR_')}
        env.update(XDG_CONFIG_HOME=str(self.root/'config'), XDG_STATE_HOME=str(self.root/'state'))
        self.binary = os.environ['HERDR_TEST_BINARY']
        self.log = (self.root/'server.log').open('wb'); self.addCleanup(self.log.close)
        self.server = subprocess.Popen([self.binary,'server'],env=env,stdin=subprocess.DEVNULL,
                                       stdout=self.log,stderr=self.log)
        self.addCleanup(self.stop)
        self.wait_for(lambda: Path(self.socket).exists(), 'isolated socket')
        result = self.request('workspace.create',{'label':'Disposable input collector','cwd':str(self.root),'focus':False})
        self.pane = result['result']['root_pane']['pane_id']
        self.terminal = result['result']['root_pane']['terminal_id']
        self.received = self.root/(self.pane+'.received')
        self.wait_for(lambda: self.received.exists(), 'raw byte collector')
        # Rendered READY proves Herdr has consumed the preceding mode sequence.
        self.wait_for(lambda: 'COLLECTOR READY' in json.dumps(self.request('pane.read',{'pane_id':self.pane,'source':'visible'})), 'collector mode')

    def stop(self):
        if self.server.poll() is None:
            self.server.terminate()
            try:self.server.wait(timeout=5)
            except subprocess.TimeoutExpired:self.server.kill();self.server.wait(timeout=5)

    def wait_for(self, predicate, description):
        deadline = time.monotonic()+12
        while time.monotonic() < deadline:
            if self.server.poll() is not None:
                self.fail('Isolated Herdr exited: '+(self.root/'server.log').read_text(errors='replace')[-1000:])
            if predicate():return
            time.sleep(.02)
        self.fail('Timed out waiting for '+description)

    def request(self, method, params):
        raw = json.dumps({'id':'fixture','method':method,'params':params},separators=(',',':')).encode()+b'\n'
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(12);connection.connect(self.socket);connection.sendall(raw)
            with connection.makefile('rb') as reader: response=reader.readline(2*1024*1024)
        return json.loads(response)

    def test_real_socket_accepts_256k_unicode_paste_as_one_bracketed_input(self):
        text = '🙂' * 65536  # 256 KiB UTF-8; escaped JSON is about 768 KiB.
        started = time.monotonic()
        response = self.request('pane.send_input',{'pane_id':self.pane,'text':text,'keys':[]})
        self.assertEqual(response['result']['type'],'ok')
        expected = b'\x1b[200~'+text.encode()+b'\x1b[201~'
        self.wait_for(lambda: self.received.stat().st_size >= len(expected), 'complete paste')
        self.assertEqual(self.received.read_bytes(),expected)  # No Enter, no split/wrap loss.
        print('Real Herdr paste:',len(text.encode()),'UTF-8 bytes;',round(time.monotonic()-started,3),'seconds; SHA256',hashlib.sha256(expected).hexdigest())

    def test_agent_space_worker_delivers_maximum_paste_and_send_without_loss(self):
        from bridge.local_api import LocalApi
        api=LocalApi(self.socket,'native')
        route={'generation':api.generation(),'terminal':self.terminal,'pane':self.pane}
        text='🙂'*65536
        api.dispatch(route,{'paste':text})
        api.dispatch(route,{'text':text},reviewed=True)
        wrapped=b'\x1b[200~'+text.encode()+b'\x1b[201~'
        expected=wrapped+wrapped+b'\r'
        self.wait_for(lambda:self.received.stat().st_size>=len(expected),'worker paste and Send')
        self.assertEqual(self.received.read_bytes(),expected)

    def test_real_socket_rejects_request_over_one_mib_without_delivering_input(self):
        try:
            response=self.request('pane.send_input',{'pane_id':self.pane,'text':'x'*(1024*1024+1024),'keys':[]})
        except (OSError,ValueError):response=None
        if response is not None:self.assertIn('error',response)
        time.sleep(.1)
        self.assertEqual(self.received.stat().st_size,0)


if __name__=='__main__':unittest.main()
