import base64
import json
import signal
import sys
from worker import LocalWorker, discover_config
from protocol import read_record, write_record, BridgeRejected


def main():
    try: config = discover_config(json.loads(base64.b64decode(sys.argv[1],validate=True)))
    except BridgeRejected:
        write_record(sys.stdout.buffer,{'type':'setup_error','code':'setup_required','reason':'herdr_missing'})
        return
    worker_type = LocalWorker
    if config['role']=='gateway':
        try:
            from gateway import GatewayWorker
            worker_type=GatewayWorker
        except ImportError: pass
    worker=worker_type(config,sys.stdout.buffer)
    for sig in (signal.SIGTERM,signal.SIGHUP,signal.SIGINT):
        signal.signal(sig,lambda *_: (worker.close(),sys.exit(0)))
    write_record(sys.stdout.buffer,worker.hello())
    try:
        while not worker.closed.is_set():
            row=read_record(sys.stdin.buffer)
            if row is None: break
            worker.handle(row)
    finally: worker.close()


if __name__=='__main__': main()
