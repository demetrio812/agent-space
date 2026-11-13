import os
from pathlib import Path
import tempfile
import unittest

from bridge.protocol import BridgeRejected
try:
    from bridge.project_files import ProjectFiles, validate_payload
except ImportError:
    ProjectFiles = None


class PaneApi:
    def __init__(self, cwd): self.cwd = str(cwd); self.pane = 'p1'
    def member(self, route):
        if route['pane'] != self.pane: raise BridgeRejected('terminal_missing')
        return {'foreground_cwd':self.cwd, 'cwd':'/must-not-use'}


class ProjectFileTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(ProjectFiles, 'The pane-bound project document reader is not implemented')
        self.temp = tempfile.TemporaryDirectory(dir='/tmp'); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve(); (self.root/'.git').mkdir()
        self.api = PaneApi(self.root); self.reader = ProjectFiles(self.api)
        self.route = {'terminal':'t1','pane':'p1','generation':'a'*64}
    def put(self, name, text='document'):
        path = self.root/name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text(text); return path
    def test_files_specs_and_html_are_discovered_separately(self):
        self.put('README.md','# Project'); self.put('docs/example.html','<h1>Preview</h1>')
        self.put('.kiro/specs/invites/tasks.md','- [x] done\n- [ ] next')
        self.put('.specs/auth/bugfix.md','# Bug'); self.put('secret.env','not a document')
        page=self.reader.listing(self.route)
        self.assertEqual({f['path']:f['section'] for f in page['files']},
                         {'README.md':'files','docs/example.html':'files','.kiro/specs/invites/tasks.md':'specs','.specs/auth/bugfix.md':'specs'})
        item=next(f for f in page['files'] if f['name']=='README.md')
        result=self.reader.read(self.route, {'scope':page['scope'],'file':item['id']})
        self.assertEqual(result['text'],'# Project'); self.assertEqual(result['file'],item['id'])
    def test_scope_changes_with_cwd_and_old_tokens_do_not_follow_it(self):
        self.put('README.md','root'); self.put('child/README.md','child')
        page=self.reader.listing(self.route); item=page['files'][0]
        self.api.cwd=str(self.root/'child')
        new=self.reader.listing(self.route); self.assertNotEqual(page['scope'],new['scope'])
        self.assertEqual(len({f['id'] for f in new['files']}),len(new['files']))
        with self.assertRaises(BridgeRejected): self.reader.read(self.route,{'scope':page['scope'],'file':item['id']})
    def test_scope_includes_host_and_connection_identity(self):
        self.put('README.md','same path on another computer')
        first=self.reader.listing(self.route)
        second=self.reader.listing({**self.route,'generation':'b'*64})
        self.assertNotEqual(first['scope'],second['scope'])

    def test_symlinks_and_unlisted_paths_are_never_read(self):
        outside=self.root.parent/(self.root.name+'-private.md'); outside.write_text('private'); self.addCleanup(outside.unlink)
        (self.root/'linked.md').symlink_to(outside)
        (self.root/'docs').symlink_to(self.root.parent, target_is_directory=True)
        self.assertEqual(self.reader.listing(self.route)['files'],[])
        for payload in [{'scope':'a'*64,'file':'../../private'}, {'scope':'a'*64,'file':'b'*64,'path':str(outside)}]:
            with self.assertRaises(BridgeRejected): validate_payload('files.read',payload)
        with self.assertRaises(BridgeRejected): self.reader.read(self.route,{'scope':'a'*64,'file':'b'*64})
    def test_oversized_invalid_utf8_and_nonregular_files_fail_explicitly(self):
        self.put('large.md','x'*(256*1024+1)); bad=self.put('bad.md'); bad.write_bytes(b'\xff\xfe')
        os.mkfifo(self.root/'pipe.md')
        page=self.reader.listing(self.route); self.assertEqual(len(page['files']),2)
        for item in page['files']:
            with self.assertRaises(BridgeRejected): self.reader.read(self.route,{'scope':page['scope'],'file':item['id']})
    def test_folder_change_during_read_is_rejected(self):
        self.put('README.md','old'); self.put('child/new.md','new')
        page=self.reader.listing(self.route); original=self.reader._read_file
        def change(*args):
            result=original(*args); self.api.cwd=str(self.root/'child'); return result
        self.reader._read_file=change
        with self.assertRaises(BridgeRejected): self.reader.read(self.route,{'scope':page['scope'],'file':page['files'][0]['id']})
    def test_held_root_cannot_be_redirected_by_an_intermediate_symlink(self):
        live=self.root/'live'; project=live/'project'; project.mkdir(parents=True); (project/'.git').mkdir()
        (project/'README.md').write_text('original')
        other=self.root/'other'; (other/'project').mkdir(parents=True); (other/'project'/'README.md').write_text('outside')
        self.api.cwd=str(project); page=self.reader.listing(self.route); original=self.reader._read_file
        saved=self.root/'saved'
        def redirect(*args):
            live.rename(saved); live.symlink_to(other,target_is_directory=True)
            try: return original(*args)
            finally: live.unlink(); saved.rename(live)
        self.reader._read_file=redirect
        doc=self.reader.read(self.route,{'scope':page['scope'],'file':page['files'][0]['id']})
        self.assertEqual(doc['text'],'original')

    def test_current_spec_folder_keeps_canonical_docs_in_specs_and_scratch_in_files(self):
        self.put('.kiro/specs/invites/tasks.md','- [ ] task')
        self.put('.kiro/specs/invites/scratch.md','scratch')
        self.api.cwd=str(self.root/'.kiro/specs/invites')
        page=self.reader.listing(self.route)
        self.assertEqual({f['name']:f['section'] for f in page['files']},{'tasks.md':'specs','scratch.md':'files'})

    def test_feature_budget_is_shared_across_roots_and_only_counts_directories(self):
        for i in range(40):
            self.put(f'.kiro/specs/root-{i}/tasks.md')
            self.put(f'child/.kiro/specs/local-{i}/tasks.md')
        self.api.cwd=str(self.root/'child'); page=self.reader.listing(self.route)
        self.assertEqual(len({f['feature'] for f in page['files']}),64)
        self.assertTrue(page['limited'])

    def test_backslash_filename_does_not_poison_the_ordinary_catalog(self):
        self.put('README.md','normal');self.put('bad\\name.md','odd name')
        self.assertEqual([f['name'] for f in self.reader.listing(self.route)['files']],['README.md'])

    def test_catalog_is_bounded_and_does_not_read_file_contents(self):
        for i in range(140): self.put(f'{i:03}.md',str(i))
        page=self.reader.listing(self.route)
        self.assertEqual(len(page['files']),128); self.assertTrue(page['limited'])
        self.assertNotIn('text',page['files'][0])

if __name__=='__main__': unittest.main()
