#!/usr/bin/env python3
"""Add/remove this client's restricted public key. Never reads a private key."""
import argparse
from pathlib import Path
import shlex
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--public-key', required=True, type=Path)
    parser.add_argument('--herdr', default=str(Path.home()/'.local/bin/herdr'))
    parser.add_argument('--socket', default=str(Path.home()/'.config/herdr/herdr.sock'))
    parser.add_argument('--authorized-keys', type=Path, default=Path.home()/'.ssh/authorized_keys')
    parser.add_argument('--remove', action='store_true')
    parser.add_argument('--allow-input', action='store_true', help='Enable validated text + Enter for this client')
    args = parser.parse_args()
    parts = args.public_key.read_text().strip().split()
    if len(parts) < 2 or parts[0] != 'ssh-rsa' or '\n' in args.public_key.read_text().strip():
        parser.error('Expected one OpenSSH RSA public key')
    subprocess.run(['ssh-keygen','-lf',str(args.public_key)],check=True,stdout=subprocess.DEVNULL)
    key = ' '.join(parts[:2])
    gate = Path(__file__).resolve().with_name('catalog-gate.py')
    command = shlex.join(['/usr/bin/python3',str(gate),'--herdr',args.herdr,'--socket',args.socket] + (['--allow-input'] if args.allow_input else []))
    escaped = command.replace('\\','\\\\').replace('"','\\"')
    entry = f'restrict,command="{escaped}" {key} agentspace-client\n'
    path = args.authorized_keys
    original = path.read_text() if path.exists() else ''
    # Match only the exact public key, preserving all unrelated entries byte-for-byte.
    lines = original.splitlines(keepends=True)
    remaining = ''.join(line for line in lines if not any(line.split()[i:i+2] == parts[:2] for i in range(len(line.split())-1)))
    updated = remaining if args.remove else remaining + ('' if not remaining or remaining.endswith('\n') else '\n') + entry
    if updated != original:
        path.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
        with path.open('w') as out:
            out.write(updated)
        path.chmod(0o600)
    print('Client read-only access removed.' if args.remove else ('Client paired for catalog, observation and explicit terminal input.' if args.allow_input else 'Client paired for read-only Herdr catalog and observation access.'))


if __name__ == '__main__':
    main()
