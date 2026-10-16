import concurrent.futures
import hashlib
import io
import os
from pathlib import Path
import stat
import tempfile
import subprocess
import sys
import unittest
import zipfile
import warnings

from bridge.bootstrap import install_package, validate_package, cached_package
from bridge.package import build_package


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ab-', dir='/tmp')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve() / 'cache'
        self.data = build_package(Path(__file__).with_name('catalog-gate.py'))
        self.digest = hashlib.sha256(self.data).hexdigest()

    def test_verified_version_reused_without_replacing_inode(self):
        path = install_package(self.root, self.data, self.digest)
        inode = path.stat().st_ino
        self.assertEqual(install_package(self.root, self.data, self.digest).stat().st_ino, inode)
        self.assertEqual(path.read_bytes(), self.data)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)

    def test_bad_digest_never_published(self):
        with self.assertRaises(ValueError):
            install_package(self.root, self.data[:-1], self.digest)
        self.assertFalse((self.root / self.digest).exists())

    def test_symlink_ancestor_never_writes_outside(self):
        outside = Path(self.temp.name) / 'outside'; outside.mkdir()
        self.root.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            install_package(self.root, self.data, self.digest)
        self.assertEqual(list(outside.iterdir()), [])

    def test_regular_file_or_public_cache_is_rejected(self):
        self.root.write_text('file')
        with self.assertRaises(ValueError): install_package(self.root, self.data, self.digest)
        self.root.unlink(); self.root.mkdir(mode=0o755)
        with self.assertRaises(ValueError): install_package(self.root, self.data, self.digest)

    def test_unsafe_package_type_is_rejected_on_cache_hit(self):
        path = install_package(self.root, self.data, self.digest)
        path.unlink()
        outside = Path(self.temp.name) / 'outside'; outside.write_bytes(self.data)
        path.symlink_to(outside)
        with self.assertRaises(ValueError): cached_package(self.root, self.digest)

    def test_corrupt_immutable_version_is_not_overwritten(self):
        path = install_package(self.root, self.data, self.digest)
        path.write_bytes(b'corrupt')
        with self.assertRaises(ValueError): install_package(self.root, self.data, self.digest)
        self.assertEqual(path.read_bytes(), b'corrupt')

    def test_concurrent_installers_publish_one_complete_version(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            paths = list(pool.map(lambda _: install_package(self.root, self.data, self.digest), range(4)))
        self.assertEqual({p.stat().st_ino for p in paths}, {paths[0].stat().st_ino})
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), [self.digest])

    def test_archive_allowlist_compression_duplicates_and_size(self):
        for special, compression in [('evil.py', zipfile.ZIP_STORED),
                                     ('../worker.py', zipfile.ZIP_STORED),
                                     ('worker.py', zipfile.ZIP_DEFLATED)]:
            data = io.BytesIO()
            with zipfile.ZipFile(data, 'w') as z:
                for name in ['__main__.py', 'worker.py', 'protocol.py', 'local_api.py']:
                    z.writestr(name, b'pass\n', compress_type=compression)
                if special != 'worker.py': z.writestr(special, b'pass\n')
            raw = data.getvalue()
            with self.subTest(special=special), self.assertRaises(ValueError):
                validate_package(raw, hashlib.sha256(raw).hexdigest())
        with self.assertRaises(ValueError): validate_package(b'x' * (512 * 1024 + 1), self.digest)

    def test_builder_reproducible(self):
        self.assertEqual(self.data, build_package(Path(__file__).with_name('catalog-gate.py')))

    def test_duplicate_zip_members_and_wrong_account_cache_are_rejected(self):
        from unittest.mock import patch
        data=io.BytesIO(self.data)
        with warnings.catch_warnings():
            warnings.simplefilter('ignore',UserWarning)
            with zipfile.ZipFile(data,'a') as archive: archive.writestr('worker.py',b'pass\n')
        raw=data.getvalue()
        with self.assertRaises(ValueError): validate_package(raw,hashlib.sha256(raw).hexdigest())
        install_package(self.root,self.data,self.digest)
        with patch('bridge.bootstrap.os.getuid',return_value=os.getuid()+1), self.assertRaises(ValueError):
            cached_package(self.root,self.digest)

    def test_interrupted_bootstrap_never_publishes_package(self):
        import json
        root=Path(self.temp.name).resolve()
        request={'type':'bootstrap','protocol':'agentspace-bridge-v2','digest':self.digest,
                 'nonce':'a'*32,'config':{'role':'local','lane':'discovery','herdr':'','socket':'','generationStyle':'peer'}}
        result=subprocess.run([sys.executable,str(Path(__file__).parent/'bridge/bootstrap.py')],
                              input=(json.dumps(request)+'\n').encode(),capture_output=True,
                              env=dict(os.environ,HOME=str(root)),timeout=3)
        self.assertNotEqual(result.returncode,0)
        self.assertFalse((root/'.cache/agentspace/bridges'/self.digest).exists())

    def test_complete_bootstrap_executes_verified_descriptor_then_reuses_cache(self):
        import base64
        import json
        from bridge_test_support import FakeHerdr
        root=Path(self.temp.name).resolve()
        with FakeHerdr(root) as h:
            request={'type':'bootstrap','protocol':'agentspace-bridge-v2','digest':self.digest,
                     'nonce':'a'*32,'config':{'role':'local','lane':'discovery','herdr':str(h.cli),'socket':h.socket_path,'generationStyle':'peer'}}
            for needed in [True,False]:
                request['config']['role']='local' if needed else 'gateway'
                process=subprocess.Popen([sys.executable,str(Path(__file__).parent/'bridge/bootstrap.py')],
                    stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=dict(os.environ,HOME=str(root)))
                try:
                    process.stdin.write((json.dumps(request)+'\n').encode()); process.stdin.flush()
                    response=json.loads(process.stdout.readline())
                    self.assertEqual(response,{'type':'cache','digest':self.digest,'needed':needed})
                    if needed:
                        package={'type':'package','digest':self.digest,'bytes':base64.b64encode(self.data).decode()}
                        process.stdin.write((json.dumps(package)+'\n').encode()); process.stdin.flush()
                    hello=process.stdout.readline()
                    self.assertTrue(hello,process.stderr.read() if process.poll() is not None else b'No hello')
                    self.assertEqual(json.loads(hello)['protocol'],'agentspace-bridge-v2')
                    process.stdin.close(); process.wait(timeout=4)
                finally:
                    if process.poll() is None: process.kill(); process.wait()
                    if not process.stdin.closed: process.stdin.close()
                    process.stdout.close(); process.stderr.close()


if __name__ == '__main__': unittest.main()
