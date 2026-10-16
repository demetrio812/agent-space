import base64
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import subprocess
import time
import signal
import sys
import os
import unittest
spec=importlib.util.spec_from_file_location('viewport_gate',Path(__file__).with_name('catalog-gate.py'))
gate=importlib.util.module_from_spec(spec);spec.loader.exec_module(gate)
class ViewportGateTest(unittest.TestCase):
 def test_control_command_is_exact_and_bounded(self):
  identity='a'*64
  self.assertEqual(('control',identity,'t1',90,30),gate.parse_command(f'agentspace-control-v1 {identity} t1 90 30'))
  for tail in ['90 30 --takeover','0 30','512 256','90 30\n']:
   with self.assertRaises(ValueError):gate.parse_command(f'agentspace-control-v1 {identity} t1 {tail}')
 def test_cancellation_kills_an_unresponsive_controller(self):
  with tempfile.TemporaryDirectory() as root:
   socket=Path(root,'socket');socket.touch();binary=Path(root,'herdr')
   binary.write_text("#!/usr/bin/env python3\nimport json,sys,os,time,signal\nfrom pathlib import Path\nif sys.argv[1:3]==['agent','list']:\n print(json.dumps({'result':{'agents':[{'terminal_id':'t1','pane_id':'p1'}]}}))\nelse:\n signal.signal(signal.SIGTERM,signal.SIG_IGN)\n Path(os.environ['HERDR_SOCKET_PATH']+'.pid').write_text(str(os.getpid()))\n while True:time.sleep(1)\n")
   binary.chmod(0o700); identity=gate.server_identity(socket)
   wrapper=Path(root,'wrapper.py')
   wrapper.write_text(f"import importlib.util,sys\nspec=importlib.util.spec_from_file_location('gate',{str(Path(gate.__file__).resolve())!r}); gate=importlib.util.module_from_spec(spec);spec.loader.exec_module(gate)\ngate.control_viewport({str(binary)!r},{str(socket)!r},{identity!r},'t1',90,30,True,sys.stdin.buffer,sys.stdout.buffer,sys.stderr.buffer)\n")
   parent=subprocess.Popen([sys.executable,str(wrapper)],stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
   child=None
   try:
    deadline=time.monotonic()+3
    while not Path(str(socket)+'.pid').exists() and time.monotonic()<deadline:time.sleep(.01)
    child=int(Path(str(socket)+'.pid').read_text())
    time.sleep(.1)
    parent.terminate()
    parent.wait(timeout=2.5)
    with self.assertRaises(ProcessLookupError):os.kill(child,0)
   finally:
    if parent.poll() is None:parent.kill();parent.wait()
    parent.stdin.close()
    if child is not None:
     try:os.kill(child,signal.SIGKILL)
     except ProcessLookupError:pass
 def test_controller_forwards_only_bounded_resize_and_rejects_read_only_or_stale_targets(self):
  with tempfile.TemporaryDirectory() as root:
   socket=Path(root,'socket');socket.touch();binary=Path(root,'herdr')
   binary.write_text('''#!/usr/bin/env python3
import json,sys,os
from pathlib import Path
root=Path(os.environ['HERDR_SOCKET_PATH']).parent
if sys.argv[1:3]==['agent','list']:
 print(json.dumps({'result':{'agents':[{'terminal_id':'t1','pane_id':'p1'}]}}))
else:
 (root/'invoked').write_text(json.dumps(sys.argv[1:]))
 print(json.dumps({'type':'terminal.frame','encoding':'ansi','width':int(sys.argv[6]),'height':int(sys.argv[8]),'seq':0,'full':True,'bytes':'ZGVtbw=='}),flush=True)
 for line in sys.stdin:
  (root/'resize').write_text(line)
''');binary.chmod(0o700);identity=gate.server_identity(socket)
   invoke=lambda data,allow=True,server=identity,target='t1':gate.control_viewport(str(binary),str(socket),server,target,90,30,allow,io.BytesIO(data),io.BytesIO(),io.BytesIO())
   with self.assertRaises(ValueError):invoke(b'',False)
   with self.assertRaises(RuntimeError):invoke(b'',server='b'*64)
   with self.assertRaises(RuntimeError):invoke(b'',target='missing')
   self.assertFalse(Path(root,'invoked').exists())
   invoke(b'{"type":"terminal.resize","cols":80,"rows":25}\n')
   self.assertEqual(['terminal','session','control','t1','--cols','90','--rows','30'],json.loads(Path(root,'invoked').read_text()))
   self.assertEqual({'type':'terminal.resize','cols':80,'rows':25},json.loads(Path(root,'resize').read_text()))
   Path(root,'resize').unlink()
   for payload in [{'type':'terminal.input','text':'must not run'},{'type':'terminal.resize','cols':True,'rows':25},{'type':'terminal.resize','cols':512,'rows':256},{'type':'terminal.resize','cols':80,'rows':25,'extra':'x'}]:
    with self.assertRaises(RuntimeError):invoke((json.dumps(payload)+'\n').encode())
   self.assertFalse(Path(root,'resize').exists())
if __name__=='__main__':unittest.main()
