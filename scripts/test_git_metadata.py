import json
import sys
import tempfile
import threading
import time
import unittest
from bridge.git_metadata import GitMetadata,repository,token_metadata,pr_url,run

class MetadataTests(unittest.TestCase):
    def test_branch_and_pr_are_bound_to_cwd_and_repo_and_cached(self):
        calls=[]
        branch=['feature/one']
        def runner(args,cwd):
            calls.append((args,cwd))
            if args[0]=='gh':return json.dumps([{'number':42,'url':'https://github.com/example/project/pull/42','state':'OPEN','isDraft':True,'headRefName':branch[0]}])
            if 'remote' in args:return 'git@github.com:example/project.git'
            return branch[0]
        metadata=GitMetadata(threading.Event(),runner)
        value=metadata.resolve('/peer/project')
        self.assertEqual(value,{'branch':'feature/one','prNumber':42,'prUrl':'https://github.com/example/project/pull/42','prState':'DRAFT'})
        metadata.resolve('/peer/project')
        self.assertEqual(sum(a[0]=='gh' for a,c in calls),1)
        self.assertTrue(all(c=='/peer/project' for a,c in calls))
        self.assertIn('github.com/example/project',calls[2][0])
        branch[0]='feature/two';metadata.resolve('/peer/project')
        self.assertEqual(sum(a[0]=='gh' for a,c in calls),2)

    def test_missing_gh_detached_head_and_mismatched_pr(self):
        def runner(args,cwd):
            if args[0]=='gh':raise FileNotFoundError()
            return 'https://github.com/example/project.git' if 'remote' in args else 'main'
        self.assertEqual(GitMetadata(threading.Event(),runner).resolve('/repo'),{'branch':'main'})
        def detached(args,cwd):return 'abc123' if '--short' in args else 'HEAD'
        self.assertEqual(GitMetadata(threading.Event(),detached).resolve('/repo'),{'branch':'Detached abc123'})
        def wrong(args,cwd):
            if args[0]=='gh':return json.dumps([{'number':2,'url':'https://github.com/wrong/repo/pull/2','headRefName':'main','state':'OPEN'}])
            return runner(args,cwd)
        self.assertEqual(GitMetadata(threading.Event(),wrong).resolve('/repo'),{'branch':'main'})

    def test_enrichment_does_not_wait_and_retargets_without_old_metadata(self):
        release=threading.Event();started=threading.Event();closed=threading.Event()
        self.addCleanup(closed.set);self.addCleanup(release.set)
        def runner(args,cwd):
            started.set();release.wait(2)
            return '' if 'remote' in args else 'feature/one'
        metadata=GitMetadata(closed,runner)
        def catalog(cwd):return {'serverIdentity':'one','workspaces':[], 'catalog':{'result':{'agents':[{'cwd':cwd}]}}}
        before=time.monotonic(); first=metadata.enrich(catalog('/repo'))
        self.assertLess(time.monotonic()-before,.1)
        self.assertEqual(first['catalog']['result']['agents'][0]['gitMetadata'],{})
        self.assertTrue(started.wait(1));release.set()
        deadline=time.monotonic()+2
        while metadata.pending and time.monotonic()<deadline:time.sleep(.01)
        self.assertEqual(metadata.enrich(catalog('/repo'))['catalog']['result']['agents'][0]['gitMetadata'],{'branch':'feature/one'})
        self.assertEqual(metadata.enrich(catalog('/other'))['catalog']['result']['agents'][0]['gitMetadata'],{})

    def test_herdr_tokens_and_untrusted_links(self):
        self.assertEqual(token_metadata({'branch':'feature/x','pr':'#42 merged','pr_url':'https://github.com/example/project/pull/42'}),
            {'branch':'feature/x','prNumber':42,'prState':'MERGED','prUrl':'https://github.com/example/project/pull/42'})
        for url in ['javascript:evil','file:///tmp/a','https://a:b@github.com/a/b/pull/1','https://github.com/a/b/pull/1?x=1']:
            self.assertEqual(pr_url(url),'')
        self.assertEqual(repository('ssh://git@github.com/example/project.git'),'github.com/example/project')
        self.assertEqual(repository('/local/repo'),'')
        self.assertEqual(repository('https://github.com/example/project;evil'),'')

    def test_subprocess_is_bounded_and_accepts_literal_args(self):
        with tempfile.TemporaryDirectory() as cwd:
            self.assertEqual(run([sys.executable,'-c','import sys;print(sys.argv[1])','$(echo literal)'],cwd),'$(echo literal)')
            with self.assertRaises(TimeoutError):
                run([sys.executable,'-c','import time;time.sleep(2)'],cwd,timeout=.05)
            with self.assertRaises(ValueError):run([sys.executable,'-c','print("x"*70000)'],cwd)
