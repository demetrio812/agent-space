import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from bridge.protocol import BridgeRejected
try:
    from bridge.git_changes import GitChanges, validate_payload
except ImportError:
    GitChanges = None


class PaneApi:
    def __init__(self, path): self.cwd = str(path)
    def member(self, route):
        if route['pane'] != 'p1': raise BridgeRejected('terminal_missing')
        return {'cwd': '/never-use', 'foreground_cwd': self.cwd}


class GitChangesTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(GitChanges, 'Read-only Git changes are not implemented')
        self.temp = tempfile.TemporaryDirectory(dir='/tmp'); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.git('init', '-q'); self.git('config', 'user.email', 'test@example.invalid'); self.git('config', 'user.name', 'Fixture')
        self.put('tracked.txt', 'original\n'); self.git('add', '.'); self.git('commit', '-qm', 'Initial')
        self.api = PaneApi(self.root); self.reader = GitChanges(self.api)
        self.route = {'machine':'gateway','session':'default','targetHash':'b'*64,'generation':'a'*64,'terminal':'t1','pane':'p1'}
    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, stderr=subprocess.DEVNULL).decode().strip()
    def put(self, path, text):
        target=self.root/path; target.parent.mkdir(parents=True, exist_ok=True); target.write_text(text); return target
    def read(self, page, entry): return self.reader.read(self.route, {'scope':page['scope'],'file':entry['id']})
    def test_staged_unstaged_and_untracked_are_separate_and_read_only(self):
        self.put('tracked.txt', 'staged\n'); self.git('add', '.'); self.put('tracked.txt', 'working\n')
        self.put('new file.txt', 'new content\n')
        before=self.git('status','--porcelain=v1'); page=self.reader.listing(self.route)
        self.assertEqual({(e['path'],e['section']) for e in page['entries']}, {('tracked.txt','staged'),('tracked.txt','unstaged'),('new file.txt','untracked')})
        diffs={e['section']:self.read(page,e)['text'] for e in page['entries']}
        self.assertIn('-original\n+staged', diffs['staged']); self.assertIn('-staged\n+working', diffs['unstaged'])
        self.assertIn('+new content', diffs['untracked']); self.assertEqual(self.git('status','--porcelain=v1'),before)
    def test_clean_and_non_repository(self):
        self.assertEqual(self.reader.listing(self.route)['entries'], [])
        outside=Path(tempfile.mkdtemp(dir=self.root)); self.api.cwd=str(outside)
        self.assertTrue(self.reader.listing(self.route)['repository'])
        self.api.cwd='/'; self.assertFalse(self.reader.listing(self.route)['repository'])
    def test_unborn_detached_nested_and_linked_worktree(self):
        self.git('checkout','--detach','-q'); self.assertIn('Detached',self.reader.listing(self.route)['branch'])
        nested=self.root/'nested'; nested.mkdir(); self.api.cwd=str(nested)
        self.assertEqual(self.reader.listing(self.route)['folder'],self.root.name)
        linked=self.root/'linked'; self.git('worktree','add','-qb','other',str(linked))
        self.api.cwd=str(linked); self.put('linked/new.txt','linked\n')
        self.assertIn('new.txt',[e['path'] for e in self.reader.listing(self.route)['entries']])
        unborn=self.root/'unborn'; unborn.mkdir(); subprocess.check_call(['git','init','-q',str(unborn)])
        self.api.cwd=str(unborn); (unborn/'first.txt').write_text('first'); page=self.reader.listing(self.route)
        self.assertTrue(page['repository']); self.assertEqual(page['entries'][0]['section'],'untracked')
    def test_rename_deletion_and_literal_pathspec(self):
        self.git('mv','tracked.txt','renamed.txt'); page=self.reader.listing(self.route)
        renamed=next(e for e in page['entries'] if e['path']=='renamed.txt')
        self.assertIn('tracked.txt',self.read(page,renamed)['text'])
        self.git('reset','--hard','-q','HEAD'); (self.root/'tracked.txt').unlink()
        self.put(':(glob)*.txt', 'literal\n'); self.put('-option.txt','option\n')
        page=self.reader.listing(self.route)
        for e in page['entries']:
            text=self.read(page,e)['text']
            if e['path']=='tracked.txt': self.assertIn('-original', text)
            if e['path']==':(glob)*.txt': self.assertIn('+literal',text); self.assertNotIn('+option',text)
    def test_binary_large_symlink_and_external_diff_config(self):
        (self.root/'binary.dat').write_bytes(b'\x00\x01')
        self.put('large.txt','x'*(256*1024+1)); (self.root/'link.txt').symlink_to('/etc/passwd')
        marker=self.root/'must-not-run'; script=self.put('external.sh',f'#!/bin/sh\ntouch "{marker}"\n'); script.chmod(0o700)
        self.git('config','diff.external',str(script)); self.git('config','core.fsmonitor',str(script))
        page=self.reader.listing(self.route)
        for e in page['entries']:
            result=self.read(page,e)
            if e['path'] in ('binary.dat','large.txt','link.txt'): self.assertTrue(result['notice']); self.assertEqual(result['text'],'')
        self.assertFalse(marker.exists())
    def test_changed_content_cwd_and_generation_reject_old_diff(self):
        self.put('tracked.txt','first\n'); page=self.reader.listing(self.route); entry=page['entries'][0]
        self.put('tracked.txt','second\n')
        with self.assertRaises(BridgeRejected): self.read(page,entry)
        page=self.reader.listing(self.route); (self.root/'nested').mkdir(); self.api.cwd=str(self.root/'nested')
        with self.assertRaises(BridgeRejected): self.read(page,page['entries'][0])
        self.api.cwd=str(self.root)
        with self.assertRaises(BridgeRejected): self.reader.read({**self.route,'generation':'c'*64},{'scope':page['scope'],'file':entry['id']})
    def test_payload_rejects_paths_and_extra_fields(self):
        validate_payload('changes.list',{}); validate_payload('changes.read',{'scope':'a'*64,'file':'b'*64})
        for op,p in [('changes.list',{'cwd':'/tmp'}),('changes.read',{'scope':'a'*64,'file':'../x'}),('changes.read',{'scope':'a'*64,'file':'b'*64,'path':'/tmp'}),('changes.write',{})]:
            with self.assertRaises(BridgeRejected): validate_payload(op,p)

    def test_deleted_parent_directory_and_missing_newline(self):
        self.put('sub/file.txt','before\n'); self.git('add','.'); self.git('commit','-qm','Nested')
        (self.root/'sub/file.txt').unlink(); (self.root/'sub').rmdir()
        self.put('no-newline.txt','last line')
        page=self.reader.listing(self.route)
        deleted=next(e for e in page['entries'] if e['path']=='sub/file.txt')
        self.assertIn('-before',self.read(page,deleted)['text'])
        added=next(e for e in page['entries'] if e['path']=='no-newline.txt')
        self.assertIn('+last line',self.read(page,added)['text'])

    def test_clean_filters_textconv_and_ignored_files_are_not_executed_or_listed(self):
        self.put('.gitattributes','tracked.txt filter=fixture diff=fixture\n')
        self.put('.gitignore','ignored.txt\n'); self.git('add','.');self.git('commit','-qm','Attributes')
        marker=self.root/'executed'; script=self.put('.git/driver',f'#!/bin/sh\ntouch "{marker}"\ncat\n');script.chmod(0o700)
        self.git('config','filter.fixture.clean',str(script)); self.git('config','filter.fixture.process',str(script))
        self.git('config','filter.fixture.required','true');self.git('config','diff.fixture.textconv',str(script))
        self.put('tracked.txt','changed\n');self.put('ignored.txt','ignored\n')
        page=self.reader.listing(self.route)
        self.assertEqual([e['path'] for e in page['entries']],['tracked.txt'])
        self.assertIn('+changed',self.read(page,page['entries'][0])['text']);self.assertFalse(marker.exists())

    def test_listing_limits_entries_and_flags_omissions(self):
        for i in range(502): self.put(f'new-{i}.txt','new')
        page=self.reader.listing(self.route)
        self.assertTrue(page['limited']);self.assertEqual(len(page['entries']),500)

    def test_binary_marker_words_in_text_are_not_treated_as_binary(self):
        self.put('explanation.txt','Binary files are handled separately.\n')
        page=self.reader.listing(self.route); result=self.read(page,page['entries'][0])
        self.assertEqual(result['notice'],'');self.assertIn('+Binary files are handled separately.',result['text'])

    def test_small_staged_diff_remains_readable_with_large_unstaged_file(self):
        self.put('tracked.txt','small staged change\n');self.git('add','tracked.txt')
        self.put('tracked.txt','x'*(300*1024))
        page=self.reader.listing(self.route);entry=next(e for e in page['entries'] if e['section']=='staged')
        result=self.read(page,entry)
        self.assertEqual(result['notice'],'');self.assertIn('+small staged change',result['text'])

if __name__=='__main__': unittest.main()
