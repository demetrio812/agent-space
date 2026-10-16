import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Mouse drags start immediately; touch retains long-press and normal scrolling.
class SessionDraggable extends StatefulWidget {
  const SessionDraggable({
    super.key,
    required this.id,
    required this.child,
    required this.feedback,
    this.onDragUpdate,
    this.onDragEnd,
  });
  final String id;
  final Widget child, feedback;
  final DragUpdateCallback? onDragUpdate;
  final VoidCallback? onDragEnd;
  @override
  State<SessionDraggable> createState() => _SessionDraggableState();
}

class _SessionDraggableState extends State<SessionDraggable>
    with AutomaticKeepAliveClientMixin {
  int activeDrags = 0;
  @override
  bool get wantKeepAlive => activeDrags > 0;

  void startDrag() {
    activeDrags++;
    updateKeepAlive();
  }

  void finishDrag() {
    if (mounted) {
      activeDrags--;
      updateKeepAlive();
    }
    widget.onDragEnd?.call();
  }

  @override
  void dispose() {
    if (activeDrags > 0) widget.onDragEnd?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return _DeviceDraggable(
      data: widget.id,
      feedback: widget.feedback,
      onDragStarted: startDrag,
      onDragUpdate: widget.onDragUpdate,
      onDragCompleted: finishDrag,
      onDraggableCanceled: (_, _) => finishDrag(),
      delayed: false,
      content: _DeviceDraggable(
        data: widget.id,
        feedback: widget.feedback,
        onDragStarted: startDrag,
        onDragUpdate: widget.onDragUpdate,
        onDragCompleted: finishDrag,
        onDraggableCanceled: (_, _) => finishDrag(),
        delayed: true,
        content: widget.child,
      ),
    );
  }
}

class _DeviceDraggable extends Draggable<String> {
  _DeviceDraggable({
    required super.data,
    required super.feedback,
    required Widget content,
    required this.delayed,
    super.onDragUpdate,
    super.onDragStarted,
    super.onDragCompleted,
    super.onDraggableCanceled,
  }) : super(
         child: content,
         childWhenDragging: Opacity(opacity: .4, child: content),
         dragAnchorStrategy: pointerDragAnchorStrategy,
         maxSimultaneousDrags: 1,
       );
  final bool delayed;
  @override
  MultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) {
    final devices = PointerDeviceKind.values
        .where(
          (kind) =>
              delayed !=
              (kind == PointerDeviceKind.mouse ||
                  kind == PointerDeviceKind.trackpad),
        )
        .toSet();
    final MultiDragGestureRecognizer recognizer = delayed
        ? DelayedMultiDragGestureRecognizer(
            supportedDevices: devices,
            allowedButtonsFilter: (buttons) => buttons == kPrimaryButton,
          )
        : ImmediateMultiDragGestureRecognizer(
            supportedDevices: devices,
            allowedButtonsFilter: (buttons) => buttons == kPrimaryButton,
          );
    return recognizer..onStart = onStart;
  }
}

class SessionReorderStart extends StatelessWidget {
  const SessionReorderStart({
    super.key,
    required this.index,
    required this.child,
  });
  final int index;
  final Widget child;
  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (event) {
      if (event.buttons != kPrimaryButton) return;
      final MultiDragGestureRecognizer recognizer =
          event.kind == PointerDeviceKind.mouse ||
              event.kind == PointerDeviceKind.trackpad
          ? ImmediateMultiDragGestureRecognizer(debugOwner: this)
          : DelayedMultiDragGestureRecognizer(debugOwner: this);
      recognizer.gestureSettings = MediaQuery.maybeGestureSettingsOf(context);
      final list = SliverReorderableList.maybeOf(context);
      if (list == null) {
        recognizer.dispose();
        return;
      }
      list.startItemDragReorder(
        index: index,
        event: event,
        recognizer: recognizer,
      );
    },
    child: child,
  );
}
