import io
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor

from bridge.gateway import Machine, MachineRegistry, PeerPool, GatewayWorker, ssh_arguments
from bridge.image_transfers import ImageTransfers
from bridge.local_api import LocalApi
from bridge.session_actions import SessionActions
from bridge.protocol import BridgeRejected
from bridge_test_support import FakeHerdr, worker_config


class ApiPeer:
    def __init__(self, machine, lane, herdr, connector):
        self.machine, self.lane = machine, lane
        self.api = LocalApi(herdr.socket_path,'peer')
        self.closed = threading.Event(); self.busy = False
        self.hello = {'generation':self.api.generation(),'capabilities':{'input':True,'observe':True,'viewport':True}}
        self.connector=connector
        self.images=ImageTransfers(self.api,herdr.root/'images')
    def request(self, row, on_event=None, timeout=6):
        if row['op'].startswith('image.'):
            return self.images.operation(row['op'],row['route'],row['payload'])
        if row['op']=='catalog':
            result=self.api.catalog()
            result.update(inputEnabled=True,terminalInputEnabled=True,terminalViewportEnabled=True)
            return result
        if row['op'] in ('rename','close','create'):
            return SessionActions(self.api).mutate(row['op'],row['route'],row['payload'])
        if row['op'] in ('input','send'):
            return self.api.dispatch(row['route'],row['payload'],reviewed=row['op']=='send')
        raise AssertionError('Unexpected peer operation: '+row['op'])
    def close(self):
        if not self.closed.is_set(): self.connector.retired.append(self.machine.id)
        self.closed.set(); self.images.close()


class ApiConnector:
    def __init__(self, test):
        self.test=test; self.started=[]; self.retired=[]; self.holds={}; self.failures={}
        self.closed=False; self.active=0; self.max_active=0; self.lock=threading.Lock()
    def open(self, machine, lane):
        with self.lock:
            self.active+=1; self.max_active=max(self.active,self.max_active)
        try:
            hold=self.holds.get(machine.id)
            if hold is not None:
                if not hold.wait(3): raise BridgeRejected('offline')
            if machine.id in self.failures: raise BridgeRejected(self.failures[machine.id])
            if self.closed: raise BridgeRejected('offline')
            self.started.append((machine.id,lane,machine.session))
            return ApiPeer(machine,lane,self.test.herdrs[machine.id],self)
        finally:
            with self.lock: self.active-=1
    def close(self):
        self.closed=True
        for hold in self.holds.values(): hold.set()


class GatewayTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='ag-',dir='/tmp'); self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name).resolve(); self.herdrs={}; self.machines=[]
        gateway_root=self.root/'gateway'; gateway_root.mkdir()
        self.gateway=FakeHerdr(gateway_root).__enter__(); self.addCleanup(self.gateway.__exit__)
        self.connector=ApiConnector(self)
        self.registry=MachineRegistry(str(self.gateway.cli),dict(os.environ,HERDR_SOCKET_PATH=self.gateway.socket_path))
        self.write_machines()
    def write_machines(self):
        (self.gateway.root/'machines.json').write_text(json.dumps(self.machines))
    def machine(self, number, target=None, session='default', label='Mac'):
        identifier=f'{number:032x}'
        row={'id':identifier,'label':label,'target':target or f'host-{number}',
             'session':session,'enabled':True,'selected':False}
        self.machines.append(row); self.write_machines()
        root=self.root/str(number); root.mkdir()
        self.herdrs[identifier]=FakeHerdr(root).__enter__(); self.addCleanup(self.herdrs[identifier].__exit__)
        return Machine(identifier,row['label'],row['target'],session,True)
    def worker(self, lane='input'):
        worker=GatewayWorker(worker_config(self.gateway,lane),io.BytesIO(),registry=self.registry,connector=self.connector)
        self.addCleanup(worker.close); return worker
    def route(self,machine):
        return {'machine':machine.id,'session':machine.session,'targetHash':machine.target_hash,
                'generation':LocalApi(self.herdrs[machine.id].socket_path,'peer').generation(),
                'terminal':'t1','pane':'p1'}

    def management_worker(self):
        config=worker_config(self.gateway,'input'); config['allowManagement']=True
        worker=GatewayWorker(config,io.BytesIO(),registry=self.registry,connector=self.connector)
        self.addCleanup(worker.close); return worker

    def test_management_routes_colliding_ids_only_to_captured_peer(self):
        a=self.machine(1); b=self.machine(2,session='work'); worker=self.management_worker()
        route=self.route(b)
        worker.operation({'op':'rename','route':route,'payload':{'title':'Peer B'}})
        created=worker.operation({'op':'create','route':{k:v for k,v in route.items() if k not in ('terminal','pane')},
                                  'payload':{'workspace':'w1','title':'Shell','cwd':''}})
        worker.operation({'op':'close','route':{**route,'terminal':created['created']['terminal'],
                                               'pane':created['created']['pane']},'payload':{}})
        self.assertEqual(self.herdrs[a.id].mutation_calls,[])
        self.assertEqual(self.gateway.mutation_calls,[])
        self.assertEqual([r['method'] for r in self.herdrs[b.id].mutation_calls],['pane.rename','tab.create','pane.close'])

    def test_management_revalidates_after_peer_start_and_checks_permission(self):
        node=self.machine(1); worker=self.management_worker(); route=self.route(node)
        original=self.connector.open
        def retarget(machine,lane):
            result=original(machine,lane)
            self.machines[0]['target']='replacement'; self.write_machines()
            return result
        self.connector.open=retarget
        with self.assertRaises(BridgeRejected): worker.operation({'op':'close','route':route,'payload':{}})
        self.assertEqual(self.herdrs[node.id].mutation_calls,[])
        worker.config['allowManagement']=False
        with self.assertRaises(BridgeRejected): worker.operation({'op':'rename','route':route,'payload':{'title':'Denied'}})
        self.assertEqual(self.gateway.mutation_calls,[])

    def test_bad_saved_node_does_not_block_healthy_input(self):
        a=self.machine(1); b=self.machine(2)
        self.machines[0]['target']='-oProxyCommand=bad'
        self.write_machines()
        worker=self.worker()
        worker.dispatch(self.route(b),{'text':'healthy'})
        self.assertEqual(len([r for r in self.herdrs[b.id].calls if r['method']=='pane.send_text']),1)
        with self.assertRaises(BridgeRejected): worker.dispatch(self.route(a),{'text':'blocked'})
        self.assertFalse(any(r['method'].startswith('pane.send') for r in self.herdrs[a.id].calls))

    def test_acquisition_lease_survives_registry_validation_gap(self):
        a=self.machine(1); b=self.machine(2)
        pool=PeerPool(self.connector,limit=1); self.addCleanup(pool.close)
        with pool.lease(a,'input',set()) as worker:
            with self.assertRaises(BridgeRejected) as error: pool.acquire(b,'input',set())
            self.assertEqual(error.exception.code,'busy')
            self.assertFalse(worker.closed.is_set())
        pool.acquire(b,'input',set())
        self.assertTrue(worker.closed.is_set())

    def test_local_and_peer_streams_share_sixteen_slot_limit(self):
        node=self.machine(1); worker=self.worker('streams')
        for i in range(16): worker.reserve_stream(str(i+100))
        with self.assertRaises(BridgeRejected) as error:
            worker.operation({'id':'1','op':'observe','route':self.route(node),'payload':{'mode':'preview'}})
        self.assertEqual(error.exception.code,'busy')
        self.assertEqual(self.connector.started,[])

    def test_cancel_while_peer_starts_does_not_forward_observe(self):
        node=self.machine(1); worker=self.worker('streams')
        hold=threading.Event(); self.connector.holds[node.id]=hold
        with ThreadPoolExecutor(max_workers=1) as executor:
            pending=executor.submit(worker.operation,{'id':'1','op':'observe','route':self.route(node),'payload':{'mode':'preview'}})
            deadline=time.monotonic()+1
            while self.connector.active==0 and time.monotonic()<deadline: time.sleep(.01)
            worker.operation({'id':'2','op':'cancel','payload':{'subscription':'1'}})
            hold.set()
            with self.assertRaises(BridgeRejected): pending.result(timeout=2)
        self.assertEqual(worker._stream_slots,set())

    def test_duplicate_labels_and_named_sessions_keep_distinct_workers(self):
        a=self.machine(1,'same-host'); b=self.machine(2,'same-host',session='work')
        pool=PeerPool(self.connector,limit=16); self.addCleanup(pool.close)
        self.assertIsNot(pool.acquire(a,'input',set()),pool.acquire(b,'input',set()))
        self.assertEqual(self.connector.started,[(a.id,'input','default'),(b.id,'input','work')])

    def test_retarget_disable_delete_and_session_change_never_deliver(self):
        a=self.machine(1); route=self.route(a); worker=self.worker()
        for change in [('target','replacement'),('session','other'),('enabled',False),('delete',None)]:
            original=dict(self.machines[0])
            if change[0]=='delete': self.machines=[]
            else: self.machines[0][change[0]]=change[1]
            self.write_machines()
            with self.subTest(change=change),self.assertRaises(BridgeRejected) as error:
                worker.dispatch(route,{'text':'do not redirect'})
            self.assertFalse(error.exception.dispatched)
            self.assertEqual(error.exception.code,'route_changed')
            self.machines=[original]; self.write_machines()
        self.assertFalse(any(r['method'].startswith('pane.send') for r in self.herdrs[a.id].calls))

    def test_colliding_terminal_ids_route_only_to_requested_computer(self):
        a=self.machine(1); b=self.machine(2); worker=self.worker()
        worker.dispatch(self.route(b),{'keys':['cmd+backspace','ctrl+enter']})
        self.assertFalse(any(r['method'].startswith('pane.send') for r in self.herdrs[a.id].calls))
        sends=[r for r in self.herdrs[b.id].calls if r['method'].startswith('pane.send')]
        self.assertEqual(len(sends),1)
        self.assertEqual(sends[0]['params'],{'pane_id':'p1','keys':['cmd+backspace','ctrl+enter']})

    def test_protected_full_pool_is_bounded_then_idle_lru_can_retire(self):
        nodes=[self.machine(i) for i in range(17)]
        pool=PeerPool(self.connector,limit=16); self.addCleanup(pool.close)
        for node in nodes[:16]: pool.acquire(node,'input',set())
        protected={n.id for n in nodes[:16]}
        with self.assertRaises(BridgeRejected): pool.acquire(nodes[16],'input',protected)
        self.assertEqual(self.connector.retired,[])
        pool.acquire(nodes[16],'input',protected-{nodes[0].id})
        self.assertEqual(self.connector.retired,[nodes[0].id])

    def test_gateway_and_healthy_peer_arrive_before_slow_peer(self):
        a=self.machine(1); b=self.machine(2)
        hold=threading.Event(); self.connector.holds[a.id]=hold
        worker=self.worker('discovery'); seen=[]
        worker.emit=lambda row: seen.append(row) or True
        worker.handle({'type':'request','protocol':'agentspace-bridge-v2','nonce':'b'*32,
                       'lane':'discovery','id':'1','op':'catalog','payload':{'epoch':1,'priorityMachines':[]}})
        deadline=time.monotonic()+2
        while time.monotonic()<deadline and not any(r.get('value',{}).get('machine')==b.id and r.get('value',{}).get('state')=='live' for r in seen):
            time.sleep(.01)
        self.assertTrue(any(r.get('value',{}).get('machine')=='gateway' for r in seen))
        self.assertTrue(any(r.get('value',{}).get('machine')==b.id and r.get('value',{}).get('state')=='live' for r in seen))
        self.assertFalse(any(r.get('type')=='reply' for r in seen))
        hold.set()

    def test_auth_hostkey_and_python_failures_are_per_node(self):
        nodes=[self.machine(i) for i in range(4)]
        for node,code in zip(nodes,['auth_required','host_key','setup_required']): self.connector.failures[node.id]=code
        worker=self.worker('discovery'); seen=[]; worker.emit=lambda row:seen.append(row) or True
        worker.operation({'id':'1','op':'catalog','payload':{'epoch':7,'priorityMachines':[]}})
        states={r['value']['machine']:r['value'] for r in seen if r.get('event')=='computer'}
        self.assertEqual(states[nodes[3].id]['state'],'live')
        self.assertEqual([states[n.id]['code'] for n in nodes[:3]],['auth_required','host_key','setup_required'])

    def test_machine_limit_duplicate_ids_and_targets_are_not_options(self):
        self.machine(1)
        self.machines.append(dict(self.machines[0])); self.write_machines()
        with self.assertRaises(BridgeRejected): self.registry.read()
        self.machines=[dict(self.machines[0],id=f'{i:032x}') for i in range(65)]; self.write_machines()
        with self.assertRaises(BridgeRejected): self.registry.read()
        for target in ['-oProxyCommand=evil','host\nother','host;touch bad']:
            with self.subTest(target=target),self.assertRaises(BridgeRejected):
                ssh_arguments(Machine('a'*32,'Mac',target,'default',True),'pass')
        args=ssh_arguments(Machine('a'*32,'Mac','user@alias','default',True),'fixed')
        self.assertEqual(args[-3:-1],['--','user@alias'])
        self.assertEqual(__import__('shlex').split(args[-1])[-2:],['agentspace-bootstrap','fixed'])
        self.assertIn('StrictHostKeyChecking=yes',args)

    def test_only_four_peer_initializations_can_run_concurrently(self):
        nodes=[self.machine(i) for i in range(8)]
        hold=threading.Event()
        self.connector.holds={node.id:hold for node in nodes}
        pool=PeerPool(self.connector); self.addCleanup(pool.close)
        with ThreadPoolExecutor(max_workers=8) as executor:
            futures=[executor.submit(pool.acquire,node,'discovery',set()) for node in nodes]
            deadline=time.monotonic()+2
            while time.monotonic()<deadline and self.connector.active<4: time.sleep(.01)
            self.assertEqual(self.connector.active,4)
            hold.set()
            for future in futures: future.result(timeout=3)
        self.assertEqual(self.connector.max_active,4)

    def test_changed_target_during_startup_rejected_before_peer_dispatch(self):
        node=self.machine(1); hold=threading.Event(); self.connector.holds[node.id]=hold
        worker=self.worker(); route=self.route(node)
        with ThreadPoolExecutor(max_workers=1) as executor:
            future=executor.submit(worker.dispatch,route,{'text':'old target'})
            deadline=time.monotonic()+2
            while time.monotonic()<deadline and self.connector.active==0: time.sleep(.01)
            self.machines[0]['target']='new-host'; self.write_machines(); hold.set()
            with self.assertRaises(BridgeRejected): future.result(timeout=3)
        self.assertFalse(any(r['method'].startswith('pane.send') for r in self.herdrs[node.id].calls))

    def test_peer_restart_rejects_old_generation(self):
        node=self.machine(1); worker=self.worker(); route=self.route(node)
        self.herdrs[node.id].replace_socket()
        with self.assertRaises(BridgeRejected) as error: worker.dispatch(route,{'text':'stale'})
        self.assertEqual(error.exception.code,'generation_changed')
        self.assertFalse(any(r['method'].startswith('pane.send') for r in self.herdrs[node.id].calls))


    def test_sixty_four_computers_emit_complete_catalog_without_busy(self):
        self.machines=[{'id':f'{i:032x}','label':f'Computer {i}','target':f'host-{i}',
                        'session':'default','enabled':False} for i in range(64)]
        self.write_machines()
        output=io.BytesIO()
        worker=GatewayWorker(worker_config(self.gateway,'discovery'),output,registry=self.registry,connector=self.connector)
        self.addCleanup(worker.close)
        result=worker.operation({'id':'1','op':'catalog','payload':{'epoch':1,'priorityMachines':[]}})
        self.assertTrue(result['complete'])
        deadline=time.monotonic()+2
        while len(output.getvalue().splitlines())<65 and time.monotonic()<deadline: time.sleep(.01)
        rows=[json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(len({r['value']['machine'] for r in rows if r.get('event')=='computer'}),65)

    def test_explicit_takeover_is_forwarded_only_to_the_selected_peer(self):
        node=self.machine(1); captured=[]
        original=self.connector.open
        def open_peer(machine,lane):
            peer=original(machine,lane)
            def request(row,on_event=None,timeout=6):
                captured.append((machine.id,row))
                return {'subscription':'500'}
            peer.request=request
            return peer
        self.connector.open=open_peer
        worker=GatewayWorker(worker_config(self.gateway,'streams'),io.BytesIO(),registry=self.registry,connector=self.connector)
        self.addCleanup(worker.close)
        payload={'mode':'viewport','cols':80,'rows':25,'takeover':True}
        worker.operation({'id':'1','op':'observe','route':self.route(node),'payload':payload})
        self.assertEqual([(machine,row['payload']) for machine,row in captured],[(node.id,payload)])

    def test_read_only_gateway_rejects_peer_viewport_before_startup(self):
        node=self.machine(1)
        config=worker_config(self.gateway,'streams'); config['allowInput']=False
        worker=GatewayWorker(config,io.BytesIO(),registry=self.registry,connector=self.connector)
        self.addCleanup(worker.close)
        with self.assertRaises(BridgeRejected) as error:
            worker.operation({'id':'1','op':'observe','route':self.route(node),'payload':{'mode':'viewport','cols':80,'rows':25,'takeover':True}})
        self.assertEqual(error.exception.code,'unsupported')
        self.assertEqual(self.connector.started,[])

    def test_peer_overflow_delivers_closure_without_retiring_other_peer(self):
        class BlockedOutput(io.BytesIO):
            def __init__(self): super().__init__(); self.entered=threading.Event(); self.release=threading.Event()
            def write(self,data): self.entered.set(); self.release.wait(3); return super().write(data)
        a=self.machine(1); b=self.machine(2); callbacks={}; cancelled=[]
        original=self.connector.open
        def open_peer(machine,lane):
            peer=original(machine,lane)
            def request(row,on_event=None,timeout=6):
                if row['op']=='observe': callbacks[machine.id]=on_event; return {'subscription':'500'}
                if row['op']=='cancel': cancelled.append(machine.id); return {'cancelled':True}
                raise AssertionError(row['op'])
            peer.request=request; return peer
        self.connector.open=open_peer
        output=BlockedOutput()
        worker=GatewayWorker(worker_config(self.gateway,'streams'),output,registry=self.registry,connector=self.connector)
        self.addCleanup(worker.close); self.addCleanup(output.release.set)
        for identifier,node in [('1',a),('2',b)]:
            worker.operation({'id':identifier,'op':'observe','route':self.route(node),'payload':{'mode':'preview'}})
        callbacks[a.id]({'id':'500','event':'frame','value':{'seq':0}})
        self.assertTrue(output.entered.wait(1))
        for seq in range(1,6): callbacks[a.id]({'id':'500','event':'frame','value':{'seq':seq}})
        callbacks[a.id]({'id':'500','event':'closed','value':{'reason':'ended'}})
        callbacks[b.id]({'id':'500','event':'frame','value':{'seq':0}})
        output.release.set()
        deadline=time.monotonic()+2
        while len(output.getvalue().splitlines())<6 and time.monotonic()<deadline: time.sleep(.01)
        rows=[json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(len([r for r in rows if r['id']=='1' and r['event']=='closed']),1)
        self.assertTrue(any(r['id']=='2' and r['event']=='frame' for r in rows))
        self.assertIn('2',worker._peer_streams)
        self.assertNotIn('1',worker._peer_streams)
        self.assertIn(a.id,cancelled); self.assertNotIn(b.id,cancelled)
        self.assertFalse(worker.closed.is_set())

    def test_read_only_catalog_and_resize_remain_restricted(self):
        node=self.machine(1)
        config=worker_config(self.gateway,'discovery'); config['allowInput']=False
        worker=GatewayWorker(config,io.BytesIO(),registry=self.registry,connector=self.connector)
        self.addCleanup(worker.close)
        seen=[]; worker.emit=lambda row:seen.append(row) or True
        worker.operation({'id':'1','op':'catalog','payload':{'epoch':1,'priorityMachines':[]}})
        catalog=next(r['value']['catalog'] for r in seen if r.get('value',{}).get('machine')==node.id and r['value'].get('catalog'))
        self.assertFalse(catalog['inputEnabled']); self.assertFalse(catalog['terminalViewportEnabled'])
        with self.assertRaises(BridgeRejected):
            worker.operation({'id':'2','op':'resize','payload':{'subscription':'1','cols':80,'rows':25}})

    def test_active_image_pins_peer_until_cancel_and_retarget_cleans(self):
        a=self.machine(1); b=self.machine(2); worker=self.worker('transfer')
        worker.config['allowImages']=True; worker.pool.limit=1
        route=self.route(a)
        start=worker.operation({'op':'image.begin','route':route,'payload':{'extension':'png','size':8,'sha256':'0'*64}})
        with self.assertRaises(BridgeRejected):worker.pool.acquire(b,'transfer',set())
        self.machines[0]['target']='replacement'; self.write_machines()
        with self.assertRaises(BridgeRejected):worker.operation({'op':'image.chunk','route':route,'payload':{'token':start['token'],'offset':0,'bytes':'YWJj'}})
        worker.pool.acquire(b,'transfer',set())
        self.assertEqual(list((self.herdrs[a.id].root/'images').glob('*.part')),[])
    def test_images_require_explicit_permission_and_input(self):
        worker=self.worker('transfer'); route={**self.route(self.machine(1))}
        for image,input_ in [(False,True),(True,False)]:
            worker.config.update(allowImages=image,allowInput=input_)
            with self.assertRaises(BridgeRejected):worker.operation({'op':'image.begin','route':route,'payload':{'extension':'png','size':8,'sha256':'0'*64}})

    def test_local_and_peer_images_share_worker_quota(self):
        import hashlib
        node=self.machine(1); worker=self.worker('transfer'); worker.config['allowImages']=True
        worker.images=ImageTransfers(worker.api,self.root/'local-images')
        payload={'extension':'png','size':8,'sha256':'0'*64}
        for _ in range(4):worker.operation({'op':'image.begin','route':self.route(node),'payload':payload})
        route={'machine':'gateway','session':'default','targetHash':hashlib.sha256(b'gateway').hexdigest(),'generation':worker.api.generation(),'terminal':'t1','pane':'p1'}
        with self.assertRaises(BridgeRejected):worker.operation({'op':'image.begin','route':route,'payload':payload})

if __name__=='__main__': unittest.main()
