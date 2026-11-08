"""Experimental Claude transcript projection, bound only by Herdr's native ID.

No paths come from the client. This reads a local record; it never starts Claude.
The internal JSONL format is deliberately isolated behind this adapter.
"""
import json
import os
from pathlib import Path
import re
import stat
import threading
import time

try:
    from .protocol import BridgeRejected
    from .gate_rules import validate_send
except ImportError:
    from protocol import BridgeRejected
    from gate_rules import validate_send

UUID = re.compile(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
MAX_FILE = 256 * 1024 * 1024
MAX_LINE = 8 * 1024 * 1024
PAGE_BYTES = 1024 * 1024


def valid_id(value):
    return isinstance(value, str) and UUID.fullmatch(value) is not None


def binding(row):
    ref = row.get('agent_session')
    if (row.get('agent') != 'claude' or not isinstance(ref, dict)
            or ref.get('agent') != 'claude' or ref.get('kind') != 'id'
            or not valid_id(ref.get('value'))):
        return ''
    return ref['value'].lower()


def validate_payload(op, payload):
    fields = {'session', 'before'} if op == 'chat.read' else {'session', 'text'}
    if not isinstance(payload, dict) or set(payload) != fields:
        raise BridgeRejected('invalid_request')
    if op == 'chat.read':
        if any(payload[k] != '' and not valid_id(payload[k]) for k in fields):
            raise BridgeRejected('invalid_request')
    else:
        if not valid_id(payload['session']): raise BridgeRejected('invalid_request')
        try: validate_send(payload['text'])
        except (ValueError, TypeError, UnicodeError): raise BridgeRejected('invalid_request')
        if payload['text'].lstrip().startswith(('/', '!')): raise BridgeRejected('unsupported')


def encoded(value):
    return len(json.dumps(value, ensure_ascii=True, separators=(',', ':')).encode())


def bounded_message(value, check=lambda:None):
    check()
    if encoded(value) <= PAGE_BYTES // 2: return value
    value = {**value, 'truncated': True}
    original = value['text']; low, high = 0, len(original)
    while low < high:
        check()
        middle = (low + high + 1) // 2
        value['text'] = original[:middle]
        if encoded(value) <= PAGE_BYTES // 2: low = middle
        else: high = middle - 1
    value['text'] = original[:low]
    return value


class TranscriptProblem(Exception):
    pass


class ConversationReader:
    def __init__(self, api, projects=None):
        self.api = api
        configured = Path(os.environ.get('CLAUDE_CONFIG_DIR', str(Path.home()/'.claude')))
        self.projects = Path(projects) if projects is not None else configured/'projects'
        self._cache = {}; self._lock = threading.RLock()

    def _open(self, session):
        found = []
        try:
            # The root is local configuration, not a requested filesystem path.
            root = os.open(self.projects.resolve(strict=True), os.O_RDONLY | os.O_DIRECTORY)
        except OSError: raise TranscriptProblem('missing_transcript')
        try:
            folders = os.listdir(root)
            if len(folders) > 4096: raise TranscriptProblem('transcript_limit')
            for name in folders:
                try: folder = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root)
                except OSError: continue
                try:
                    if os.fstat(folder).st_uid != os.getuid(): continue
                    try: fd = os.open(session+'.jsonl', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=folder)
                    except OSError: continue
                    info = os.fstat(fd)
                    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                        os.close(fd); continue
                    found.append(fd)
                finally: os.close(folder)
            if len(found) != 1:
                raise TranscriptProblem('ambiguous_transcript' if found else 'missing_transcript')
            return found.pop()
        finally:
            os.close(root)
            for fd in found: os.close(fd)

    def _load(self, session):
        fd = self._open(session)
        with os.fdopen(fd, 'rb') as source:
            info = os.fstat(source.fileno())
            if info.st_size > MAX_FILE: raise TranscriptProblem('transcript_limit')
            stamp = (session, info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)
            with self._lock:
                if stamp in self._cache: return self._cache[stamp]
            deadline = time.monotonic()+4; nodes = {}; commands = set(); leaf = None; total = 0
            def check():
                if time.monotonic() > deadline: raise TranscriptProblem('transcript_limit')
            while True:
                check()
                line = source.readline(MAX_LINE+1)
                if not line: break
                total += len(line)
                if total > MAX_FILE or len(line) > MAX_LINE: raise TranscriptProblem('transcript_limit')
                if not line.endswith(b'\n'): break  # A live writer has not committed this row yet.
                try: row = json.loads(line)
                except (ValueError, UnicodeError, RecursionError): raise TranscriptProblem('unsupported_transcript')
                if not isinstance(row, dict): raise TranscriptProblem('unsupported_transcript')
                identifier = row.get('uuid')
                if not valid_id(identifier): continue
                parent = row.get('parentUuid')
                if row.get('type')=='system' and row.get('subtype')=='compact_boundary' and parent is None:
                    # Prefer the exact known branch. A forward logical parent
                    # may instead belong to the preserved segment rooted here;
                    # fall back to the active leaf to avoid that cycle.
                    logical = row.get('logicalParentUuid')
                    parent = logical if valid_id(logical) and logical in nodes else leaf
                if parent is not None and not valid_id(parent): raise TranscriptProblem('unsupported_transcript')
                message = row.get('message'); projection = None
                role = row.get('type')
                content = message.get('content') if isinstance(message, dict) else None
                # Origin is a CLI discriminator; command output additionally needs
                # a command parent so ordinary user-authored XML stays visible.
                text = content if isinstance(content, str) else None
                if isinstance(content, list) and all(isinstance(b, dict) and b.get('type')=='text' and isinstance(b.get('text'), str) for b in content):
                    text = '\n\n'.join(b['text'] for b in content)
                if role=='user' and text and text.lstrip().startswith('<command-name>'):
                    commands.add(identifier)
                origin = row.get('origin')
                internal = role=='user' and (
                    isinstance(origin, dict) and origin.get('kind')=='task-notification' or
                    parent in commands and text is not None and
                    re.fullmatch(r'\s*<local-command-stdout>[\s\S]*</local-command-stdout>\s*', text) is not None)
                visible = not internal and not row.get('isSidechain') and not row.get('isMeta') and not row.get('isCompactSummary')
                if visible and role in ('user', 'assistant'):
                    if not isinstance(message, dict) or 'content' not in message:
                        raise TranscriptProblem('unsupported_transcript')
                    content = message['content']
                    if isinstance(content, str): content = [{'type':'text', 'text':content}]
                    if not isinstance(content, list): raise TranscriptProblem('unsupported_transcript')
                    texts=[]; tools=[]
                    for block in content:
                        if not isinstance(block, dict): raise TranscriptProblem('unsupported_transcript')
                        if block.get('type')=='text' and isinstance(block.get('text'), str): texts.append(block['text'])
                        elif block.get('type')=='image': texts.append('[Image]')
                        elif block.get('type')=='tool_use' and isinstance(block.get('name'), str):
                            name=block['name'][:64]
                            if name.isprintable(): tools.append(name)
                        elif block.get('type') not in ('tool_result','thinking','redacted_thinking'):
                            raise TranscriptProblem('unsupported_transcript')
                    projection={'id':identifier, 'role':role, 'text':'\n\n'.join(texts), 'tools':tools[:32],
                                'truncated':False, '_api':message.get('id'), '_block':row.get('apiBlockIndex')}
                elif visible and role=='system' and row.get('subtype')=='compact_boundary':
                    projection={'id':identifier,'role':'system','text':'Conversation compacted','tools':[], 'truncated':False}
                nodes[identifier]=(parent, projection)
                if visible and (role in ('user','assistant') or role=='system' and row.get('subtype')=='compact_boundary'): leaf=identifier
                if len(nodes)>500000: raise TranscriptProblem('transcript_limit')
            chain=[]; seen=set()
            while leaf in nodes:
                check()
                if leaf in seen: raise TranscriptProblem('unsupported_transcript')
                seen.add(leaf)
                parent, projection=nodes[leaf]
                if projection is not None: chain.append(projection)
                leaf=parent
            chain.reverse(); messages=[]; group=[]
            def flush():
                if not group: return
                first=group[0]; parts={}
                for entry in group:
                    check()
                    index=entry.get('_block')
                    # Newer CLI writes one record per API block; older CLI writes
                    # the cumulative message, which replaces previous content.
                    parts[index if type(index) is int else 0]=entry
                ordered=[parts[k] for k in sorted(parts)]
                value={k:first[k] for k in ('id','role','text','tools','truncated')}
                value['text']='\n\n'.join(e['text'] for e in ordered if e['text'])
                value['tools']=[name for e in ordered for name in e['tools']][:32]
                if value['text'] or value['tools']: messages.append(bounded_message(value, check))
                group.clear()
            for entry in chain:
                check()
                if group and not (entry['role']=='assistant' and entry.get('_api') and entry.get('_api')==group[0].get('_api')): flush()
                group.append(entry)
            flush()
            # Keep only small projections cached; never retain raw tool output.
            size = 0
            for item in messages:
                check()
                size += encoded(item)
            check()
            if size<=8*1024*1024:
                with self._lock:
                    if len(self._cache)>=2: self._cache.clear()
                    self._cache[stamp]=messages
            return messages

    def read(self, route, payload):
        validate_payload('chat.read', payload)
        current=self.api.member(route); session=binding(current)
        def unavailable(status):
            return {'session':session, 'status':status, 'messages':[], 'before':'', 'hasEarlier':False, 'canSend':False}
        if not session: return unavailable('unbound')
        if payload['session'] and session != payload['session'].lower(): return unavailable('session_changed')
        try: messages=self._load(session)
        except (TranscriptProblem, OSError) as error:
            return unavailable(str(error) if isinstance(error,TranscriptProblem) else 'missing_transcript')
        refreshed=self.api.member(route)
        if binding(refreshed)!=session: return unavailable('session_changed')
        stop=len(messages)
        if payload['before']:
            stop=next((i for i,m in enumerate(messages) if m['id']==payload['before']), -1)
            if stop<0: return unavailable('session_changed')
        result=[]; used=1024
        for entry in reversed(messages[:stop]):
            size=encoded(entry)
            if len(result)>=60 or used+size>PAGE_BYTES: break
            result.append(entry); used+=size
        result.reverse()
        return {'session':session,'status':'available','messages':result,
                'before':result[0]['id'] if result else '', 'hasEarlier':len(result)<stop,
                'canSend':refreshed.get('agent_status') in ('idle','done') and refreshed.get('interactive_ready') is not False}

    def send(self, route, payload, cancelled=lambda:False):
        validate_payload('chat.send', payload)
        def guard(member):
            if (binding(member)!=payload['session'].lower() or member.get('agent_status') not in ('idle','done')
                    or member.get('interactive_ready') is False):
                raise BridgeRejected('unsupported')
        return self.api.dispatch(route, {'text':payload['text']}, reviewed=True, cancelled=cancelled, guard=guard)
