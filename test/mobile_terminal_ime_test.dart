import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/custom_text_edit.dart';

void main() {
  late FocusNode focus;
  late List<String> sent;
  late List<String?> previews;
  late CustomTextEditState client;
  Future<void> mount(WidgetTester tester) async {
    focus = FocusNode();
    sent = [];
    previews = [];
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: CustomTextEdit(
          focusNode: focus,
          deleteDetection: true,
          onInsert: (text) => sent.add(text),
          onDelete: () => sent.add('<backspace>'),
          onComposing: previews.add,
          onAction: (_) {},
          onKeyEvent: (_, _) => KeyEventResult.ignored,
          child: const SizedBox(width: 300, height: 300),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    client = tester.state(find.byType(CustomTextEdit));
    expect(tester.testTextInput.setClientArgs!['enableDeltaModel'], isTrue);
    expect(
      client,
      isA<DeltaTextInputClient>(),
      reason: 'Native queued edits need deltas, not repeated full values.',
    );
  }

  void edits(List<TextEditingDelta> deltas) =>
      (client as DeltaTextInputClient).updateEditingValueWithDeltas(deltas);
  TextEditingDelta insert(
    String old,
    String text, {
    TextRange composing = TextRange.empty,
  }) => TextEditingDeltaInsertion(
    oldText: old,
    textInserted: text,
    insertionOffset: old.length,
    selection: TextSelection.collapsed(offset: old.length + text.length),
    composing: composing,
  );
  testWidgets(
    'queued iOS prefix updates send native exactly once, including repeats',
    (tester) async {
      await mount(tester);
      var old = '  ';
      final deltas = <TextEditingDelta>[];
      for (final ch in 'nativeaaaa'.split('')) {
        deltas.add(insert(old, ch));
        old += ch;
      }
      edits(deltas);
      expect(sent.join(), 'nativeaaaa');
      edits([insert('  ', 'a'), insert('  ', 'a')]);
      expect(sent.join(), 'nativeaaaaaa');
    },
  );
  testWidgets(
    'software deletion uses sentinels and one grapheme per backspace',
    (tester) async {
      await mount(tester);
      edits([
        const TextEditingDeltaDeletion(
          oldText: '  ',
          deletedRange: TextRange(start: 1, end: 2),
          selection: TextSelection.collapsed(offset: 1),
          composing: TextRange.empty,
        ),
        const TextEditingDeltaDeletion(
          oldText: '  ',
          deletedRange: TextRange(start: 1, end: 2),
          selection: TextSelection.collapsed(offset: 1),
          composing: TextRange.empty,
        ),
        const TextEditingDeltaDeletion(
          oldText: '  👩‍💻',
          deletedRange: TextRange(start: 2, end: 7),
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange.empty,
        ),
      ]);
      expect(sent, ['<backspace>', '<backspace>', '<backspace>']);
    },
  );
  testWidgets(
    'composition commits once on non-text update and cancellation sends nothing',
    (tester) async {
      await mount(tester);
      edits([insert('  ', '日', composing: const TextRange(start: 2, end: 3))]);
      expect(sent, isEmpty);
      edits([
        const TextEditingDeltaNonTextUpdate(
          oldText: '  日',
          selection: TextSelection.collapsed(offset: 3),
          composing: TextRange.empty,
        ),
      ]);
      expect(sent, ['日']);
      sent.clear();
      edits([insert('  ', '仮', composing: const TextRange(start: 2, end: 3))]);
      edits([
        const TextEditingDeltaDeletion(
          oldText: '  仮',
          deletedRange: TextRange(start: 2, end: 3),
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange.empty,
        ),
      ]);
      expect(sent, isEmpty);
    },
  );
  testWidgets('replacement and multiline paste preserve literal input', (
    tester,
  ) async {
    await mount(tester);
    edits([
      const TextEditingDeltaReplacement(
        oldText: '  teh',
        replacementText: 'the',
        replacedRange: TextRange(start: 2, end: 5),
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange.empty,
      ),
    ]);
    expect(sent, ['<backspace>', '<backspace>', '<backspace>', 'the']);
    sent.clear();
    edits([insert('  ', 'first\nsecond')]);
    expect(sent, ['first\nsecond']);
  });
  testWidgets(
    'losing focus discards a pending composition before a new input connection',
    (tester) async {
      await mount(tester);
      edits([insert('  ', '仮', composing: const TextRange(start: 2, end: 3))]);
      expect(previews.last, '仮');
      focus.unfocus();
      await tester.pump();
      expect(previews.last, isNull);
      focus.requestFocus();
      await tester.pump();
      edits([insert('  ', 'x')]);
      expect(sent, ['x']);
    },
  );
  testWidgets('legacy composition preview clears when focus is lost', (
    tester,
  ) async {
    await mount(tester);
    client.updateEditingValue(
      const TextEditingValue(
        text: '  仮',
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 2, end: 3),
      ),
    );
    expect(previews.last, '仮');
    focus.unfocus();
    await tester.pump();
    expect(previews.last, isNull);
    expect(sent, isEmpty);
  });
}
