"""Disposable one-request-per-socket Herdr API. Never touches real sessions."""
import json
import os
from pathlib import Path
import socket
import sys
import threading

root=Path(sys.argv[1]); path=root/'.config/herdr/herdr.sock'
path.parent.mkdir(parents=True,exist_ok=True)
if path.exists(): path.unlink()
listener=socket.socket(socket.AF_UNIX); listener.bind(str(path)); listener.listen()
lock=threading.Lock()

def serve(connection):
    with connection:
        connection.settimeout(10)
        with connection.makefile('rb') as reader: request=json.loads(reader.readline(2*1024*1024))
        with lock:
            with (root/'api-calls.jsonl').open('a') as output: output.write(json.dumps(request)+'\n')
        method=request['method']
        if method.startswith('pane.send_') and (root/'fail-after-input').exists(): return
        result={
          'agent.list':{'agents':[{'terminal_id':'t1','pane_id':'p1','workspace_id':'w1','tab_id':'tab1','terminal_title':'Normal SSH fixture','agent_status':'idle'}]},
          'workspace.list':{'workspaces':[{'workspace_id':'w1','label':'Fixture workspace'}]},
          'tab.list':{'tabs':[]},
          'pane.layout':{'layout':{'panes':[{'pane_id':'p1','rect':{'width':90,'height':30}}]}}
        }.get(method,{'type':'ok'})
        connection.sendall((json.dumps({'id':request['id'],'result':result})+'\n').encode())

print(json.dumps({'ready':True}),flush=True)
while True:
    connection,_=listener.accept()
    threading.Thread(target=serve,args=(connection,),daemon=True).start()
