import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoSlider;

import 'backend.dart';
import 'controller.dart';
import 'models.dart';
import 'ui_common.dart';

Future<void> showSettings(
  BuildContext context,
  AppController app,
  CredentialVault vault,
  bool desktop,
) => showDialog<void>(
  context: context,
  builder: (context) => Dialog(
    insetPadding: const EdgeInsets.all(16),
    child: SizedBox(
      width: 680,
      height: (MediaQuery.sizeOf(context).height - 60).clamp(300, 720),
      child: _Settings(app: app, vault: vault, desktop: desktop),
    ),
  ),
);

class _Settings extends StatefulWidget {
  const _Settings({
    required this.app,
    required this.vault,
    required this.desktop,
  });
  final AppController app;
  final CredentialVault vault;
  final bool desktop;
  @override
  State<_Settings> createState() => _SettingsState();
}

class _SettingsState extends State<_Settings> {
  Future<void> select(String source) async {
    Navigator.pop(context);
    await widget.app.switchSource(source);
  }

  Future<void> edit(ConnectionProfile? profile) async {
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: SizedBox(
          width: 620,
          height: (MediaQuery.sizeOf(context).height - 60).clamp(300, 740),
          child: _ProfileEditor(
            app: widget.app,
            vault: widget.vault,
            original: profile,
            desktop: widget.desktop,
          ),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.app,
    builder: (context, _) => Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 12, 12),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Connection & display',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
              ),
              CompactIcon(
                Icons.close,
                'Close settings',
                () => Navigator.pop(context),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(22),
            children: [
              const Text(
                'Session source',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
              ),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.science_outlined, color: context.accent),
                title: const Text('Demo'),
                subtitle: const Text(
                  'Synthetic sessions. Your real sessions stay out of this view.',
                ),
                trailing: widget.app.source == 'demo'
                    ? Icon(Icons.check, color: context.accent)
                    : TextButton(
                        onPressed: () => unawaited(select('demo')),
                        child: const Text('Use demo'),
                      ),
                onTap: () => unawaited(select('demo')),
              ),
              ...widget.app.snapshot.profiles
                  .where((p) => widget.desktop || p.kind == ConnectionKind.ssh)
                  .map(
                    (profile) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        profile.kind == ConnectionKind.local
                            ? Icons.computer
                            : Icons.cloud_outlined,
                        color: context.mutedInk,
                      ),
                      title: Text(profile.label),
                      subtitle: Text(
                        profile.kind == ConnectionKind.local
                            ? 'Herdr on this Mac'
                            : '${profile.username}@${profile.host}:${profile.port}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.app.source == profile.id)
                            Padding(
                              padding: EdgeInsets.only(right: 8),
                              child: Icon(Icons.check, color: context.accent),
                            ),
                          TextButton(
                            onPressed: () => unawaited(select(profile.id)),
                            child: const Text('Connect'),
                          ),
                          CompactIcon(
                            Icons.edit_outlined,
                            'Edit ${profile.label}',
                            () => unawaited(edit(profile)),
                          ),
                        ],
                      ),
                    ),
                  ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => unawaited(edit(null)),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add SSH connection'),
                ),
              ),
              if (!widget.desktop)
                Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Connect your phone or tablet to Herdr on a computer over SSH. Local computer sockets are available in the desktop app.',
                    style: TextStyle(color: context.mutedInk, height: 1.5),
                  ),
                ),
              const Divider(height: 34),
              const Text(
                'Display',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
              ),
              const SizedBox(height: 12),
              const Text('Appearance'),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                key: const ValueKey('appearance-mode'),
                segments: const [
                  ButtonSegment(value: 'system', label: Text('System')),
                  ButtonSegment(value: 'light', label: Text('Light')),
                  ButtonSegment(value: 'dark', label: Text('Dark')),
                ],
                selected: {widget.app.snapshot.appearance},
                onSelectionChanged: (value) =>
                    widget.app.setAppearance(value.single),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  const Expanded(child: Text('Session tile size')),
                  Text(
                    '${widget.app.layout.tileWidth.round()} px',
                    style: TextStyle(color: context.mutedInk),
                  ),
                ],
              ),
              CupertinoSlider(
                value: widget.app.layout.tileWidth,
                min: 240,
                max: 480,
                divisions: 8,
                onChanged: widget.app.setTileWidth,
              ),
              Row(
                children: [
                  const Expanded(child: Text('Terminal zoom')),
                  Text(
                    '${(widget.app.layout.zoom * 100).round()}%',
                    style: TextStyle(color: context.mutedInk),
                  ),
                ],
              ),
              CupertinoSlider(
                value: widget.app.layout.zoom,
                min: 0.5,
                max: 3,
                onChanged: widget.app.setZoom,
              ),
              Text(
                'Zoom fits the terminal to the available space when the connection supports resizing.',
                style: TextStyle(
                  color: context.mutedInk,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
              const Divider(height: 34),
              const Text(
                'Keyboard & dictation',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
              ),
              const SizedBox(height: 10),
              Text(
                '⌘ F  Find a session\n⌘ 1  Favourites\n⌘ 0  All sessions\nEsc  Return to overview outside terminal focus\n⌘ R  Reconnect\n⌘ Enter / Ctrl Enter  Send from the message box',
                style: TextStyle(height: 1.9, color: context.mutedInk),
              ),
              const SizedBox(height: 10),
              Text(
                'Click or tap the terminal to type directly. Arrows, Enter, Tab and control keys go to the focused session. The message box stays separate; use your system keyboard’s microphone or dictation when available, then review and Send.',
                style: TextStyle(height: 1.5, color: context.mutedInk),
              ),
              const Divider(height: 34),
              const Text(
                'AgentSpace 0.1.0',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                'Closing a view leaves the session running. Agent status colours come from Herdr; terminal connection state is shown separately. Demo and live layouts, drafts and favourites stay separate.',
                style: TextStyle(color: context.mutedInk, height: 1.5),
              ),
              const SizedBox(height: 12),
              Text(
                'Multi-line paste opens in the message box for review. Unconfirmed delivery stops further input until you check the terminal; input is never automatically retried.',
                style: TextStyle(color: context.mutedInk, height: 1.5),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _ProfileEditor extends StatefulWidget {
  const _ProfileEditor({
    required this.app,
    required this.vault,
    required this.original,
    required this.desktop,
  });
  final AppController app;
  final CredentialVault vault;
  final ConnectionProfile? original;
  final bool desktop;
  @override
  State<_ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<_ProfileEditor> {
  final name = TextEditingController(),
      host = TextEditingController(),
      port = TextEditingController(text: '22'),
      username = TextEditingController(),
      fingerprint = TextEditingController(),
      executable = TextEditingController(),
      socket = TextEditingController(),
      privateKey = TextEditingController(),
      privateKeyPath = TextEditingController(),
      password = TextEditingController(),
      passphrase = TextEditingController();
  late ConnectionProfile profile;
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    profile = widget.original == null
        ? ConnectionProfile(
            id: 'ssh-${DateTime.now().microsecondsSinceEpoch}',
            label: '',
            kind: ConnectionKind.ssh,
          )
        : ConnectionProfile.fromJson(widget.original!.toJson())!;
    name.text = profile.label;
    host.text = profile.host;
    port.text = '${profile.port}';
    username.text = profile.username;
    fingerprint.text = profile.hostFingerprint;
    executable.text = profile.executable;
    socket.text = profile.socketPath;
    privateKeyPath.text = profile.privateKeyPath;
    if (profile.kind == ConnectionKind.ssh && widget.original != null) {
      unawaited(loadCredentials());
    }
  }

  Future<void> loadCredentials() async {
    try {
      final credentials = await widget.vault.read(profile.id);
      if (!mounted) return;
      if (privateKey.text.isEmpty) privateKey.text = credentials.privateKey;
      if (password.text.isEmpty) password.text = credentials.password;
      if (passphrase.text.isEmpty) passphrase.text = credentials.passphrase;
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Stored credentials could not be opened. Enter a key or password to reconnect.',
        );
      }
    }
  }

  @override
  void dispose() {
    for (final field in [
      name,
      host,
      port,
      username,
      fingerprint,
      executable,
      socket,
      privateKey,
      privateKeyPath,
      password,
      passphrase,
    ]) {
      field.dispose();
    }
    super.dispose();
  }

  void capture() {
    profile.label = name.text.trim().isEmpty
        ? profile.kind == ConnectionKind.local
              ? 'Local Mac'
              : host.text.trim()
        : name.text.trim();
    profile.host = host.text.trim();
    profile.port = int.tryParse(port.text.trim()) ?? 0;
    profile.username = username.text.trim();
    profile.hostFingerprint = fingerprint.text.trim();
    profile.executable = executable.text.trim();
    profile.socketPath = socket.text.trim();
    profile.privateKeyPath = privateKeyPath.text.trim();
  }

  Future<void> checkIdentity() async {
    capture();
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final value = await probeHostFingerprint(profile);
      if (!mounted) return;
      final trusted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Verify this computer'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${profile.host}:${profile.port} presented this SSH host key:',
              ),
              const SizedBox(height: 14),
              SelectableText(
                value,
                style: const TextStyle(fontFamily: 'Menlo', fontSize: 12),
              ),
              const SizedBox(height: 16),
              Text(
                'Compare it with the host fingerprint on your Mac before trusting it. Discovery does not authenticate or send input.',
                style: TextStyle(color: context.mutedInk, height: 1.5),
              ),
              const SizedBox(height: 12),
              const SelectableText(
                'ssh-keygen -lf /etc/ssh/ssh_host_*_key.pub -E sha256',
                style: TextStyle(fontFamily: 'Menlo', fontSize: 11),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Fingerprint matches'),
            ),
          ],
        ),
      );
      if (trusted == true && mounted) fingerprint.text = value;
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Could not read the host key. Check the address, port and SSH Remote Login.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    capture();
    if (profile.kind == ConnectionKind.local &&
        (!profile.socketPath.startsWith('/') ||
            !profile.executable.startsWith('/'))) {
      setState(() => error = 'Use absolute paths for Herdr and its socket.');
      return;
    }
    if (profile.kind == ConnectionKind.ssh &&
        (profile.host.isEmpty ||
            profile.username.isEmpty ||
            profile.port < 1 ||
            profile.port > 65535 ||
            !RegExp(r'^SHA256:[A-Za-z0-9+/]{43}$')
                .hasMatch(profile.hostFingerprint))) {
      setState(
        () => error = 'Enter a host, username and valid port, then verify its SSH fingerprint.',
      );
      return;
    }
    if (profile.kind == ConnectionKind.ssh &&
        privateKey.text.trim().isEmpty &&
        password.text.isEmpty &&
        privateKeyPath.text.isEmpty) {
      setState(() => error = 'Enter a dedicated SSH private key or password.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (profile.kind == ConnectionKind.ssh) {
        await widget.vault.write(
          profile.id,
          SshCredentials(
            privateKey: privateKey.text.trim(),
            password: password.text,
            passphrase: passphrase.text,
          ),
        );
      }
      final index = widget.app.snapshot.profiles.indexWhere(
        (p) => p.id == profile.id,
      );
      if (index < 0) {
        if (widget.app.snapshot.profiles.length >= 16) {
          throw StateError('Connection limit');
        }
        widget.app.snapshot.profiles.add(profile);
      } else {
        widget.app.snapshot.profiles[index] = profile;
      }
      await widget.app.flush();
      if (!mounted) return;
      Navigator.pop(context);
      await widget.app.switchSource(profile.id);
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          error = 'The connection could not be saved. Check that secure storage is available and try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(22, 18, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                profile.kind == ConnectionKind.local
                    ? 'Herdr on this Mac'
                    : 'SSH connection',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            CompactIcon(
              Icons.close,
              'Close connection settings',
              busy ? null : () => Navigator.pop(context),
            ),
          ],
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.all(22),
          children: [
            _field(name, 'Connection name'),
            if (profile.kind == ConnectionKind.local) ...[
              _field(
                executable,
                'Herdr executable',
                hint: '/absolute/path/to/herdr',
              ),
              _field(
                socket,
                'Server socket',
                hint: '/Users/you/.config/herdr/herdr.sock',
              ),
              const SizedBox(height: 12),
              Text(
                'AgentSpace connects to an existing local Herdr server. It does not start terminals. Opening a session fits its terminal to your view.',
                style: TextStyle(color: context.mutedInk, height: 1.5),
              ),
            ] else ...[
              _field(
                host,
                'Computer address',
                hint: 'Mac hostname or IP address',
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _field(username, 'SSH username')),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 100,
                    child: _field(
                      port,
                      'Port',
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              _field(
                fingerprint,
                'Verified host fingerprint',
                hint: 'SHA256:…',
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: busy ? null : checkIdentity,
                  icon: const Icon(Icons.verified_user_outlined, size: 17),
                  label: Text(busy ? 'Checking…' : 'Check computer identity'),
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Authentication',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              if (widget.desktop)
                _field(
                  privateKeyPath,
                  'Private key file',
                  hint: '/absolute/path/to/dedicated/key',
                ),
              _field(
                privateKey,
                'Or paste an SSH private key',
                maxLines: 4,
                keyboardType: TextInputType.multiline,
              ),
              _field(passphrase, 'Key passphrase, if needed', obscure: true),
              _field(password, 'Or SSH password', obscure: true),
              Text(
                'Credentials are kept in this device’s secure storage. Use your usual SSH key or password. Herdr must be running on the computer; dedicated restricted keys are also supported.',
                style: TextStyle(color: context.mutedInk, height: 1.5),
              ),
            ],
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  error!,
                  style: TextStyle(color: context.attention, height: 1.5),
                ),
              ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          alignment: WrapAlignment.end,
          spacing: 10,
          runSpacing: 8,
          children: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: busy ? null : save,
              child: Text(busy ? 'Saving…' : 'Save & connect'),
            ),
          ],
        ),
      ),
    ],
  );
  Widget _field(
    TextEditingController controller,
    String label, {
    String? hint,
    bool obscure = false,
    int maxLines = 1,
    TextInputType? keyboardType,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextField(
      controller: controller,
      obscureText: obscure,
      maxLines: maxLines,
      keyboardType: keyboardType,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(labelText: label, hintText: hint),
    ),
  );
}
