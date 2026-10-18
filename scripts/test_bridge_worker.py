import io
import json
import os
from pathlib import Path
import socket
import tempfile
import threading
import unittest

from bridge.protocol import read_record, DeliveryUncertain, BridgeRejected
from bridge.local_api import LocalApi, server_generation
from bridge_test_support import FakeHerdr, WorkerHarness


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ab-', dir='/tmp')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_shell_remains_discoverable_and_writable_after_agent_exits(self):
        with FakeHerdr(self.root) as h:
            api=LocalApi(h.socket_path,'peer')
            h.agents[0].update(agent='claude', agent_status='working')
            before=api.catalog(); generation=before['serverIdentity']
            pane={**h.agents[0], 'agent':None, 'agent_status':None, 'label':'My shell'}
            h.extra_panes=[pane]; h.agents=[]
            after=api.catalog()['catalog']['result']['agents']
            self.assertEqual([a['terminal_id'] for a in after], ['t1'])
            self.assertEqual(after[0]['title'], 'My shell')
            self.assertIsNone(after[0]['agent'])
            self.assertEqual(after[0]['terminal_id'], before['catalog']['result']['agents'][0]['terminal_id'])
            route={'generation':generation,'terminal':'t1','pane':'p1'}
            api.dispatch(route,{'text':'claude'})
            self.assertEqual(len([r for r in h.calls if r['method']=='pane.send_text']),1)
            h.extra_panes=[]
            self.assertEqual(api.catalog()['catalog']['result']['agents'], [])
            with self.assertRaises(BridgeRejected): api.dispatch(route,{'text':'closed'})

    def test_ambiguous_shell_identity_never_receives_input(self):
        with FakeHerdr(self.root) as h:
            api=LocalApi(h.socket_path,'peer'); generation=api.generation()
            h.extra_panes=[dict(h.agents[0]), {**h.agents[0], 'pane_id':'other'}]
            with self.assertRaises(BridgeRejected):
                api.dispatch({'generation':generation,'terminal':'t1','pane':'p1'}, {'text':'ambiguous'})
            self.assertFalse(any(r['method'].startswith('pane.send') for r in h.calls))

    def test_empty_panes_do_not_resurrect_stale_agents(self):
        with FakeHerdr(self.root) as h:
            api=LocalApi(h.socket_path,'peer'); original=api.call
            def call(method,params,deadline,before_send=None):
                if method=='pane.list': return {'result':{'panes':[]}}
                return original(method,params,deadline,before_send)
            api.call=call
            self.assertEqual(api.catalog()['catalog']['result']['agents'], [])
            with self.assertRaises(BridgeRejected):
                api.dispatch({'generation':api.generation(),'terminal':'t1','pane':'p1'}, {'text':'closed'})
            self.assertFalse(any(r['method'].startswith('pane.send') for r in h.calls))

    def test_malformed_pane_list_rejects_input(self):
        with FakeHerdr(self.root) as h:
            api=LocalApi(h.socket_path,'peer'); original=api.call
            for panes in [None, {}, [{}]*4097]:
                def call(method,params,deadline,before_send=None):
                    if method=='pane.list': return {'result':{'panes':panes}}
                    return original(method,params,deadline,before_send)
                api.call=call
                with self.subTest(panes=type(panes).__name__), self.assertRaises(BridgeRejected):
                    api.dispatch({'generation':api.generation(),'terminal':'t1','pane':'p1'}, {'text':'invalid'})
            self.assertFalse(any(r['method'].startswith('pane.send') for r in h.calls))

    def test_fragmented_unicode_and_embedded_newline_are_literal(self):
        row={'text':'café\n世界'}
        raw=(json.dumps(row,ensure_ascii=False)+'\n').encode()
        left,right=socket.socketpair()
        self.addCleanup(left.close); self.addCleanup(right.close)
        thread=threading.Thread(target=lambda:[left.sendall(bytes([b])) for b in raw]); thread.start()
        with right.makefile('rb') as reader: self.assertEqual(read_record(reader),row)
        thread.join()

    def test_oversized_unterminated_duplicate_fields_and_bad_utf8_rejected(self):
        for raw in [b'x'*33,b'{"id":"1","id":"2"}\n',b'{"x":"\xff"}\n']:
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                read_record(io.BytesIO(raw),limit=32)

    def test_direct_api_literal_keys_and_reviewed_input(self):
        with FakeHerdr(self.root) as h:
            api=LocalApi(h.socket_path,'peer')
            c=api.catalog()
            route={'generation':c['serverIdentity'],'terminal':'t1','pane':'p1'}
            self.assertEqual(api.dispatch(route,{'text':' café; $(harmless) '}),{'sent':True})
            api.dispatch(route,{'keys':['up','ctrl+enter','cmd+backspace']})
            api.dispatch(route,{'text':'line one\nline two'},reviewed=True)
            sends=[r for r in h.calls if r['method'].startswith('pane.send')]
            self.assertEqual([(r['method'],r['params']) for r in sends],[
                ('pane.send_text',{'pane_id':'p1','text':' café; $(harmless) '}),
                ('pane.send_keys',{'pane_id':'p1','keys':['up','ctrl+enter','cmd+backspace']}),
                ('pane.send_input',{'pane_id':'p1','text':'line one\nline two','keys':['Enter']})])
            self.assertFalse((self.root/'cli-calls').exists())

    def test_image_path_uses_paste_input_without_enter(self):
        with FakeHerdr(self.root) as h:
            api=LocalApi(h.socket_path,'peer'); c=api.catalog()
            route={'generation':c['serverIdentity'],'terminal':'t1','pane':'p1'}
            api.dispatch(route,{'paste':"/cache/a'post with space.png"})
            sends=[r for r in h.calls if r['method'].startswith('pane.send')]
            self.assertEqual([(r['method'],r['params']) for r in sends],[
                ('pane.send_input',{'pane_id':'p1','text':"/cache/a'post with space.png",'keys':[]})])
            for value in [{'paste':'bad\x1b'}, {'paste':'bad\r'}, {'paste':'x'*16385}, {'paste':'x','keys':['enter']}]:
                with self.subTest(value=value), self.assertRaises(BridgeRejected): api.dispatch(route,value)
            self.assertEqual(len([r for r in h.calls if r['method'].startswith('pane.send')]),1)

    def test_multiline_paste_preserves_text_and_never_appends_enter(self):
        with FakeHerdr(self.root) as h:
            api=LocalApi(h.socket_path,'peer'); c=api.catalog()
            route={'generation':c['serverIdentity'],'terminal':'t1','pane':'p1'}
            text='  first\n\tsecond café\n'
            api.dispatch(route,{'paste':text})
            sends=[r for r in h.calls if r['method'].startswith('pane.send')]
            self.assertEqual([(r['method'],r['params']) for r in sends],[
                ('pane.send_input',{'pane_id':'p1','text':text,'keys':[]})])

    def test_missing_ack_uncertain_and_one_delivery(self):
        with FakeHerdr(self.root) as h:
            api=LocalApi(h.socket_path,'peer'); c=api.catalog()
            h.lose_next_input_ack()
            with self.assertRaises(DeliveryUncertain):
                api.dispatch({'generation':c['serverIdentity'],'terminal':'t1','pane':'p1'}, {'keys':['cmd+backspace']})
            self.assertEqual(len([r for r in h.calls if r['method']=='pane.send_keys']),1)

    def test_replaced_generation_or_pane_rejects_before_delivery(self):
        with FakeHerdr(self.root) as h:
            api=LocalApi(h.socket_path,'peer'); c=api.catalog()
            route={'generation':c['serverIdentity'],'terminal':'t1','pane':'wrong'}
            with self.assertRaises(BridgeRejected): api.dispatch(route,{'text':'x'})
            route['pane']='p1'; h.replace_socket()
            with self.assertRaises(BridgeRejected): api.dispatch(route,{'text':'x'})
            self.assertFalse(any(r['method'].startswith('pane.send') for r in h.calls))

    def test_deeply_malformed_ack_is_uncertain_after_dispatch(self):
        with FakeHerdr(self.root) as h:
            api=LocalApi(h.socket_path,'peer'); c=api.catalog()
            h.input_reply=b'{"result":'+b'['*20000+b'0'+b']'*20000+b'}\n'
            with self.assertRaises(DeliveryUncertain):
                api.dispatch({'generation':c['serverIdentity'],'terminal':'t1','pane':'p1'},{'text':'one attempt'})
            self.assertEqual(len([r for r in h.calls if r['method']=='pane.send_text']),1)

    def test_worker_lane_deduplication_and_input_opt_out(self):
        with WorkerHarness(self.root,'discovery') as h:
            result=h.request('input',{'text':'not allowed'})
            self.assertFalse(result['ok']); self.assertFalse(result['error']['dispatched'])
            self.assertFalse(any(r['method'].startswith('pane.send') for r in h.herdr.calls))

    def test_duplicate_request_id_cannot_deliver_input_twice(self):
        with WorkerHarness(self.root,'input') as h:
            first=h.request('input',{'text':'only once'})
            self.assertTrue(first['ok'])
            h.counter=0
            second=h.request('input',{'text':'only once'})
            self.assertFalse(second['ok'])
            self.assertEqual(len([r for r in h.herdr.calls if r['method']=='pane.send_text']),1)

    def test_modifiers_controls_and_size_are_checked_before_delivery(self):
        with FakeHerdr(self.root) as h:
            api=LocalApi(h.socket_path,'peer'); generation=api.catalog()['serverIdentity']
            route={'generation':generation,'terminal':'t1','pane':'p1'}
            for value in [{'text':'bad\x1b'}, {'text':'line\n'}, {'text':'x'*16385},
                          {'keys':['ctrl+ctrl+c']},{'keys':['cmd+backspace;bad']},
                          {'keys':['up']*33}, {'text':'x','keys':['enter']}]:
                with self.subTest(value=value), self.assertRaises(BridgeRejected): api.dispatch(route,value)
            self.assertFalse(any(r['method'].startswith('pane.send') for r in h.calls))

    def test_viewport_resize_and_preview_cannot_take_over(self):
        with WorkerHarness(self.root,'streams') as h:
            result=h.request('observe',{'mode':'viewport','cols':90,'rows':30})
            self.assertTrue(result['ok'])
            subscription=result['result']['subscription']
            h.wait_frame(subscription)
            resized=h.request('resize',{'subscription':subscription,'cols':80,'rows':25})
            self.assertTrue(resized['ok'])
            bad=h.request('resize',{'subscription':subscription,'cols':True,'rows':25})
            self.assertFalse(bad['ok'])
            h.request('cancel',{'subscription':subscription})
            preview=h.request('observe',{'mode':'preview','cols':90,'rows':30})
            h.wait_frame(preview['result']['subscription'])
            rejected=h.request('resize',{'subscription':preview['result']['subscription'],'cols':80,'rows':25})
            self.assertFalse(rejected['ok'])
            calls=[json.loads(line) for line in (self.root/'cli-calls').read_text().splitlines()]
            self.assertFalse(any('--takeover' in call for call in calls))

    def test_attached_scroll_writes_fixed_control_only_to_live_viewport(self):
        from types import SimpleNamespace
        from bridge.worker import LocalWorker
        from bridge_test_support import worker_config
        with FakeHerdr(self.root) as h:
            worker=LocalWorker(worker_config(h,'streams'),io.BytesIO())
            self.addCleanup(worker.close)
            pipe=io.BytesIO()
            worker.streams['7']={'mode':'viewport','process':SimpleNamespace(stdin=pipe,poll=lambda:None)}
            self.addCleanup(worker.streams.clear)
            result=worker.operation({'op':'scroll','payload':{'subscription':'7','steps':6,'direction':'up'}})
            self.assertEqual(result,{'scrolled':True})
            self.assertEqual([json.loads(line) for line in pipe.getvalue().splitlines()],[{'type':'terminal.scroll','direction':'up','lines':3,'source':'wheel'}]*6)
            before=pipe.getvalue()
            for bad in [True,0,-1,41,'6']:
                with self.subTest(bad=bad),self.assertRaises(BridgeRejected):
                    worker.operation({'op':'scroll','payload':{'subscription':'7','steps':bad,'direction':'up'}})
            worker.streams['7']['mode']='preview'
            with self.assertRaises(BridgeRejected):
                worker.operation({'op':'scroll','payload':{'subscription':'7','steps':1,'direction':'down'}})
            worker.streams['7']['mode']='viewport';worker.config['allowInput']=False
            with self.assertRaises(BridgeRejected):
                worker.operation({'op':'scroll','payload':{'subscription':'7','steps':1,'direction':'down'}})
            self.assertEqual(pipe.getvalue(),before)
            self.assertEqual(h.calls,[])

    def test_scroll_batch_preserves_wheel_ticks_for_application_mouse_reporting(self):
        from types import SimpleNamespace
        from bridge.worker import LocalWorker
        from bridge_test_support import worker_config
        with FakeHerdr(self.root) as h:
            worker=LocalWorker(worker_config(h,'streams'),io.BytesIO());self.addCleanup(worker.close)
            pipe=io.BytesIO();worker.streams['7']={'mode':'viewport','cols':90,'rows':30,'process':SimpleNamespace(stdin=pipe,poll=lambda:None)}
            self.addCleanup(worker.streams.clear)
            self.assertEqual(worker.operation({'op':'scroll','payload':{'subscription':'7','steps':6,'direction':'up'}}),{'scrolled':True})
            records=[json.loads(line) for line in pipe.getvalue().splitlines()]
            self.assertEqual(records,[{'type':'terminal.scroll','direction':'up','lines':3,'source':'wheel'}]*6)

    def test_click_is_fixed_down_up_and_bounded_by_owned_viewport(self):
        from types import SimpleNamespace
        from bridge.worker import LocalWorker
        from bridge_test_support import worker_config
        with FakeHerdr(self.root) as h:
            worker=LocalWorker(worker_config(h,'streams'),io.BytesIO());self.addCleanup(worker.close)
            pipe=io.BytesIO();worker.streams['7']={'mode':'viewport','cols':90,'rows':30,'process':SimpleNamespace(stdin=pipe,poll=lambda:None)}
            self.addCleanup(worker.streams.clear)
            self.assertEqual(worker.operation({'op':'click','payload':{'subscription':'7','column':12,'row':25}}),{'sent':True})
            self.assertEqual([json.loads(line) for line in pipe.getvalue().splitlines()],[
                {'type':'terminal.mouse','action':'down','button':'left','column':12,'row':25},
                {'type':'terminal.mouse','action':'up','button':'left','column':12,'row':25}])
            before=pipe.getvalue()
            for col,row in [(True,1),(90,1),(1,30),(-1,1)]:
                with self.subTest(col=col,row=row),self.assertRaises(BridgeRejected):
                    worker.operation({'op':'click','payload':{'subscription':'7','column':col,'row':row}})
            worker.config['allowInput']=False
            with self.assertRaises(BridgeRejected):worker.operation({'op':'click','payload':{'subscription':'7','column':1,'row':1}})
            self.assertEqual(pipe.getvalue(),before)

    def test_worker_input_opt_out_rejects_before_api(self):
        from bridge.worker import LocalWorker
        from bridge_test_support import worker_config
        with FakeHerdr(self.root) as h:
            config=worker_config(h,'input'); config['allowInput']=False
            worker=LocalWorker(config,io.BytesIO())
            self.addCleanup(worker.close)
            with self.assertRaises(BridgeRejected):
                worker.operation({'op':'input','payload':{'text':'x'},'route':{}})
            self.assertEqual(h.calls,[])

    def test_cancel_during_membership_check_cannot_start_observer(self):
        from bridge.worker import LocalWorker
        from bridge_test_support import worker_config
        with FakeHerdr(self.root) as h:
            worker=LocalWorker(worker_config(h,'streams'),io.BytesIO()); self.addCleanup(worker.close)
            route={'generation':worker.api.generation(),'terminal':'t1','pane':'p1'}
            entered=threading.Event(); released=threading.Event()
            member=worker.api.member
            def delayed(value):
                entered.set(); released.wait(2); return member(value)
            worker.api.member=delayed
            errors=[]
            def observe():
                try: worker.operation({'id':'1','op':'observe','route':route,'payload':{'mode':'viewport','cols':80,'rows':25}})
                except BridgeRejected as error: errors.append(error)
            task=threading.Thread(target=observe); task.start()
            self.assertTrue(entered.wait(1))
            worker.operation({'id':'2','op':'cancel','payload':{'subscription':'1'}})
            released.set(); task.join(2)
            self.assertFalse(task.is_alive())
            self.assertEqual(len(errors),1)
            self.assertEqual(worker.streams,{})
            calls=[json.loads(line) for line in (self.root/'cli-calls').read_text().splitlines()]
            self.assertFalse(any('observe' in call or 'control' in call for call in calls))

    def test_older_herdr_has_no_advertised_input_or_stream_capability(self):
        from bridge.worker import LocalWorker
        from bridge_test_support import worker_config
        with FakeHerdr(self.root) as h:
            (self.root/'older-herdr').touch()
            worker=LocalWorker(worker_config(h,'discovery'),io.BytesIO()); self.addCleanup(worker.close)
            hello=worker.hello()
            self.assertFalse(hello['capabilities']['input'])
            self.assertFalse(hello['capabilities']['observe'])
            with self.assertRaises(BridgeRejected) as error: worker.operation({'op':'catalog','payload':{}})
            self.assertEqual(error.exception.code,'unsupported')

    def test_standard_cargo_and_ssh_path_herdr_discovery_is_preserved(self):
        from unittest.mock import patch
        from bridge.worker import discover_config
        for folder in ['.cargo/bin','custom/bin']:
            binary=self.root/folder/'herdr'; binary.parent.mkdir(parents=True,exist_ok=True)
            binary.write_text('#!/bin/sh\nexit 0\n'); binary.chmod(0o700)
            with patch.dict(os.environ,HOME=str(self.root),PATH=str(binary.parent)):
                result=discover_config({'role':'local','lane':'discovery','generationStyle':'peer'})
                self.assertEqual(result['herdr'],str(binary))
            binary.unlink()

    def test_eof_reaps_term_ignoring_observer_not_herdr(self):
        (self.root/'ignore-term').touch()
        with WorkerHarness(self.root,'streams') as h:
            result=h.request('observe',{'mode':'preview','cols':90,'rows':30})
            self.assertTrue(result['ok'])
            pids=h.owned_pids[:]
            h.close_stdin(); h.wait_closed(4)
            for pid in pids:
                with self.assertRaises(ProcessLookupError): os.kill(pid,0)
            self.assertEqual(LocalApi(h.herdr.socket_path,'peer').catalog()['catalog']['result']['agents'][0]['terminal_id'],'t1')

    def test_gateway_styles_preserve_legacy_generation(self):
        with FakeHerdr(self.root) as h:
            import hashlib
            p=Path(h.socket_path); s=p.stat()
            if hasattr(s,'st_birthtime'):
                expected=hashlib.sha256(f'{p.resolve()}:{s.st_dev}:{s.st_ino}:{s.st_birthtime}'.encode()).hexdigest()
                self.assertEqual(server_generation(h.socket_path,'ssh'),expected)
                # This fixture is under /tmp, the native Foundation alias.
                native=hashlib.sha256(f'{p}:{s.st_dev}:{s.st_ino}:{int(s.st_birthtime)}'.encode()).hexdigest()
                self.assertEqual(server_generation(h.socket_path,'native'),native)


if __name__=='__main__': unittest.main()

class SlowOutputTests(unittest.TestCase):
    def test_terminal_closure_survives_full_frame_queue_and_other_stream(self):
        from bridge.worker import LocalWorker
        from bridge_test_support import worker_config
        class BlockedOutput(io.BytesIO):
            def __init__(self): super().__init__(); self.entered=threading.Event(); self.release=threading.Event()
            def write(self,data): self.entered.set(); self.release.wait(3); return super().write(data)
        with tempfile.TemporaryDirectory(prefix='aq-',dir='/tmp') as root:
            with FakeHerdr(root) as h:
                output=BlockedOutput(); worker=LocalWorker(worker_config(h,'streams'),output)
                self.addCleanup(worker.close); self.addCleanup(output.release.set)
                worker.emit({'type':'event','id':'1','event':'frame','value':{'seq':0}})
                self.assertTrue(output.entered.wait(1))
                for seq in range(1,4): self.assertTrue(worker.emit({'type':'event','id':'1','event':'frame','value':{'seq':seq}}))
                self.assertFalse(worker.emit({'type':'event','id':'1','event':'frame','value':{'seq':4}}))
                self.assertTrue(worker.emit({'type':'event','id':'1','event':'closed','value':{'reason':'ended'}}))
                self.assertTrue(worker.emit({'type':'event','id':'2','event':'frame','value':{'seq':0}}))
                output.release.set()
                deadline=__import__('time').monotonic()+2
                while len(output.getvalue().splitlines())<6 and __import__('time').monotonic()<deadline: __import__('time').sleep(.01)
                rows=[json.loads(line) for line in output.getvalue().splitlines()]
                self.assertEqual(len([r for r in rows if r['id']=='1' and r['event']=='closed']),1)
                self.assertTrue(any(r['id']=='2' and r['event']=='frame' for r in rows))
                self.assertFalse(worker.closed.is_set())

class OwnedProcessCleanupTests(unittest.TestCase):
    def test_group_signal_denial_still_stops_the_owned_child(self):
        import subprocess
        import sys
        from unittest.mock import patch
        from bridge.worker import stop_process
        child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
        self.addCleanup(lambda: child.kill() if child.poll() is None else None)
        with patch('bridge.worker.os.killpg',side_effect=PermissionError('group signal denied')):
            stop_process(child)
        self.assertIsNotNone(child.poll())
        self.assertTrue(child.stdin.closed)
