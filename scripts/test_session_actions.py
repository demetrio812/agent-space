import io
import os
from pathlib import Path
import tempfile
import unittest
from bridge.local_api import LocalApi
from bridge.protocol import BridgeRejected, DeliveryUncertain
from bridge.session_actions import SessionActions, validate_computer_route
from bridge.worker import LocalWorker
from bridge_test_support import FakeHerdr, worker_config

class ActionsTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='as-action-',dir='/tmp'); self.addCleanup(self.temp.cleanup)
        self.herdr=FakeHerdr(self.temp.name).__enter__(); self.addCleanup(self.herdr.__exit__)
        self.api=LocalApi(self.herdr.socket_path,'peer'); self.actions=SessionActions(self.api)
        self.computer={'machine':'gateway','session':'default','targetHash':__import__('hashlib').sha256(b'gateway').hexdigest(),
                       'generation':self.api.generation()}
        self.route={**self.computer,'terminal':'t1','pane':'p1'}

    def test_rename_close_and_create_literal_shell(self):
        self.assertEqual(self.actions.mutate('rename',self.route,{'title':"Review café ' $()"}),{'applied':True})
        self.assertEqual(self.herdr.pane_labels['p1'],"Review café ' $()")
        created=self.actions.mutate('create',self.computer,{'workspace':'w1','title':'Shell','cwd':'~/project'})
        self.assertEqual(created,{'applied':True,'created':{'terminal':'new-terminal','pane':'new-pane','workspace':'w1','tab':'new-tab'}})
        params=self.herdr.mutation_calls[-1]['params']
        self.assertEqual(params,{'workspace_id':'w1','label':'Shell','cwd':str(Path.home()/'project'),'focus':False,'env':{}})
        self.assertIsNone(self.herdr.agents[-1]['agent'])
        self.actions.mutate('close',self.route,{})
        self.assertEqual([a['terminal_id'] for a in self.herdr.agents],['new-terminal'])

    def test_saved_pane_label_is_visible_after_rename_and_clear(self):
        # Herdr 0.9.3 keeps manual labels in pane.list, not agent.list.
        self.herdr.agents[0]['title']='Agent-generated title'
        self.actions.mutate('rename',self.route,{'title':'My session'})
        self.assertEqual(self.herdr.agents[0]['title'],'Agent-generated title')
        self.assertEqual(self.api.catalog()['catalog']['result']['agents'][0]['title'],'My session')
        # A new connection must discover the saved name, without a local override.
        fresh=LocalApi(self.herdr.socket_path,'peer')
        self.assertEqual(fresh.catalog()['catalog']['result']['agents'][0]['title'],'My session')
        self.actions.mutate('rename',self.route,{'title':''})
        self.assertEqual(fresh.catalog()['catalog']['result']['agents'][0]['title'],'Agent-generated title')

    def test_agent_metadata_requires_unique_exact_pane_identity(self):
        original=self.api.call
        agent=dict(self.herdr.agents[0])
        self.herdr.agents[0]['agent_session']='old-agent-session'
        for field in ('terminal_id','pane_id','workspace_id','tab_id'):
            pane={**agent,field:'other','label':'Current shell'}
            def call(method,params,deadline,before_send=None):
                if method=='pane.list': return {'result':{'panes':[pane]}}
                return original(method,params,deadline,before_send)
            self.api.call=call
            with self.subTest(field=field):
                current=self.api.catalog()['catalog']['result']['agents'][0]
                self.assertNotIn('agent_session',current)
                self.assertEqual(current[field],'other')
                self.assertEqual(current['title'],'Current shell')

    def test_older_server_without_pane_list_keeps_catalog(self):
        original=self.api.call
        def call(method,params,deadline,before_send=None):
            if method=='pane.list': raise BridgeRejected('offline')
            return original(method,params,deadline,before_send)
        self.api.call=call
        self.assertEqual(self.api.catalog()['catalog']['result']['agents'],self.herdr.agents)

    def test_invalid_payloads_routes_and_destinations_do_not_submit(self):
        bad=[('rename',self.route,{'title':'x','method':'evil'}),('rename',self.route,{'title':'\n'}),
             ('rename',self.route,{'title':'é'*65}),('close',self.route,{'x':1}),
             ('create',self.computer,{'workspace':'w1','title':'','cwd':'relative'}),
             ('create',self.computer,{'workspace':'w1','title':'','cwd':'/a\x00b'}),
             ('create',self.computer,{'workspace':'missing','title':'','cwd':''}),
             ('rename',{**self.route,'pane':'wrong'},{'title':'test'}),
             ('close',{**self.route,'generation':'a'*64},{}),
             ('create',{**self.computer,'generation':True},{'workspace':'w1','title':'','cwd':''}),
             ('create',{**self.computer,'terminal':'t1'},{'workspace':'w1','title':'','cwd':''})]
        for op,route,payload in bad:
            with self.subTest(op=op,payload=payload),self.assertRaises(BridgeRejected):
                self.actions.mutate(op,route,payload)
        self.assertEqual(self.herdr.mutation_calls,[])

    def test_cancelled_or_generation_changed_before_send(self):
        with self.assertRaises(BridgeRejected): self.actions.mutate('close',self.route,{},lambda:True)
        original=self.api.call
        def changed(method,params,deadline,before_send=None):
            if method=='pane.close': self.herdr.replace_socket()
            return original(method,params,deadline,before_send)
        self.api.call=changed
        with self.assertRaises(BridgeRejected) as error: self.actions.mutate('close',self.route,{})
        self.assertFalse(error.exception.dispatched)
        self.assertEqual(self.herdr.mutation_calls,[])

    def test_lost_ack_submits_once_and_is_uncertain(self):
        self.herdr.lose_management_ack=True
        with self.assertRaises(DeliveryUncertain):
            self.actions.mutate('create',self.computer,{'workspace':'w1','title':'','cwd':''})
        self.assertEqual(len(self.herdr.mutation_calls),1)
        self.assertEqual(len(self.herdr.agents),2)

    def test_malformed_nested_acknowledgements_are_uncertain_after_one_submission(self):
        for op,result in [('create',{'type':'tab_created','root_pane':True,'tab':{}}),
                          ('create',{'type':'tab_created','root_pane':{},'tab':True}),
                          ('rename',{'type':'pane_info','pane':True})]:
            self.herdr.management_result=result
            before=len(self.herdr.mutation_calls)
            with self.subTest(result=result),self.assertRaises(DeliveryUncertain):
                self.actions.mutate(op,self.computer if op=='create' else self.route,
                                    {'workspace':'w1','title':'','cwd':''} if op=='create' else {'title':'Renamed'})
            self.assertEqual(len(self.herdr.mutation_calls),before+1)

    def test_management_requires_explicit_capability_and_write_access(self):
        for allowed,write in [(False,True),(True,False),(True,True)]:
            config=worker_config(self.herdr,'input'); config.update(allowManagement=allowed,allowInput=write)
            worker=LocalWorker(config,io.BytesIO()); self.addCleanup(worker.close)
            if allowed and write:
                self.assertEqual(worker.operation({'op':'rename','route':self.route,'payload':{'title':'Renamed'}}),{'applied':True})
            else:
                with self.assertRaises(BridgeRejected): worker.operation({'op':'close','route':self.route,'payload':{}})
        config=worker_config(self.herdr,'discovery')
        worker=LocalWorker(config,io.BytesIO()); self.addCleanup(worker.close)
        self.assertFalse(worker.operation({'op':'catalog','payload':{}})['sessionManagementEnabled'])
        config['allowManagement']=True
        self.assertTrue(worker.operation({'op':'catalog','payload':{}})['sessionManagementEnabled'])
