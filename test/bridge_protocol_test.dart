import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/bridge_protocol.dart';

void main() {
  test(
    'fragmented UTF-8 and multiple records preserve literal newline',
    () async {
      final rows = [
        {'text': 'café\n世界'},
        {'text': 'second'},
      ];
      final raw = utf8.encode('${rows.map(jsonEncode).join('\n')}\n');
      expect(
        await decodeBridgeRecords(Stream.fromIterable(raw.map((b) => [b])))
            .toList(),
        rows,
      );
    },
  );
  test(
    'unterminated oversized records fail before unlimited buffering',
    () async {
      await expectLater(
        decodeBridgeRecords(Stream.value(List.filled(2 * 1024 * 1024 + 1, 120)))
            .toList(),
        throwsA(isA<FormatException>()),
      );
    },
  );
  test(
    'duplicate correlation fields, bad UTF-8 and incomplete JSON fail',
    () async {
      for (final raw in [
        utf8.encode('{"id":"1","id":"2"}\n'),
        [123, 34, 120, 34, 58, 34, 255, 34, 125, 10],
        utf8.encode('{"id":"1"}'),
      ]) {
        await expectLater(
          decodeBridgeRecords(Stream.value(raw)).toList(),
          throwsA(isA<FormatException>()),
        );
      }
    },
  );
}
