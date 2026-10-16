import 'package:flutter/material.dart';

import 'models.dart';

const ink = Color(0xff182330);
const workspaceBackground = Color(0xffeef2f5);
const terminalBackground = Color(0xff101820);
const selectionBlue = Color(0xff3976b7);
const mutedInk = Color(0xff637385);

extension WorkspaceColors on BuildContext {
  bool get darkAppearance => Theme.of(this).brightness == Brightness.dark;
  Color get ink =>
      darkAppearance ? const Color(0xffe2eaf2) : const Color(0xff182330);
  Color get mutedInk =>
      darkAppearance ? const Color(0xffa5b5c5) : const Color(0xff637385);
  Color get panel => darkAppearance ? const Color(0xff1b2733) : Colors.white;
  Color get workspace =>
      darkAppearance ? const Color(0xff111c26) : workspaceBackground;
  Color get border =>
      darkAppearance ? const Color(0xff3b4b5c) : const Color(0xffd8e0e7);
  Color get tabs =>
      darkAppearance ? const Color(0xff243343) : const Color(0xffe5ebf0);
  Color get accent => darkAppearance ? const Color(0xff8cbdf0) : selectionBlue;
  Color get attention =>
      darkAppearance ? const Color(0xffedc477) : const Color(0xff925a12);
  Color get success =>
      darkAppearance ? const Color(0xff94d6ae) : const Color(0xff23734b);
  Color get attentionSurface =>
      darkAppearance ? const Color(0xff352e20) : const Color(0xfffff8e8);
  Color get successSurface =>
      darkAppearance ? const Color(0xff20352c) : const Color(0xffedf7f0);
}

ThemeData workspaceTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final surface = dark ? const Color(0xff1b2733) : Colors.white;
  final border = dark ? const Color(0xff3b4b5c) : const Color(0xffd8e0e7);
  final foreground = dark ? const Color(0xffe2eaf2) : ink;
  final muted = dark ? const Color(0xffa5b5c5) : mutedInk;
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: selectionBlue,
      brightness: brightness,
      surface: surface,
    ),
    scaffoldBackgroundColor: dark
        ? const Color(0xff111c26)
        : workspaceBackground,
    visualDensity: VisualDensity.compact,
    fontFamily: 'SF Pro Text',
    textTheme: TextTheme(
      bodyMedium: TextStyle(fontSize: 13, color: foreground),
      bodySmall: TextStyle(fontSize: 11, color: muted),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: foreground,
      ),
    ),
    dividerColor: border,
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(7),
        borderSide: BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(7),
        borderSide: BorderSide(color: border),
      ),
    ),
  );
}

typedef OpenDesktopWindow = Future<void> Function(String kind, String target);
Color statusInk(BuildContext context, SessionInfo session) => !session.available
    ? context.mutedInk
    : switch (session.status) {
        SessionStatus.done => context.success,
        SessionStatus.needsInput => context.attention,
        SessionStatus.working => context.accent,
        _ => context.mutedInk,
      };
Color statusBackground(BuildContext context, SessionInfo session) =>
    !session.available
    ? context.tabs
    : switch (session.status) {
        SessionStatus.done => context.successSurface,
        SessionStatus.needsInput => context.attentionSurface,
        _ => context.tabs,
      };
IconData statusIcon(SessionInfo session) => !session.available
    ? Icons.cloud_off_outlined
    : switch (session.status) {
        SessionStatus.done => Icons.check_circle_outline,
        SessionStatus.needsInput => Icons.help_outline,
        SessionStatus.working => Icons.autorenew,
        _ => Icons.circle_outlined,
      };

class CompactIcon extends StatelessWidget {
  const CompactIcon(
    this.icon,
    this.tooltip,
    this.onPressed, {
    super.key,
    this.color,
    this.size = 18,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;
  final double size;
  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    icon: Icon(icon, size: size, color: color),
    style: IconButton.styleFrom(
      minimumSize: const Size(32, 32),
      fixedSize: const Size(32, 32),
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
  );
}

class StatusBadge extends StatelessWidget {
  const StatusBadge(this.session, {super.key});
  final SessionInfo session;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
    decoration: BoxDecoration(
      color: statusBackground(context, session),
      borderRadius: BorderRadius.circular(5),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(statusIcon(session), color: statusInk(context, session), size: 13),
        const SizedBox(width: 4),
        Text(
          session.available ? session.status.label : 'Unavailable',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: statusInk(context, session),
          ),
        ),
      ],
    ),
  );
}
