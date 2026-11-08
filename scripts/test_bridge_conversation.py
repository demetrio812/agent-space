import json
import os
from pathlib import Path
import tempfile
import unittest
import uuid

from bridge.conversation import ConversationReader
from bridge.local_api import LocalApi
from bridge.protocol import BridgeRejected, DeliveryUncertain
from bridge_test_support import FakeHerdr

SID = '11111111-1111-4111-8111-111111111111'
OTHER = '22222222-2222-4222-8222-222222222222'


def message(text, parent=None, role='assistant', **extra):
    return {'uuid': str(uuid.uuid4()), 'parentUuid': parent, 'sessionId': SID,
            'type': role, 'message': {'role': role, 'content': [{'type': 'text', 'text': text}]}, **extra}


class ConversationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='chat-', dir='/tmp')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.herdr = FakeHerdr(self.root).__enter__()
        self.addCleanup(self.herdr.__exit__)
        self.herdr.agents[0].update(agent='claude', agent_status='idle',
            agent_session={'agent': 'claude', 'kind': 'id', 'source': 'herdr:claude', 'value': SID})
        self.api = LocalApi(self.herdr.socket_path, 'peer')
        self.route = {'terminal': 't1', 'pane': 'p1', 'generation': self.api.generation()}
        self.projects = self.root / 'projects'
        self.folder = self.projects / 'project'
        self.folder.mkdir(parents=True)
        self.file = self.folder / (SID + '.jsonl')
        self.reader = ConversationReader(self.api, projects=self.projects)

    def write(self, records, tail=b''):
        self.file.write_bytes(b''.join((json.dumps(r)+'\n').encode() for r in records)+tail)

    def read(self, **payload):
        return self.reader.read(self.route, {'session': '', 'before': '', **payload})

    def test_active_parent_chain_and_streamed_blocks_exclude_rewound_answers_and_sidechains(self):
        a = message('question', role='user')
        abandoned = message('discarded answer', a['uuid'])
        b = message('part one', a['uuid'], apiBlockIndex=0)
        b['message']['id'] = 'api1'
        c = message('part two', b['uuid'], apiBlockIndex=1)
        c['message']['id'] = 'api1'
        side = message('private subagent', c['uuid'], isSidechain=True)
        self.write([a, abandoned, b, c, side], tail=b'{"unfinished":')
        result = self.read()
        self.assertEqual(result['session'], SID)
        self.assertEqual([m['text'] for m in result['messages']], ['question', 'part one\n\npart two'])
        self.assertFalse(result['hasEarlier'])
        self.assertFalse(self.herdr.calls[-1]['method'].startswith('pane.send'))

    def test_exact_uuid_never_guesses_from_cwd_and_revalidates_after_read(self):
        self.write([message('correct')])
        self.herdr.agents[0]['agent_session']['value'] = OTHER
        self.assertEqual(self.read()['status'], 'missing_transcript')
        self.assertEqual(self.read(session=SID)['status'], 'session_changed')
        self.herdr.agents[0]['agent_session']['value'] = SID
        original = self.reader._load
        def change(*args):
            result = original(*args)
            self.herdr.agents[0]['agent_session']['value'] = OTHER
            return result
        self.reader._load = change
        self.assertEqual(self.read()['status'], 'session_changed')

    def test_symlinks_and_duplicate_matches_are_not_read(self):
        private = self.root / 'private.jsonl'
        private.write_text(json.dumps(message('not a transcript grant'))+'\n')
        self.file.symlink_to(private)
        self.assertEqual(self.read()['status'], 'missing_transcript')
        self.file.unlink()
        self.write([message('one')])
        other = self.projects / 'other'
        other.mkdir()
        (other/self.file.name).write_bytes(self.file.read_bytes())
        self.assertEqual(self.read()['status'], 'ambiguous_transcript')

    def test_history_pages_and_copyable_message_text_include_offscreen_content(self):
        records=[]
        for i in range(125):
            records.append(message(f'answer {i}', records[-1]['uuid'] if records else None))
        self.write(records)
        page = self.read()
        self.assertEqual(len(page['messages']),60)
        self.assertEqual(page['messages'][-1]['text'],'answer 124')
        self.assertTrue(page['hasEarlier'])
        earlier = self.read(session=SID, before=page['before'])
        self.assertEqual(earlier['messages'][-1]['text'],'answer 64')
        self.assertEqual(earlier['messages'][0]['text'],'answer 5')
        self.assertLess(len(json.dumps(page).encode()),1024*1024)

    def test_tools_and_images_are_labels_not_unbounded_results(self):
        a=message('')
        a['message']['content']=[{'type':'text','text':'result'}, {'type':'tool_use','name':'Read','input':{'secret':'not copied'}}]
        b=message('',a['uuid'],role='user')
        b['message']['content']=[{'type':'tool_result','content':'secret result'}, {'type':'image','source':{'data':'not copied'}}]
        self.write([a,b])
        page=self.read()
        self.assertEqual(page['messages'][0]['tools'],['Read'])
        self.assertEqual(page['messages'][1]['text'],'[Image]')
        self.assertNotIn('secret',json.dumps(page))
        self.assertNotIn('not copied',json.dumps(page))

    def test_native_send_checks_binding_and_prompt_state_inside_dispatch_without_retry(self):
        self.write([message('history')])
        for status in ['working','blocked','unknown']:
            self.herdr.agents[0]['agent_status']=status
            with self.assertRaises(BridgeRejected):
                self.reader.send(self.route,{'session':SID,'text':'hello'})
        self.herdr.agents[0]['agent_status']='idle'
        with self.assertRaises(BridgeRejected): self.reader.send(self.route,{'session':OTHER,'text':'hello'})
        with self.assertRaises(BridgeRejected): self.reader.send(self.route,{'session':SID,'text':' /model'})
        self.assertFalse(any(r['method'].startswith('pane.send') for r in self.herdr.calls))
        self.reader.send(self.route,{'session':SID,'text':'hello'})
        sends=[r for r in self.herdr.calls if r['method'].startswith('pane.send')]
        self.assertEqual(len(sends),1)
        self.assertEqual(sends[0]['params']['text'],'hello')

    def test_lost_native_send_ack_is_uncertain_and_not_retried(self):
        self.herdr._lose_ack = True
        with self.assertRaises(DeliveryUncertain): self.reader.send(self.route,{'session':SID,'text':'once'})
        self.assertEqual(len([r for r in self.herdr.calls if r['method']=='pane.send_input']),1)

    def test_compaction_and_forked_history_in_the_exact_file_remain_readable(self):
        a=message('original user',role='user',sessionId=OTHER)
        b=message('original answer',a['uuid'],sessionId=OTHER)
        compact={'uuid':str(uuid.uuid4()),'parentUuid':None,'logicalParentUuid':b['uuid'],
                 'type':'system','subtype':'compact_boundary'}
        c=message('continued',compact['uuid'])
        self.write([a,b,compact,c])
        self.assertEqual([m['text'] for m in self.read()['messages']],
                         ['original user','original answer','Conversation compacted','continued'])

    def test_compaction_logical_parent_can_point_forward_into_preserved_segment(self):
        a=message('before compaction',role='user')
        b=message('old answer',a['uuid'])
        compact={'uuid':str(uuid.uuid4()),'parentUuid':None,'type':'system','subtype':'compact_boundary'}
        c=message('preserved context',compact['uuid'],role='user')
        compact['logicalParentUuid']=c['uuid']
        d=message('new answer',c['uuid'])
        self.write([a,b,compact,c,d])
        self.assertEqual([m['text'] for m in self.read()['messages']],
                         ['before compaction','old answer','Conversation compacted','preserved context','new answer'])

    def test_unrelated_system_metadata_does_not_replace_the_conversation_leaf(self):
        a=message('visible answer')
        metadata={'uuid':str(uuid.uuid4()),'type':'system','subtype':'local_status','parentUuid':None}
        self.write([a,metadata])
        self.assertEqual([m['text'] for m in self.read()['messages']],['visible answer'])

    def test_empty_reference_and_path_payloads_are_rejected(self):
        self.write([message('safe')])
        for bad in [{'session':'../../private','before':''}, {'session':'','before':'','path':str(self.file)}]:
            with self.assertRaises(BridgeRejected): self.reader.read(self.route,bad)
        self.herdr.agents[0].pop('agent_session')
        self.assertEqual(self.read()['status'],'unbound')


if __name__ == '__main__': unittest.main()
