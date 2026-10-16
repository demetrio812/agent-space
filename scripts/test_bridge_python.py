import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from bridge.gateway import Machine, ssh_arguments


class PythonDiscoveryTests(unittest.TestCase):
    def test_broken_path_python_uses_working_account_python_without_eating_stdin(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            broken = root / 'bin'
            broken.mkdir()
            (broken / 'python3').write_text('#!/bin/sh\nexit 72\n')
            (broken / 'python3').chmod(0o700)
            account = root / '.local/bin'
            account.mkdir(parents=True)
            (account / 'python3').symlink_to(sys.executable)
            source = 'import sys; print(sys.stdin.read())'
            command = ssh_arguments(Machine('a'*32, 'Mac', 'host', 'default', True), source)[-1]
            result = subprocess.run(['/bin/sh', '-c', command], input='bootstrap input survives',
                                    capture_output=True, text=True, timeout=5,
                                    env=dict(os.environ, HOME=str(root), PATH=str(broken)))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, 'bootstrap input survives\n')

    def test_failed_bootstrap_does_not_try_another_interpreter(self):
        command = ssh_arguments(Machine('a'*32, 'Mac', 'host', 'default', True),
                                'import sys; print("one attempt"); sys.exit(7)')[-1]
        result = subprocess.run(['/bin/sh', '-c', command], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout, 'one attempt\n')
