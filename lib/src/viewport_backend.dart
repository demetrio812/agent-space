part of 'backend.dart';

class _ViewportControl {
  _ViewportControl(this.cols, this.rows);
  int cols, rows;
  _Command? command;
  bool cancelled = false;
  void Function()? stop;
  void ensureActive() {
    if (cancelled) throw ConnectionFailure('Terminal viewport was cancelled.');
  }

  void bindStop(void Function() value) {
    stop = value;
    if (cancelled) value();
  }
}

mixin _ViewportSupport implements TerminalViewportBackend {
  final _viewportControls = <String, _ViewportControl>{};

  Stream<ObserveEvent> viewportStream(
    SessionInfo session,
    int cols,
    int rows,
    Future<_Command> Function(_ViewportControl) open,
  ) {
    if (!validViewport(cols, rows)) {
      throw ArgumentError('Invalid terminal dimensions.');
    }
    final view = _ViewportControl(cols, rows);
    _viewportControls[session.key.id] = view;
    return _observeCommand(
      () async {
        try {
          view.ensureActive();
          final command = await open(view);
          view.command = command;
          view.ensureActive();
          // A zoom may have changed while validation or connection setup was pending.
          await command.resize?.call(view.cols, view.rows);
          return _Command(command.stdout, command.stderr, command.exit, () {
            if (identical(_viewportControls[session.key.id], view)) {
              _viewportControls.remove(session.key.id);
            }
            command.stop();
          });
        } catch (_) {
          view.command?.stop();
          if (identical(_viewportControls[session.key.id], view)) {
            _viewportControls.remove(session.key.id);
          }
          rethrow;
        }
      },
      onCancel: () {
        view.cancelled = true;
        view.stop?.call();
        if (identical(_viewportControls[session.key.id], view)) {
          _viewportControls.remove(session.key.id);
        }
      },
    );
  }

  @override
  Future<void> resizeViewport(SessionInfo session, int cols, int rows) async {
    if (!validViewport(cols, rows)) {
      throw ArgumentError('Invalid terminal dimensions.');
    }
    final view = _viewportControls[session.key.id];
    if (view == null) {
      throw ConnectionFailure(
        'Terminal resize is unavailable. Reconnect the terminal.',
      );
    }
    view.cols = cols;
    view.rows = rows;
    await view.command?.resize?.call(cols, rows);
  }
}
