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
    def test_catalog_is_bounded_and_does_not_read_file_contents(self):
        for i in range(140): self.put(f'{i:03}.md',str(i))
        page=self.reader.listing(self.route)
        self.assertEqual(len(page['files']),128); self.assertTrue(page['limited'])
        self.assertNotIn('text',page['files'][0])

if __name__=='__main__': unittest.main()
