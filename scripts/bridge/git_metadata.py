"""Best-effort Git/PR metadata. Never runs on the catalog or terminal input path."""
from collections import OrderedDict
import json
import os
from pathlib import Path
import queue
import re
import selectors
import subprocess
import threading
import time
from urllib.parse import urlsplit


def clean(value, limit=256):
    return value if isinstance(value,str) and len(value)<=limit and not any(ord(c)<32 or 127<=ord(c)<160 for c in value) else ''


def pr_url(value):
    value=clean(value,2048)
    try:
        url=urlsplit(value)
        if (url.scheme=='https' and url.hostname and not url.username and not url.password
                and not url.query and not url.fragment and re.fullmatch(r'/[\w.-]+/[\w.-]+/pull/[1-9][0-9]*',url.path)):
            return value
    except ValueError: pass
    return ''


def token_metadata(tokens):
    if not isinstance(tokens,dict): return {}
    result={}
    branch=clean(tokens.get('branch') or tokens.get('git_branch'))
    if branch: result['branch']=branch
    label=clean(tokens.get('pr') or tokens.get('pr_status'))
    url=pr_url(tokens.get('pr_url') or tokens.get('pr_link'))
    match=re.search(r'#([1-9][0-9]{0,9})\b',label)
    if url or match:
        result['prNumber']=int(urlsplit(url).path.rsplit('/',1)[-1]) if url else int(match[1])
        result['prUrl']=url
        result['prState']=next((s for s in ('MERGED','CLOSED','DRAFT','OPEN') if s.lower() in label.lower()),'')
    return result


def run(args,cwd,timeout=4):
    # Fixed argv, bounded output/time, no shell, hooks, prompt or external pager.
    env={k:v for k,v in os.environ.items() if not k.startswith('GIT_')}
    env.update(GIT_TERMINAL_PROMPT='0',GIT_OPTIONAL_LOCKS='0',GH_PROMPT_DISABLED='1',GH_PAGER='cat',PAGER='cat')
    process=subprocess.Popen(args,cwd=cwd,env=env,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
    data=bytearray(); deadline=time.monotonic()+timeout
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout,selectors.EVENT_READ)
            while True:
                remaining=deadline-time.monotonic()
                if remaining<=0: raise TimeoutError()
                if not selector.select(remaining): raise TimeoutError()
                chunk=os.read(process.stdout.fileno(),8192)
                if not chunk: break
                data.extend(chunk)
                if len(data)>65536: raise ValueError('Metadata too large')
        if process.wait(timeout=max(.01,deadline-time.monotonic())): return ''
        return data.decode('utf-8').strip()
    finally:
        if process.poll() is None: process.kill()
        process.wait();process.stdout.close()


def repository(remote):
    # gh receives an explicit repository: never infer one from the gateway cwd.
    remote=clean(remote,2048)
    if remote.startswith('git@') and ':' in remote:
        host,path=remote[4:].split(':',1)
    else:
        try:
            url=urlsplit(remote)
            if url.scheme not in ('https','ssh'): return ''
            host,path=url.hostname or '',url.path.lstrip('/')
        except ValueError: return ''
    path=path.removesuffix('.git')
    if not re.fullmatch(r'[A-Za-z0-9.-]+',host) or not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+',path): return ''
    return host+'/'+path


class GitMetadata:
    def __init__(self,closed,runner=run):
        self.closed=closed;self.run=runner;self.lock=threading.Lock()
        self.cache=OrderedDict();self.pr_cache=OrderedDict();self.pending=set();self.jobs=queue.Queue(maxsize=64)
        self.started=False

    def enrich(self,catalog):
        generation=catalog['serverIdentity']
        workspaces={w.get('workspace_id'):w for w in catalog.get('workspaces',[]) if isinstance(w,dict)}
        now=time.monotonic()
        for row in catalog['catalog']['result']['agents']:
            workspace=workspaces.get(row.get('workspace_id'),{})
            pane_tokens=row.get('tokens') if isinstance(row.get('tokens'),dict) else {}
            workspace_tokens=workspace.get('tokens') if isinstance(workspace.get('tokens'),dict) else {}
            reported=token_metadata({**workspace_tokens,**pane_tokens})
            cwd=clean(row.get('foreground_cwd') or row.get('cwd'),4096)
            if not cwd.startswith('/'):
                worktree=workspace.get('worktree')
                cwd=clean(worktree.get('checkout_path'),4096) if isinstance(worktree,dict) else ''
            value={}
            if cwd.startswith('/'):
                key=(generation,cwd)
                with self.lock:
                    entry=self.cache.get(key)
                    if entry and now-entry[0]<90: value=dict(entry[1])
                    if (not entry or now-entry[0]>=15) and key not in self.pending and not self.closed.is_set():
                        try:self.jobs.put_nowait(key)
                        except queue.Full:pass
                        else:
                            self.pending.add(key)
                            if not self.started:
                                self.started=True
                                threading.Thread(target=self._loop,daemon=True).start()
            # Once Git has identified the branch, don't combine it with a token
            # explicitly describing a different branch.
            if value and reported.get('branch') and reported['branch']!=value.get('branch'): reported={}
            row['gitMetadata']={**reported,**value}
        return catalog

    def _loop(self):
        while not self.closed.is_set():
            try:key=self.jobs.get(timeout=.25)
            except queue.Empty:continue
            try:value=self.resolve(key[1])
            except (OSError,ValueError,TimeoutError,subprocess.SubprocessError):value={}
            with self.lock:
                self.pending.discard(key);self.cache[key]=(time.monotonic(),value);self.cache.move_to_end(key)
                while len(self.cache)>128:self.cache.popitem(last=False)

    def resolve(self,cwd):
        branch=clean(self.run(['git','-c','core.fsmonitor=false','rev-parse','--abbrev-ref','HEAD'],cwd))
        if not branch:return {}
        if branch=='HEAD':
            sha=clean(self.run(['git','rev-parse','--short','HEAD'],cwd))
            return {'branch':('Detached '+sha) if sha else 'Detached HEAD'}
        result={'branch':branch}
        repo=repository(self.run(['git','remote','get-url','origin'],cwd))
        if not repo:return result
        key=(repo,branch);now=time.monotonic();cached=self.pr_cache.get(key)
        if not cached or now-cached[0]>=60:
            pr={}
            try:
                raw=self.run(['gh','pr','list','--repo',repo,'--head',branch,'--state','all','--limit','10','--json','number,url,state,isDraft,headRefName'],cwd)
                rows=json.loads(raw) if raw else []
                rows=[r for r in rows if isinstance(r,dict) and r.get('headRefName')==branch] if isinstance(rows,list) else []
                rows.sort(key=lambda r:r.get('state')!='OPEN')
                if rows:
                    row=rows[0];url=pr_url(row.get('url'));number=row.get('number')
                    # Bind the URL to both the repository and reported PR number.
                    if (isinstance(number,int) and not isinstance(number,bool) and number>0
                            and url=='https://'+repo+'/pull/'+str(number)):
                        pr={'prNumber':number,'prUrl':url,'prState':'DRAFT' if row.get('isDraft') else row.get('state','')}
            except (OSError,ValueError,TimeoutError,subprocess.SubprocessError):pass
            self.pr_cache[key]=(now,pr);self.pr_cache.move_to_end(key)
            while len(self.pr_cache)>128:self.pr_cache.popitem(last=False)
        else:pr=cached[1]
        return {**result,**pr}
