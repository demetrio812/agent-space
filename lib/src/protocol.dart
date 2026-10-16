import 'dart:convert';
import 'dart:typed_data';

import 'package:xterm/xterm.dart';

sealed class ObserveEvent {}

class TerminalFrame extends ObserveEvent {
  TerminalFrame(this.width, this.height, this.seq, this.full, this.bytes);
  final int width, height, seq;
  final bool full;
  final Uint8List bytes;
  Map<String, dynamic> toJson() => {
    'type': 'terminal.frame',
    'width': width,
    'height': height,
    'seq': seq,
    'full': full,
    'encoding': 'ansi',
    'bytes': base64Encode(bytes),
  };
}

class TerminalClosed extends ObserveEvent {
  TerminalClosed(this.reason);
  final String reason;
}

ObserveEvent parseObserveLine(String line) {
  try {
    if (line.length > 2 * 1024 * 1024 ||
        utf8.encode(line).length > 2 * 1024 * 1024) {
      throw const FormatException();
    }
    final j = jsonDecode(line);
    if (j is! Map) throw const FormatException();
    if (j['type'] == 'terminal.closed') {
      final reason = j['reason'] ?? 'Session closed.';
      if (reason is! String || reason.length > 1024) {
        throw const FormatException();
      }
      return TerminalClosed(reason);
    }
    if (j['type'] != 'terminal.frame' ||
        j['encoding'] != 'ansi' ||
        j['width'] is! int ||
        j['height'] is! int ||
        j['seq'] is! int ||
        j['full'] is! bool ||
        j['bytes'] is! String) {
      throw const FormatException();
    }
    final w = j['width'] as int, h = j['height'] as int, seq = j['seq'] as int;
    if (w < 1 ||
        w > 512 ||
        h < 1 ||
        h > 256 ||
        w * h > 65536 ||
        seq < 0 ||
        seq > 0x7fffffffffffffff) {
      throw const FormatException();
    }
    final encoded = j['bytes'] as String;
    if (encoded.length > ((1024 * 1024 + 2) ~/ 3) * 4) {
      throw const FormatException();
    }
    final bytes = base64Decode(encoded);
    if (bytes.length > 1024 * 1024 || base64Encode(bytes) != encoded) {
      throw const FormatException();
    }
    return TerminalFrame(w, h, seq, j['full'], bytes);
  } catch (_) {
    throw const FormatException('The terminal returned an invalid frame.');
  }
}

class FrameContinuityException extends FormatException {
  const FrameContinuityException()
    : super('Terminal frame continuity was lost. Refreshing the screen.');
}

class TerminalScreen {
  Terminal? _terminal;
  Sink<List<int>>? _decoder;
  int _lastSeq = -1;
  int get rows => _terminal?.viewHeight ?? 0;
  int get columns => _terminal?.viewWidth ?? 0;
  Terminal? get terminal => _terminal;
  String get text => _terminal?.buffer.getText() ?? '';
  int revision = 0;
  final List<TerminalFrame> _replay = [];
  int _replayBytes = 0;
  bool get canReplay => _replay.isNotEmpty && _replay.first.full;
  List<TerminalFrame> get replay => List.unmodifiable(_replay);
  void beginStream() {
    _lastSeq = -1;
    _decoder = null;
    _replay.clear();
    _replayBytes = 0;
  }

  void accept(TerminalFrame frame) {
    if (frame.seq <= _lastSeq ||
        (!frame.full &&
            (_lastSeq < 0 ||
                frame.seq != _lastSeq + 1 ||
                columns != frame.width ||
                rows != frame.height ||
                _decoder == null))) {
      throw const FrameContinuityException();
    }
    if (frame.full) {
      _terminal = Terminal(maxLines: 2000, reflowEnabled: false)
        ..resize(frame.width, frame.height);
      _decoder = const Utf8Decoder(allowMalformed: true)
          .startChunkedConversion(_TerminalTextSink(_terminal!));
      _replay.clear();
      _replayBytes = 0;
    }
    _decoder!.add(frame.bytes);
    _lastSeq = frame.seq;
    revision++;
    if (frame.full || canReplay) {
      _replay.add(frame);
      _replayBytes += frame.bytes.length;
      if (_replayBytes > 2 * 1024 * 1024 || _replay.length > 512) {
        _replay.clear();
        _replayBytes = 0;
      }
    }
  }

  List<String> get previewLines {
    final t = _terminal;
    if (t == null) return [];
    final start = (t.buffer.lines.length - t.viewHeight).clamp(
      0,
      t.buffer.lines.length,
    );
    final nonempty = <String>[];
    for (var i = start; i < t.buffer.lines.length; i++) {
      final line = t.buffer.lines[i].getText().trimRight();
      if (line.trim().isNotEmpty) {
        nonempty.add(line.length > 160 ? line.substring(0, 160) : line);
      }
    }
    return nonempty.length > 4
        ? nonempty.sublist(nonempty.length - 4)
        : nonempty;
  }
}

class _TerminalTextSink implements Sink<String> {
  _TerminalTextSink(this.terminal);
  final Terminal terminal;
  @override
  void add(String data) => terminal.write(data);
  @override
  void close() {}
}
