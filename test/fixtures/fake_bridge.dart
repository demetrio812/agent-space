import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agentspace/src/bridge_protocol.dart';
import 'package:agentspace/src/persistent_bridge.dart';

const fixtureRoute = <String, dynamic>{
  'machine': 'gateway',
  'session': 'default',
  'targetHash':
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  'generation':
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  'terminal': 't1',
  'pane': 'p1',
};

class FakeBridge {
  final openedLanes = <BridgeLane>[];
  final startingLanes = <BridgeLane>[];
  final closedLanes = <BridgeLane>[];
  final sentInputs = <Map<String, dynamic>>[];
  final requests = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> computerEvents = [];
  final held = <BridgeLane>{};
  final connections = <_Connection>[];
  Completer<void>? opening;
  Map<String, dynamic>? Function(Map<String, dynamic>)? resultFor;
  String? inputFault;
  String? managementFault;
  final managementRequests = <Map<String, dynamic>>[];
  void hold(BridgeLane lane) => held.add(lane);
  void release(BridgeLane lane) {
    held.remove(lane);
    for (final connection in connections.where((c) => c.lane == lane)) {
      for (final row in connection.waiting.toList()) {
        connection.reply(row);
      }
      connection.waiting.clear();
    }
  }

  void lostAck() => inputFault = 'lost';
  void lateAckFromRetiredLane() => inputFault = 'nonce';
  void malformedAck() => inputFault = 'malformed';
  void lateFrame(String id) {
    final connection = connections.lastWhere(
      (c) => c.lane == BridgeLane.streams,
    );
    connection.send({
      'type': 'event',
      'nonce': connection.hello['nonce'],
      'lane': 'streams',
      'id': id,
      'event': 'frame',
      'value': {
        'type': 'terminal.frame',
        'encoding': 'ansi',
        'width': 90,
        'height': 30,
        'seq': 0,
        'full': true,
        'bytes': 'Zml4dHVyZQ==',
      },
    });
  }

  Future<BridgeConnection> open(BridgeLane lane) async {
    startingLanes.add(lane);
    await opening?.future;
    openedLanes.add(lane);
    final connection = _Connection(this, lane, connections.length + 1);
    connections.add(connection);
    return connection;
  }
}

class _Connection implements BridgeConnection {
  _Connection(this.owner, this.lane, int index)
    : hello = {
        'type': 'hello',
        'protocol': 'agentspace-bridge-v2',
        'digest':
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'nonce': index.toRadixString(16).padLeft(32, '0'),
        'lane': lane.name,
        'generation': fixtureRoute['generation'],
        'capabilities': {
          'catalog': true,
          'input': true,
          'network': true,
          'observe': true,
          'viewport': true,
        },
      };
  final FakeBridge owner;
  final BridgeLane lane;
  @override
  final Map<String, dynamic> hello;
  final out = StreamController<Uint8List>();
  final err = StreamController<Uint8List>();
  final waiting = <Map<String, dynamic>>[];
  bool closed = false;
  @override
  Stream<Uint8List> get stdout => out.stream;
  @override
  Stream<Uint8List> get stderr => err.stream;
  @override
  Future<void> write(Uint8List bytes) async {
    if (closed) throw StateError('Closed fixture');
    final row = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(bytes)) as Map,
    );
    owner.requests.add(row);
    if (row['op'] == 'input' || row['op'] == 'send' || row['op'] == 'click') {
      owner.sentInputs.add(row);
    }
    if (owner.held.contains(lane)) {
      waiting.add(row);
      return;
    }
    if (row['op'] == 'input' && owner.inputFault == 'partial') {
      throw StateError('Partial write');
    }
    reply(row);
  }

  void send(Map<String, dynamic> row) {
    if (!closed) {
      out.add(Uint8List.fromList(utf8.encode('${jsonEncode(row)}\n')));
    }
  }

  void reply(Map<String, dynamic> row) {
    if (closed) return;
    final management = const {
      'rename',
      'close',
      'create',
      'workspace.create',
      'workspace.rename',
      'workspace.close',
    }.contains(row['op']);
    if (management) owner.managementRequests.add(row);
    if (management && owner.managementFault == 'lost') {
      unawaited(out.close());
      return;
    }
    final danger =
        row['op'] == 'input' || row['op'] == 'send' || row['op'] == 'click';
    if (danger && owner.inputFault == 'lost') return;
    final reply = <String, dynamic>{
      'type': 'reply',
      'nonce': hello['nonce'],
      'lane': lane.name,
      'id': row['id'],
      'ok': true,
      'result': {
        'sent': true,
        'alive': true,
        'scrolled': true,
        'subscription': row['id'],
      },
    };
    final custom = owner.resultFor?.call(row);
    if (custom != null) reply['result'] = custom;
    if (danger) {
      switch (owner.inputFault) {
        case 'nonce':
          reply['nonce'] = 'ffffffffffffffffffffffffffffffff';
        case 'id':
          reply['id'] = '999';
        case 'malformed':
          reply['result'] = {'sent': false};
        case 'rejected':
          reply['ok'] = false;
          reply['error'] = {'code': 'route_changed', 'dispatched': false};
      }
    }
    if (management) {
      final route = row['route'] as Map, payload = row['payload'] as Map;
      final computer = owner.computerEvents
          .where((c) => c['machine'] == route['machine'])
          .single;
      final agents =
          (computer['catalog']['catalog']['result']['agents'] as List);
      final result = <String, dynamic>{'applied': true};
      if (row['op'] == 'workspace.rename') {
        ((computer['catalog']['workspaces'] as List).singleWhere(
          (w) => w['workspace_id'] == payload['workspace'],
        ) as Map)['label'] = payload['title'];
      } else if (row['op'] == 'workspace.close') {
        (computer['catalog']['workspaces'] as List).removeWhere(
          (w) => w['workspace_id'] == payload['workspace'],
        );
        agents.removeWhere((a) => a['workspace_id'] == payload['workspace']);
      } else if (row['op'] == 'rename') {
        (agents.singleWhere((a) => a['terminal_id'] == route['terminal'])
                as Map)['title'] =
            payload['title'];
      } else if (row['op'] == 'close') {
        agents.removeWhere((a) => a['terminal_id'] == route['terminal']);
      } else {
        final workspace = row['op'] == 'workspace.create'
            ? 'new-workspace'
            : payload['workspace'];
        if (row['op'] == 'workspace.create') {
          (computer['catalog']['workspaces'] as List).add({
            'workspace_id': workspace,
            'label': payload['title'],
          });
        }
        agents.add({
          'terminal_id': 'new-terminal',
          'pane_id': 'new-pane',
          'workspace_id': workspace,
          'tab_id': 'new-tab',
          'title': payload['title'] == '' ? 'Shell' : payload['title'],
          'agent': null,
          'agent_status': 'idle',
        });
        result['created'] = {
          'terminal': 'new-terminal',
          'pane': 'new-pane',
          'workspace': workspace,
          'tab': 'new-tab',
        };
      }
      reply['result'] = result;
      if (owner.managementFault == 'wrong-created') {
        result['created'] = {
          'terminal': 't1',
          'pane': 'p1',
          'workspace': 'other',
          'tab': 'other',
        };
      }
    }
    if (row['op'] == 'catalog') {
      for (final computer
          in owner.computerEvents.isEmpty
              ? [
                  {'machine': 'gateway'},
                ]
              : owner.computerEvents) {
        send({
          'type': 'event',
          'nonce': hello['nonce'],
          'lane': lane.name,
          'id': row['id'],
          'event': 'computer',
          'epoch': row['payload']['epoch'],
          'value': computer,
        });
      }
    }
    send(reply);
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    owner.closedLanes.add(lane);
    unawaited(out.close());
    unawaited(err.close());
  }
}
