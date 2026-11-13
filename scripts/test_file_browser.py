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
