import base64
import hashlib
import os
from pathlib import Path
import stat
import tempfile
import unittest
from bridge.image_transfers import ImageTransfers
from bridge.local_api import LocalApi
from bridge.protocol import BridgeRejected
from bridge_test_support import FakeHerdr

PNG=bytes.fromhex('89504e470d0a1a0a')+b'disposable-image'
class ImageTransferTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(dir='/tmp'); self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name).resolve(); self.herdr=FakeHerdr(self.root).__enter__(); self.addCleanup(self.herdr.__exit__)
        self.api=LocalApi(self.herdr.socket_path,'native'); self.now=1000.
        self.route={'machine':'gateway','session':'default','targetHash':hashlib.sha256(b'gateway').hexdigest(),'generation':self.api.generation(),'terminal':'t1','pane':'p1'}
        self.store=ImageTransfers(self.api,self.root/'attachments',clock=lambda:self.now); self.addCleanup(self.store.close)
    def begin(self,data=PNG,**changes):
        payload={'extension':'png','size':len(data),'sha256':hashlib.sha256(data).hexdigest(),**changes}
        return self.store.operation('image.begin',self.route,payload)['token']
    def chunk(self,token,data=PNG,offset=0,route=None):
        return self.store.operation('image.chunk',route or self.route,{'token':token,'offset':offset,'bytes':base64.b64encode(data).decode()})
    def finish(self,token): return self.store.operation('image.finish',self.route,{'token':token})
    def test_exact_bytes_permissions_and_no_terminal_input(self):
        token=self.begin(); self.assertEqual(self.chunk(token),{'offset':len(PNG)})
        receipt=self.finish(token); path=Path(receipt['path'])
        self.assertEqual(path.read_bytes(),PNG); self.assertEqual(receipt['sha256'],hashlib.sha256(PNG).hexdigest())
        self.assertEqual(stat.S_IMODE(path.stat().st_mode),0o600); self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode),0o700)
        self.assertEqual(self.store.active_count,0)
        self.assertFalse(any(r['method'].startswith('pane.send') for r in self.herdr.calls))
    def test_digest_signature_and_incomplete_never_commit(self):
        for data,changes in [(b'not-image',{}),(PNG,{'sha256':'0'*64}),(PNG,{'size':len(PNG)+1})]:
            token=self.begin(data,**changes); self.chunk(token,data)
            with self.assertRaises(BridgeRejected):self.finish(token)
        self.assertEqual(list((self.root/'attachments').iterdir()),[])
    def test_exact_offsets_route_and_generation(self):
        token=self.begin(); self.chunk(token)
        for route,offset in [(self.route,0),({**self.route,'pane':'other'},len(PNG)),({**self.route,'generation':'0'*64},len(PNG))]:
            with self.assertRaises(BridgeRejected): self.chunk(token,b'x',offset,route)
        self.store.operation('image.cancel',self.route,{'token':token})
        self.assertEqual(self.store.active_count,0)
    def test_payload_bounds_and_quota(self):
        for changes in [{'size':True},{'size':0},{'size':16777217},{'extension':'../png'},{'sha256':'A'*64},{'extra':1}]:
            with self.assertRaises(BridgeRejected):self.begin(**changes)
        tokens=[self.begin() for _ in range(4)]
        with self.assertRaises(BridgeRejected):self.begin()
        for bad in [True,-1,'0']:
            with self.assertRaises(BridgeRejected):self.chunk(tokens[0],offset=bad)
    def test_expiry_and_cleanup_only_owned_regular_files(self):
        token=self.begin(); self.chunk(token); path=Path(self.finish(token)['path'])
        token=self.begin(); unrelated=path.parent/'keep'; unrelated.write_text('keep')
        link=path.parent/('ag-image-'+'a'*32+'.png'); link.symlink_to(unrelated)
        self.now+=301; self.store.reap(); self.assertEqual(self.store.active_count,0); self.assertTrue(path.exists())
        os.utime(path,(0,0)); self.store.reap(); self.assertFalse(path.exists()); self.assertTrue(link.is_symlink()); self.assertEqual(unrelated.read_text(),'keep')
    def test_unsafe_root_and_replaced_partial_cannot_overwrite(self):
        other=self.root/'other'; other.mkdir(); symlink=self.root/'symlink'; symlink.symlink_to(other)
        with self.assertRaises((ValueError,BridgeRejected)):ImageTransfers(self.api,symlink)
        token=self.begin(); partial=next((self.root/'attachments').glob('*.part'))
        partial.unlink(); victim=self.root/'victim'; victim.write_text('keep'); partial.symlink_to(victim)
        with self.assertRaises(BridgeRejected):self.chunk(token)
        self.assertEqual(victim.read_text(),'keep')
    def test_finish_revalidates_membership(self):
        token=self.begin(); self.chunk(token)
        original=self.api.member
        def missing(route):raise BridgeRejected('route_changed')
        self.api.member=missing
        with self.assertRaises(BridgeRejected):self.finish(token)
        self.api.member=original
        self.assertEqual(list((self.root/'attachments').iterdir()),[])

    def test_publication_rejects_a_partial_replaced_during_final_check(self):
        token=self.begin(); self.chunk(token)
        original=self.store._member; checks=0
        victim=self.root/'victim'; victim.write_text('keep')
        def swap(route):
            nonlocal checks
            original(route); checks+=1
            if checks==2:
                partial=next((self.root/'attachments').glob('*.part')); partial.unlink(); partial.symlink_to(victim)
        self.store._member=swap
        with self.assertRaises(BridgeRejected):self.finish(token)
        self.assertEqual(victim.read_text(),'keep')
        self.assertFalse(list((self.root/'attachments').iterdir()))
