import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:island_ui_foundation/island_ui_foundation.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../servers/webdav_sync_service.dart';

/// Prompts the user for WebDAV endpoint credentials.
///
/// Returns a [WebDavSyncConfiguration] carrying the entered base URL,
/// username, password and remote folder. The returned object's `blobId` is
/// only meaningful when [initial] was provided.
Future<WebDavSyncConfiguration?> showWebDavConfigurationSheet(
  BuildContext context, {
  WebDavSyncConfiguration? initial,
  required String vaultLabel,
}) => showModalBottomSheet<WebDavSyncConfiguration>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  useRootNavigator: true,
  builder: (sheetContext) => _WebDavConfigurationSheet(
    initial: initial,
    vaultLabel: vaultLabel,
  ),
);

class _WebDavConfigurationSheet extends StatefulWidget {
  const _WebDavConfigurationSheet({this.initial, required this.vaultLabel});

  final WebDavSyncConfiguration? initial;
  final String vaultLabel;

  @override
  State<_WebDavConfigurationSheet> createState() =>
      _WebDavConfigurationSheetState();
}

class _WebDavConfigurationSheetState extends State<_WebDavConfigurationSheet> {
  late final TextEditingController _baseUrl;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _remotePath;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _baseUrl = TextEditingController(text: widget.initial?.baseUrl ?? '');
    _username = TextEditingController(text: widget.initial?.username ?? '');
    _password = TextEditingController(text: widget.initial?.password ?? '');
    _remotePath = TextEditingController(
      text: widget.initial?.remotePath ?? '/MaidKit/',
    );
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _username.dispose();
    _password.dispose();
    _remotePath.dispose();
    super.dispose();
  }

  void _submit() {
    final baseUrl = _baseUrl.text.trim();
    final username = _username.text.trim();
    final password = _password.text;
    if (baseUrl.isEmpty || username.isEmpty || password.isEmpty) return;
    var remotePath = _remotePath.text.trim();
    if (remotePath.isEmpty) remotePath = '/MaidKit/';
    Navigator.of(context).pop(
      WebDavSyncConfiguration(
        baseUrl: baseUrl,
        username: username,
        password: password,
        remotePath: remotePath,
        blobId: widget.initial?.blobId ?? '',
        revision: widget.initial?.revision ?? 0,
        lastSyncedAt: widget.initial?.lastSyncedAt,
        lastContentFingerprint: widget.initial?.lastContentFingerprint,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => SheetScaffold(
    title: Text('settingsVaultWebDavConfigure'.tr()),
    heightFactor: 0.75,
    child: ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        Text(
          'settingsVaultWebDavHint'.tr(args: [widget.vaultLabel]),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _baseUrl,
          autofocus: widget.initial == null,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'WebDAV URL',
            hintText: 'https://dav.jianguoyun.com/dav/',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _username,
          decoration: const InputDecoration(labelText: '用户名'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _password,
          obscureText: _obscure,
          decoration: InputDecoration(
            labelText: '密码',
            suffixIcon: IconButton(
              icon: Icon(_obscure ? Symbols.visibility : Symbols.visibility_off),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _remotePath,
          decoration: const InputDecoration(
            labelText: '远程目录',
            hintText: '/MaidKit/',
          ),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            const Spacer(),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('commonCancel').tr(),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _submit,
              child: const Text('settingsVaultSyncConfigureSave').tr(),
            ),
          ],
        ),
      ],
    ),
  );
}
