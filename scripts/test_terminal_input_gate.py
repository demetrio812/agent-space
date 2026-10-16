import base64
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
spec=importlib.util.spec_from_file_location('keyboard_gate',Path(__file__).with_name('catalog-gate.py'))
gate=importlib.util.module_from_spec(spec);spec.loader.exec_module(gate)
class TerminalInputTest(unittest.TestCase):
 def fixture(self,root):
  socket=Path(root,'socket');socket.touch();binary=Path(root,'herdr')
  binary.write_text('''#!/usr/bin/env python3
import json,sys,os
from pathlib import Path
if sys.argv[1:3]==['agent','list']:
 print(json.dumps({'result':{'agents':[{'terminal_id':'t1','pane_id':'p1'}]}}))
elif sys.argv[1:3] in (['pane','send-text'],['pane','send-keys']):
 Path(os.environ['HERDR_SOCKET_PATH']+'.received').write_text(json.dumps(sys.argv[1:],ensure_ascii=False))
else:raise SystemExit(1)
''');binary.chmod(0o700)
  return str(binary),str(socket),gate.server_identity(socket)
 def encode(self,payload):return base64.b64encode(json.dumps(payload,ensure_ascii=False).encode()).decode()
 def test_typing_and_keys_preserve_spaces_and_never_append_enter(self):
  with tempfile.TemporaryDirectory() as root:
   binary,socket,identity=self.fixture(root)
   for value,args in [({'text':' café '},['pane','send-text','p1',' café ']),({'keys':['up','ctrl+enter','shift+tab','cmd+backspace','shift+cmd+left']},['pane','send-keys','p1','up','ctrl+enter','shift+tab','cmd+backspace','shift+cmd+left'])]:
    self.assertEqual({'sent':True},gate.terminal_input(binary,socket,identity,'t1',self.encode(value),True))
    self.assertEqual(args,json.loads(Path(socket+'.received').read_text()))
 def test_read_only_key_cannot_type_or_send_control_keys(self):
  with tempfile.TemporaryDirectory() as root:
   binary,socket,identity=self.fixture(root)
   with self.assertRaises(ValueError):gate.terminal_input(binary,socket,identity,'t1',self.encode({'keys':['ctrl+enter']}))
   self.assertFalse(Path(socket+'.received').exists())
 def test_malformed_input_is_rejected_before_any_command(self):
  with tempfile.TemporaryDirectory() as root:
   binary,socket,identity=self.fixture(root)
   for payload in [{'text':'\x1b[A'},{'text':'first\nsecond'},{'text':'é'*8193},{'keys':['ctrl+enter; injected']},{'keys':['ctrl+ctrl+c']},{'keys':['up']*33},{'text':'x','keys':['enter']},{}]:
    with self.subTest(payload=str(payload)[:40]),self.assertRaises(ValueError):gate.terminal_input(binary,socket,identity,'t1',self.encode(payload),True)
   self.assertFalse(Path(socket+'.received').exists())
 def test_stale_server_or_missing_terminal_never_dispatches(self):
  with tempfile.TemporaryDirectory() as root:
   binary,socket,identity=self.fixture(root)
   for server,terminal in [('a'*64,'t1'),(identity,'missing')]:
    with self.assertRaises(RuntimeError):gate.terminal_input(binary,socket,server,terminal,self.encode({'keys':['enter']}),True)
   self.assertFalse(Path(socket+'.received').exists())
if __name__=='__main__':unittest.main()
