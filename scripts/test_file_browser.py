import base64
import hashlib
import os
from pathlib import Path
import tempfile
import unittest
try:
    from bridge.file_browser import FileBrowser, validate_payload
except ImportError:
    FileBrowser=None
from bridge.protocol import BridgeRejected

class Api:
    def __init__(self,cwd):self.cwd=str(cwd)
    def member(self,route):
        if route['pane']!='p1':raise BridgeRejected('terminal_missing')
        return {'cwd':self.cwd}
    def generation(self):return 'a'*64

class FileBrowserTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(FileBrowser,'Computer file browser is not implemented')
        self.temp=tempfile.TemporaryDirectory(dir='/tmp');self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name).resolve();self.api=Api(self.root)
        self.browser=FileBrowser(self.api);self.addCleanup(self.browser.close)
        self.route={'terminal':'t1','pane':'p1','generation':'a'*64,'machine':'gateway','session':'local','targetHash':'b'*64}
    def request(self,op,payload):return self.browser.operation('fs.'+op,self.route,payload)
    def page(self,path=''):return self.request('list',{'path':path})
    def begin(self,name='hello.bin',data=b'\x00hello'):
        page=self.page();return self.request('begin',{'path':page['path'],'scope':page['scope'],'name':name,'size':len(data),'sha256':hashlib.sha256(data).hexdigest()})
    def test_download_binary_chunks_are_revision_scoped_and_do_not_follow_links(self):
        data=bytes(range(256))*1100
        source=self.root/'archive.bin';source.write_bytes(data)
        page=self.page();entry=page['entries'][0]
        p={'path':page['path'],'scope':page['scope'],'name':entry['name'],'revision':entry['revision'],'offset':0}
        first=self.request('download',p)
        self.assertEqual(base64.b64decode(first['bytes']),data[:256*1024]);self.assertFalse(first['eof'])
        second=self.request('download',dict(p,offset=256*1024))
        self.assertEqual(base64.b64decode(second['bytes']),data[256*1024:]);self.assertTrue(second['eof'])
        source.write_bytes(b'changed')
        with self.assertRaises(BridgeRejected):self.request('download',p)
        source.unlink();source.symlink_to('/etc/passwd')
        with self.assertRaises(BridgeRejected):self.request('download',p)
        for offset in (-1,True,32*1024*1024+1):
            with self.assertRaises(BridgeRejected):self.request('download',dict(p,offset=offset))

    def test_browse_starts_at_pane_and_can_navigate_elsewhere(self):
        (self.root/'child').mkdir();(self.root/'readme.md').write_text('# hi');os.mkfifo(self.root/'pipe')
        page=self.page();self.assertEqual(page['path'],str(self.root))
        self.assertEqual({e['name']:e['kind'] for e in page['entries']},{'child':'directory','readme.md':'file','pipe':'other'})
        self.assertEqual(self.page(str(self.root.parent))['path'],str(self.root.parent))
        self.assertEqual(self.page('~')['path'],str(Path.home().resolve()))
        (self.root/'linked').symlink_to(self.root/'child',target_is_directory=True)
        self.assertEqual(self.page(str(self.root/'linked'))['path'],str(self.root/'child'))
    def test_preview_is_bounded_regular_utf8_and_scoped(self):
        file=self.root/'readme.md';file.write_text('# hello');page=self.page();entry=page['entries'][0]
        payload={'path':page['path'],'scope':page['scope'],'name':entry['name'],'revision':entry['revision']}
        self.assertEqual(self.request('read',payload)['document']['text'],'# hello')
        file.write_text('changed')
        with self.assertRaises(BridgeRejected):self.request('read',payload)
        file.unlink();file.symlink_to('/etc/passwd')
        with self.assertRaises(BridgeRejected):self.request('read',payload)
    def test_binary_and_zero_byte_upload_are_atomic_and_do_not_overwrite(self):
        for name,data in [('hello.bin',b'\x00hello'),('empty.txt',b'')]:
            begin=self.begin(name,data);token=begin['token'];self.assertFalse((self.root/name).exists())
            if data:self.request('chunk',{'token':token,'offset':0,'bytes':base64.b64encode(data).decode()})
            result=self.request('finish',{'token':token});self.assertTrue(result['uploaded']);self.assertEqual((self.root/name).read_bytes(),data)
            with self.assertRaises(BridgeRejected):self.begin(name,data)
        self.assertFalse(any(p.name.endswith('.part') for p in self.root.iterdir()))
    def test_digest_mismatch_cancel_close_and_replacement_clean_partials(self):
        begin=self.begin();token=begin['token']
        self.request('chunk',{'token':token,'offset':0,'bytes':base64.b64encode(b'wrong!').decode()})
        with self.assertRaises(BridgeRejected):self.request('finish',{'token':token})
        token=self.begin()['token'];self.request('cancel',{'token':token})
        token=self.begin()['token'];self.api.cwd=str(self.root.parent)
        with self.assertRaises(BridgeRejected):self.request('chunk',{'token':token,'offset':0,'bytes':'YQ=='})
        self.assertEqual(list(self.root.iterdir()),[])
    def test_existing_symlink_and_folder_publication_race_are_rejected(self):
        token=self.begin()['token'];(self.root/'hello.bin').symlink_to('/etc/passwd')
        self.request('chunk',{'token':token,'offset':0,'bytes':base64.b64encode(b'\x00hello').decode()})
        with self.assertRaises(BridgeRejected):self.request('finish',{'token':token})
        self.assertTrue((self.root/'hello.bin').is_symlink())
        (self.root/'hello.bin').unlink();token=self.begin()['token']
        saved=self.root.with_name(self.root.name+'-saved');self.root.rename(saved);self.root.mkdir()
        try:
            with self.assertRaises(BridgeRejected):self.request('chunk',{'token':token,'offset':0,'bytes':'YQ=='})
            self.assertEqual(list(self.root.iterdir()),[]);self.assertEqual(list(saved.iterdir()),[])
        finally:self.root.rmdir();saved.rename(self.root)
    def test_staged_inode_digest_and_size_are_verified_before_publication(self):
        data=b'\x00hello';token=self.begin()['token']
        self.request('chunk',{'token':token,'offset':0,'bytes':base64.b64encode(data).decode()})
        os.pwrite(self.browser.pending[token]['fd'],b'WRONG!',0)
        with self.assertRaises(BridgeRejected):self.request('finish',{'token':token})
        self.assertFalse((self.root/'hello.bin').exists())
    def test_cancel_keeps_a_replacement_it_does_not_own(self):
        token=self.begin()['token'];item=self.browser.pending[token];directory=item.get('stage',item['dir'])
        os.unlink(item['temp'],dir_fd=directory)
        other=os.open(item['temp'],os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600,dir_fd=directory);os.write(other,b'unrelated');os.close(other)
        held=os.dup(directory)
        try:
            self.request('cancel',{'token':token})
            check=os.open(item['temp'],os.O_RDONLY,dir_fd=held)
            try:self.assertEqual(os.read(check,100),b'unrelated')
            finally:os.close(check)
        finally:os.close(held)
    def test_search_only_ancestor_and_no_hardlink_filesystem(self):
        from unittest.mock import patch
        import errno
        parent=self.root/'passage';parent.mkdir();child=parent/'readable';child.mkdir();(child/'ok').touch()
        parent.chmod(0o111)
        try:self.assertEqual(self.page(str(child))['entries'][0]['name'],'ok')
        finally:parent.chmod(0o700)
        token=self.begin('empty',b'')['token']
        with patch('bridge.file_browser.os.link',side_effect=OSError(errno.ENOTSUP,'No hard links')):
            self.assertTrue(self.request('finish',{'token':token})['uploaded'])

    def test_create_folder_is_scoped_and_never_replaces_existing_items(self):
        page=self.page();payload={'path':page['path'],'scope':page['scope'],'name':'New folder'}
        result=self.request('mkdir',payload)
        self.assertEqual(result,{'created':True,'path':str(self.root/'New folder')})
        self.assertTrue((self.root/'New folder').is_dir())
        for existing in ('New folder','existing.txt','link'):
            if existing=='existing.txt':(self.root/existing).write_text('keep')
            if existing=='link':(self.root/existing).symlink_to(self.root/'New folder')
            with self.assertRaises(BridgeRejected) as error:self.request('mkdir',{**payload,'name':existing})
            self.assertEqual(error.exception.code,'file_exists')
        self.assertEqual((self.root/'existing.txt').read_text(),'keep')
        for invalid in ('../other','/absolute','.','..',' ','.agentspace-upload-test'):
            with self.assertRaises(BridgeRejected):self.request('mkdir',{**payload,'name':invalid})
        self.api.cwd=str(self.root.parent)
        with self.assertRaises(BridgeRejected):self.request('mkdir',{**payload,'name':'stale'})
        self.assertFalse((self.root/'stale').exists())

    def test_limits_and_payloads(self):
        for name in ('../outside','/absolute','.','..','a/b','bad\x00name'):
            with self.assertRaises(BridgeRejected):self.begin(name)
        with self.assertRaises(BridgeRejected):validate_payload('fs.begin',{'path':str(self.root),'scope':'a'*64,'name':'big','size':32*1024*1024+1,'sha256':'a'*64})
        with self.assertRaises(BridgeRejected):self.page('../relative')
        for i in range(1002):(self.root/f'f{i}').touch()
        page=self.page();self.assertTrue(page['limited']);self.assertEqual(len(page['entries']),1000)
    def test_token_is_bound_to_exact_route_and_expiry_cleans(self):
        token=self.begin()['token']
        with self.assertRaises(BridgeRejected):self.browser.operation('fs.cancel',{**self.route,'terminal':'t2'},{'token':token})
        self.browser.pending[token]['last']-=301;self.browser.reap()
        self.assertEqual(list(self.root.iterdir()),[])

if __name__=='__main__':unittest.main()
