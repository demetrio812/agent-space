"""Prevent terminal menus below the default observer rectangle being silently cropped."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('gate', Path(__file__).with_name('catalog-gate.py'))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

class ObserveDimensionsTest(unittest.TestCase):
    def fixture(self, directory, rect, restart=False):
        socket = Path(directory, 'socket'); socket.touch()
        binary = Path(directory, 'herdr')
        layout = {'result': {'type':'pane_layout','layout': {
            'area': {'width':300,'height':100,'x':0,'y':0}, 'focused_pane_id':'p2',
            'panes':[{'pane_id':'p2','focused':True,'rect':{'width':125,'height':100,'x':175,'y':0}},
                     {'pane_id':'p1','focused':False,'rect':dict(rect,x=0,y=0)}],
            'splits':[], 'tab_id':'tab1','workspace_id':'w1','zoomed':False}}}
        binary.write_text('''#!/usr/bin/env python3
import json,sys,os
from pathlib import Path
if sys.argv[1:] == ['agent','list']:
 print(json.dumps({'result':{'agents':[{'terminal_id':'t1','pane_id':'p1'}]}}))
elif sys.argv[1:] == ['pane','layout','--pane','p1']:
''' + (" s=Path(os.environ['HERDR_SOCKET_PATH']); s.rename(s.with_name('old')); s.touch()\n" if restart else '') +
            ' print('+repr(json.dumps(layout))+')\nelse:\n raise SystemExit(1)\n')
        binary.chmod(0o700)
        return str(binary),str(socket),gate.server_identity(socket)

    def test_observe_requests_selected_pane_native_size_instead_of_cropping_to_40_rows(self):
        with tempfile.TemporaryDirectory() as directory:
            binary,socket,identity=self.fixture(directory, {'width':175,'height':55})
            with patch.object(gate.os,'execve') as execute,patch.object(gate.os,'dup2'):
                gate.observe(binary,socket,identity,'t1')
                self.assertEqual([binary,'terminal','session','observe','t1','--cols','175','--rows','55'],execute.call_args.args[1])

    def test_untrusted_dimensions_cannot_exceed_android_frame_bounds(self):
        for rect in [{'width':0,'height':55},{'width':True,'height':55},{'width':513,'height':55},
                     {'width':175,'height':257},{'width':512,'height':256},{'width':'175','height':55}]:
            with self.subTest(rect=rect),tempfile.TemporaryDirectory() as directory:
                binary,socket,identity=self.fixture(directory,rect)
                with patch.object(gate.os,'execve') as execute,patch.object(gate.os,'dup2'):
                    gate.observe(binary,socket,identity,'t1')
                    self.assertEqual([binary,'terminal','session','observe','t1'],execute.call_args.args[1])

    def test_server_restart_during_size_lookup_is_rejected_before_observing(self):
        with tempfile.TemporaryDirectory() as directory:
            binary,socket,identity=self.fixture(directory, {'width':175,'height':55},True)
            with patch.object(gate.os,'execve') as execute,patch.object(gate.os,'dup2'):
                with self.assertRaises(RuntimeError):gate.observe(binary,socket,identity,'t1')
                execute.assert_not_called()

if __name__ == '__main__':unittest.main()
