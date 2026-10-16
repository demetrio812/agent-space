"""Bounded bridge envelopes and dispatch certainty."""
import re
try:
    from .bootstrap import PROTOCOL, read_record, write_record
except ImportError:
    from bootstrap import PROTOCOL, read_record, write_record

ID = re.compile(r'^[1-9][0-9]{0,15}$')
IDENTITY = re.compile(r'^[A-Za-z0-9_.:@%+/][A-Za-z0-9_.:@%+/-]{0,255}$')
GENERATION = re.compile(r'^[0-9a-f]{64}$')
OPS = {'transfer': {'image.begin','image.chunk','image.finish','image.cancel','health'}, 'discovery': {'catalog','machines','health'},
       'input': {'input','send','rename','close','create','health'}, 'streams': {'observe','resize','scroll','click','cancel','health'}}


class BridgeRejected(Exception):
    def __init__(self, code, dispatched=False):
        super().__init__(code); self.code, self.dispatched = code, dispatched


class DeliveryUncertain(BridgeRejected):
    def __init__(self): super().__init__('delivery_uncertain', True)


def validate_request(row, nonce, lane):
    if (not isinstance(row, dict) or set(row) - {'type','protocol','nonce','lane','id','op','payload','route'}
            or row.get('type') != 'request' or row.get('protocol') != PROTOCOL
            or row.get('nonce') != nonce or row.get('lane') != lane
            or not isinstance(row.get('id'), str) or not ID.fullmatch(row['id'])
            or row.get('op') not in OPS[lane] or not isinstance(row.get('payload'), dict)):
        raise BridgeRejected('invalid_request')
    return row


def validate_route(route):
    if not isinstance(route, dict): raise BridgeRejected('invalid_request')
    for name in ('terminal','pane'):
        if not isinstance(route.get(name), str) or not IDENTITY.fullmatch(route[name]):
            raise BridgeRejected('invalid_request')
    if not isinstance(route.get('generation'), str) or not GENERATION.fullmatch(route['generation']):
        raise BridgeRejected('invalid_request')
    return route
