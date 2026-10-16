import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'backend_errors.dart';
import 'bridge_protocol.dart';
import 'image_attachments.dart';
import 'models.dart';
import 'protocol.dart';
import 'session_actions.dart';

abstract interface class BridgeConnection {
  Map<String, dynamic> get hello;
  Stream<Uint8List> get stdout;
  Stream<Uint8List> get stderr;
  Future<void> write(Uint8List bytes);
  Future<void> close();
}

typedef OpenBridge = Future<BridgeConnection> Function(BridgeLane lane);

class _Pending {
  _Pending(this.op);
  final String op;
  final done = Completer<Map<String, dynamic>>();
  bool submitted = false;
  Timer? timer;
  bool get input => op == 'input' || op == 'send' || op == 'click';
  bool get management => sessionManagementOperations.contains(op);
  bool get mutation => input || management;
}

class _Lane {
  _Lane(this.connection, this.kind)
    : protocol = BridgeProtocol(
        bridgeProtocol,
        connection.hello['nonce'] as String,
        kind,
      );
  final BridgeConnection connection;
  final BridgeLane kind;
  final BridgeProtocol protocol;
  final pending = <String, _Pending>{};
  final events = <String, void Function(Map<String, dynamic>)>{};
  final retiredEvents = <String>{};
  StreamSubscription? stdout, stderr;
  int counter = 0, errorBytes = 0;
  bool closed = false;
}

class _View {
  _View(this.route, this.cols, this.rows);
  final Map<String, dynamic> route;
  int? cols, rows;
  _Lane? lane;
  String? id;
  bool cancelled = false;
  bool cancelSent = false;
  int queued = 0;
  late StreamController<ObserveEvent> output;
}

class PersistentBridge {
  PersistentBridge(this.open);
  final OpenBridge open;
  final _lanes = <BridgeLane, _Lane>{};
  final _opening = <BridgeLane, Future<_Lane>>{};
  final _views = <String, _View>{};
  bool _closed = false;
  Future<_Lane> _lane(BridgeLane kind) async {
    if (_closed) throw ConnectionFailure('Connection closed.');
    final existing = _lanes[kind];
    if (existing != null && !existing.closed) return existing;
    final opening = _opening[kind];
    if (opening != null) return opening;
    final future = _open(kind);
    _opening[kind] = future;
    try {
      return await future;
    } finally {
      if (identical(_opening[kind], future)) _opening.remove(kind);
    }
  }

  Future<_Lane> _open(BridgeLane kind) async {
    final connection = await open(kind);
    try {
      if (_closed) throw ConnectionFailure('Connection closed.');
      validateBridgeHello(connection.hello, kind);
      final lane = _Lane(connection, kind);
      _lanes[kind] = lane;
      lane.stdout = decodeBridgeRecords(connection.stdout).listen(
        (row) => _accept(lane, row),
        onError: (Object error) => _fail(lane, error),
        onDone: () => _fail(lane, ConnectionFailure('Computer disconnected.')),
      );
      lane.stderr = connection.stderr.listen((chunk) {
        lane.errorBytes += chunk.length;
        if (lane.errorBytes > 65536) {
          _fail(
            lane,
            const FormatException(
              'Connection error output exceeded its limit.',
            ),
          );
        }
      }, onError: (Object error) => _fail(lane, error));
      return lane;
    } catch (_) {
      await connection.close();
      rethrow;
    }
  }

  void _fail(_Lane lane, Object error) {
    if (lane.closed) return;
    lane.closed = true;
    if (identical(_lanes[lane.kind], lane)) _lanes.remove(lane.kind);
    for (final pending in lane.pending.values) {
      pending.timer?.cancel();
      if (!pending.done.isCompleted) {
        pending.done.completeError(
          pending.mutation && pending.submitted ? DeliveryUncertain() : error,
        );
      }
    }
    lane.pending.clear();
    final handlers = lane.events.values.toList();
    lane.events.clear();
    for (final handler in handlers) {
      handler({'type': 'lane_error', 'error': error});
    }
    unawaited(lane.stdout?.cancel());
    unawaited(lane.stderr?.cancel());
    unawaited(lane.connection.close());
  }

  void _accept(_Lane lane, Map<String, dynamic> row) {
    if (lane.closed) return;
    try {
      lane.protocol.validate(row);
      final id = row['id'] as String;
      if (row['type'] == 'event') {
        final handler = lane.events[id];
        if (handler == null && lane.retiredEvents.contains(id)) return;
        if (handler == null ||
            row['value'] is! Map ||
            row['event'] is! String) {
          throw const FormatException('Unexpected connection event.');
        }
        handler(row);
        return;
      }
      final pending = lane.pending[id];
      if (pending == null || row['ok'] is! bool) {
        throw const FormatException('Unexpected connection acknowledgement.');
      }
      if (row['ok'] == false) {
        if (row['error'] is! Map<String, dynamic>) {
          throw const FormatException('Invalid connection rejection.');
        }
        final error = bridgeRejection(
          row['error'] as Map<String, dynamic>,
          input: pending.mutation,
        );
        lane.pending.remove(id);
        pending.timer?.cancel();
        pending.done.completeError(error);
        return;
      }
      if (row['result'] is! Map<String, dynamic> ||
          (pending.input && (row['result'] as Map)['sent'] != true) ||
          (pending.management && (row['result'] as Map)['applied'] != true)) {
        throw const FormatException('Missing input acknowledgement.');
      }
      lane.pending.remove(id);
      pending.timer?.cancel();
      pending.done.complete(row['result'] as Map<String, dynamic>);
    } catch (error) {
      _fail(lane, error);
    }
  }

  Future<Map<String, dynamic>> request(
    BridgeLane lane,
    String op,
    Map<String, dynamic> payload, {
    Map<String, dynamic>? route,
    Duration timeout = const Duration(seconds: 6),
    bool Function()? cancelled,
  }) => _request(
    lane,
    op,
    payload,
    route: route,
    timeout: timeout,
    cancelled: cancelled,
  );

  Future<Map<String, dynamic>> _request(
    BridgeLane kind,
    String op,
    Map<String, dynamic> payload, {
    Map<String, dynamic>? route,
    Duration timeout = const Duration(seconds: 6),
    void Function(Map<String, dynamic>)? events,
    void Function(_Lane, String)? onId,
    bool Function()? cancelled,
  }) async {
    final allowed = switch (kind) {
      BridgeLane.transfer => const {
        'image.begin',
        'image.chunk',
        'image.finish',
        'image.cancel',
        'health',
      },
      BridgeLane.discovery => const {'catalog', 'machines', 'health'},
      BridgeLane.input => const {
        'input',
        'send',
        'rename',
        'close',
        'create',
        'health',
      },
      BridgeLane.streams => const {
        'observe',
        'resize',
        'scroll',
        'click',
        'cancel',
        'health',
      },
    };
    if (!allowed.contains(op)) {
      throw ArgumentError('Unsupported connection action.');
    }
    if (op.startsWith('image.')) {
      validateImagePayload(op, payload);
      validateSessionActionRoute('rename', route);
    }
    if (sessionManagementOperations.contains(op)) {
      validateSessionAction(op, payload);
      validateSessionActionRoute(op, route);
    }
    if (op == 'input') {
      final input = switch (payload) {
        {'text': final String text} when payload.length == 1 =>
          TerminalInput.text(text),
        {'paste': final String text} when payload.length == 1 =>
          TerminalInput.paste(text),
        {'keys': final List keys}
            when payload.length == 1 && keys.every((k) => k is String) =>
          TerminalInput.keys(keys.cast<String>()),
        _ => throw ArgumentError('Invalid terminal input.'),
      };
      if (input.validationError != null) {
        throw ArgumentError(input.validationError);
      }
    }
    if (op == 'send' &&
        (payload.length != 1 ||
            payload['text'] is! String ||
            validateInput(payload['text'] as String) != null)) {
      throw ArgumentError('Invalid reviewed message.');
    }
    final lane = await _lane(kind);
    if (_closed || lane.closed || cancelled?.call() == true) {
      throw ConnectionFailure('Connection closed.');
    }
    if (lane.pending.length >= 128) {
      throw ConnectionFailure('Connection is busy.');
    }
    final id = '${++lane.counter}';
    final pending = _Pending(op);
    final wire = encodeBridgeRecord({
      'type': 'request',
      'protocol': bridgeProtocol,
      'nonce': lane.protocol.nonce,
      'lane': kind.name,
      'id': id,
      'op': op,
      'payload': payload,
      'route': ?route,
    });
    lane.pending[id] = pending;
    if (events != null) lane.events[id] = events;
    onId?.call(lane, id);
    pending.timer = Timer(
      timeout,
      () => _fail(lane, ConnectionFailure('Computer response timed out.')),
    );
    // Attach the error listener before write can synchronously fail the lane.
    final result = pending.done.future;
    try {
      pending.submitted = true;
      final writing = lane.connection.write(wire);
      unawaited(
        writing.catchError((Object error) {
          _fail(lane, error);
        }),
      );
      return await result;
    } finally {
      if (op != 'observe') lane.events.remove(id);
    }
  }

  Stream<Map<String, dynamic>> discover(
    int epoch,
    Set<String> priorityMachines,
  ) {
    var cancelled = false;
    late StreamController<Map<String, dynamic>> controller;
    controller = StreamController(
      onListen: () {
        unawaited(() async {
          try {
            await _request(
              BridgeLane.discovery,
              'catalog',
              {
                'epoch': epoch,
                'priorityMachines': priorityMachines.take(16).toList(),
              },
              timeout: const Duration(minutes: 3),
              cancelled: () => cancelled,
              events: (row) {
                if (cancelled || controller.isClosed) return;
                if (row['type'] == 'lane_error') {
                  controller.addError(row['error'] as Object);
                  return;
                }
                if (row['epoch'] != epoch) return;
                controller.add(row);
              },
            );
          } catch (error) {
            if (!cancelled && !controller.isClosed) controller.addError(error);
          } finally {
            if (!controller.isClosed) unawaited(controller.close());
          }
        }());
      },
      onCancel: () {
        cancelled = true;
      },
    );
    return controller.stream;
  }

  String _routeKey(Map<String, dynamic> route) => jsonEncode([
    route['machine'],
    route['session'],
    route['generation'],
    route['terminal'],
    route['pane'],
  ]);
  Stream<ObserveEvent> observe(
    Map<String, dynamic> route, {
    int? cols,
    int? rows,
  }) {
    if ((cols == null) != (rows == null) ||
        (cols != null && !_validViewport(cols, rows!))) {
      throw ArgumentError('Invalid terminal dimensions.');
    }
    final view = _View(route, cols, rows);
    final key = _routeKey(route);
    if (cols != null) _views[key] = view;
    view.output = StreamController<ObserveEvent>(
      sync: true,
      onListen: () {
        unawaited(() async {
          try {
            await _request(
              BridgeLane.streams,
              'observe',
              {
                'mode': cols == null ? 'preview' : 'viewport',
                'cols': view.cols ?? 120,
                'rows': view.rows ?? 40,
              },
              route: route,
              timeout: const Duration(seconds: 30),
              cancelled: () => view.cancelled,
              onId: (lane, id) {
                view.lane = lane;
                view.id = id;
              },
              events: (row) {
                if (view.cancelled || view.output.isClosed) return;
                if (row['type'] == 'lane_error') {
                  view.output.addError(row['error'] as Object);
                  unawaited(view.output.close());
                  return;
                }
                if (view.output.isPaused && ++view.queued > 4) {
                  view.output.addError(
                    ConnectionFailure('Terminal output exceeded its buffer.'),
                  );
                  unawaited(view.output.close());
                  unawaited(_cancelView(view));
                  return;
                }
                try {
                  if (row['event'] == 'frame') {
                    final event = parseObserveLine(jsonEncode(row['value']));
                    view.output.add(event);
                    if (event is TerminalClosed) unawaited(view.output.close());
                  } else if (row['event'] == 'closed') {
                    view.output.add(TerminalClosed('Computer disconnected.'));
                    unawaited(view.output.close());
                  } else {
                    throw const FormatException('Invalid terminal event.');
                  }
                } catch (error) {
                  view.output.addError(error);
                  unawaited(view.output.close());
                  unawaited(_cancelView(view));
                }
              },
            );
            if (view.cancelled) {
              await _cancelView(view);
              return;
            }
            if (view.cols != null && (view.cols != cols || view.rows != rows)) {
              await resize(route, view.cols!, view.rows!);
            }
          } catch (error) {
            if (!view.cancelled && !view.output.isClosed) {
              view.output.addError(error);
              unawaited(view.output.close());
            }
          }
        }());
      },
      onResume: () {
        view.queued = 0;
      },
      onCancel: () => _cancelView(view),
    );
    return view.output.stream;
  }

  Future<void> _cancelView(_View view) async {
    view.cancelled = true;
    final key = _routeKey(view.route);
    if (identical(_views[key], view)) _views.remove(key);
    final lane = view.lane;
    final id = view.id;
    if (lane == null || id == null || lane.closed || _closed) return;
    if (view.cancelSent) return;
    view.cancelSent = true;
    // Keep a tombstone event handler until cancel is acknowledged, so a frame
    // already in flight cannot retire the entire streams lane.
    try {
      await _request(BridgeLane.streams, 'cancel', {
        'subscription': id,
      }, timeout: const Duration(seconds: 6));
    } catch (_) {
      /* Closed lanes already own cleanup. */
    }
    lane.events.remove(id);
    lane.retiredEvents.add(id);
    if (lane.retiredEvents.length > 128) {
      lane.retiredEvents.remove(lane.retiredEvents.first);
    }
  }

  Future<void> resize(Map<String, dynamic> route, int cols, int rows) async {
    if (!_validViewport(cols, rows)) {
      throw ArgumentError('Invalid terminal dimensions.');
    }
    final view = _views[_routeKey(route)];
    if (view == null || view.cancelled) {
      throw ConnectionFailure('Terminal resize is unavailable.');
    }
    view.cols = cols;
    view.rows = rows;
    if (view.id == null) return;
    await _request(BridgeLane.streams, 'resize', {
      'subscription': view.id,
      'cols': cols,
      'rows': rows,
    });
  }

  Future<void> scroll(Map<String, dynamic> route, int lines) async {
    if (lines == 0 || lines.abs() > 40) {
      throw ArgumentError('Invalid terminal scroll.');
    }
    final view = _views[_routeKey(route)];
    if (view == null || view.cancelled || view.id == null) {
      throw ConnectionFailure('Terminal scrolling is unavailable.');
    }
    final result = await _request(
      BridgeLane.streams,
      'scroll',
      {
        'subscription': view.id,
        'direction': lines < 0 ? 'up' : 'down',
        'steps': lines.abs(),
      },
      cancelled: () =>
          view.cancelled || !identical(_views[_routeKey(route)], view),
    );
    if (result['scrolled'] != true) {
      throw ConnectionFailure('Terminal scroll was not accepted.');
    }
  }

  Future<void> click(
    Map<String, dynamic> route,
    int column,
    int row, {
    Duration timeout = const Duration(seconds: 6),
  }) async {
    if (column < 0 || column >= 512 || row < 0 || row >= 256) {
      throw ArgumentError('Invalid terminal click.');
    }
    final view = _views[_routeKey(route)];
    if (view == null || view.cancelled || view.id == null) {
      throw ConnectionFailure('Terminal click is unavailable.');
    }
    await _request(
      BridgeLane.streams,
      'click',
      {'subscription': view.id, 'column': column, 'row': row},
      timeout: timeout,
      cancelled: () =>
          view.cancelled || !identical(_views[_routeKey(route)], view),
    );
  }

  bool _validViewport(int cols, int rows) =>
      cols >= 1 &&
      cols <= 512 &&
      rows >= 1 &&
      rows <= 256 &&
      cols * rows <= 65536;
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final lane in _lanes.values.toList()) {
      _fail(lane, ConnectionFailure('Connection closed.'));
    }
    for (final view in _views.values) {
      view.cancelled = true;
      unawaited(view.output.close());
    }
    _views.clear();
  }
}
