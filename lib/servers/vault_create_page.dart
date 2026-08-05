import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:island_ui_foundation/island_ui_foundation.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:maid_kit/shared/presentation/webdav_configuration_sheet.dart';

import 'webdav_sync_service.dart';
import 'server_providers.dart';

/// Full-screen vault onboarding reached from the locked vault gate.
///
/// The user either creates a brand-new local vault file or signs in to
/// Solarpass to download an existing cloud vault.
class VaultCreatePage extends ConsumerStatefulWidget {
  const VaultCreatePage({super.key});

  @override
  ConsumerState<VaultCreatePage> createState() => _VaultCreatePageState();
}

class _VaultCreatePageState extends ConsumerState<VaultCreatePage> {
  final _name = TextEditingController();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  bool _creatingLocal = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  String _friendlyError(Object error) => error.toString().replaceFirst(
    RegExp(r'^(Bad state|ArgumentError): '),
    '',
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('vaultCreateTitle'.tr())),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: _creatingLocal
                    ? _buildLocalForm(theme)
                    : _buildChoices(theme),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildChoices(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'vaultCreateTitle'.tr(),
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'vaultCreateSubtitle'.tr(),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Symbols.add),
                title: Text('vaultCreateFileAction'.tr()),
                subtitle: Text('settingsVaultCreateLocalHint'.tr()),
                onTap: _busy
                    ? null
                    : () => setState(() {
                        _creatingLocal = true;
                        _error = null;
                      }),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Symbols.cloud_download),
                title: Text('vaultCreateFromCloudAction'.tr()),
                subtitle: Text('vaultCreateFromCloudHint'.tr()),
                onTap: _busy ? null : _downloadFromCloud,
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('commonCancel'.tr()),
        ),
      ],
    );
  }

  Widget _buildLocalForm(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'vaultCreateFileAction'.tr(),
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'settingsVaultCreateLocalHint'.tr(),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _name,
          enabled: !_busy,
          decoration: InputDecoration(labelText: 'settingsVaultName'.tr()),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _password,
          obscureText: true,
          enabled: !_busy,
          onSubmitted: (_) => _createLocalVault(),
          decoration: InputDecoration(labelText: 'vaultPasswordLabel'.tr()),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _confirmation,
          obscureText: true,
          enabled: !_busy,
          onSubmitted: (_) => _createLocalVault(),
          decoration: InputDecoration(
            labelText: 'vaultConfirmPasswordLabel'.tr(),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _error!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _createLocalVault,
          child: _busy
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text('vaultCreateAction'.tr()),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                  _creatingLocal = false;
                  _error = null;
                }),
          child: Text('commonCancel'.tr()),
        ),
      ],
    );
  }

  Future<void> _createLocalVault() async {
    if (_busy) return;
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'vaultNameRequired'.tr());
      return;
    }
    if (_password.text != _confirmation.text) {
      setState(() => _error = 'vaultPasswordsDontMatch'.tr());
      return;
    }
    setState(() {
      _error = null;
      _busy = true;
    });
    var success = false;
    try {
      final path = await ref
          .read(vaultFileStorageProvider)
          .createVaultPath(name: name);
      await ref.read(vaultLabelsProvider.notifier).rename(path, name);
      await ref.read(activeVaultFileProvider.notifier).select(path);
      await ref.read(vaultServiceProvider).create(_password.text);
      success = true;
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) {
        if (success) {
          Navigator.of(context).pop(true);
        } else {
          setState(() => _busy = false);
        }
      }
    }
  }

  Future<void> _downloadFromCloud() async {
    if (_busy) return;
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      final credentials = await showWebDavConfigurationSheet(
        context,
        vaultLabel: 'settingsVaultDownloadCloud'.tr(),
      );
      if (credentials == null || !mounted) return;

      final probe = WebDavSyncService(vaultId: 'probe');
      final vaults = await probe.listRemoteVaults(
        baseUrl: credentials.baseUrl,
        username: credentials.username,
        password: credentials.password,
        remotePath: credentials.remotePath,
      );
      if (!mounted) return;
      if (vaults.isEmpty) {
        setState(() => _error = 'settingsVaultNoCloudVaults'.tr());
        return;
      }
      final vault = await _chooseRemoteVault(vaults);
      if (vault == null || !mounted) return;
      final name = await _chooseVaultName(initialValue: vault.name);
      if (name == null || !mounted) return;

      final path = await ref
          .read(vaultFileStorageProvider)
          .createVaultPath(name: name);
      await ref.read(vaultLabelsProvider.notifier).rename(path, name);
      final sync = ref.read(webDavSyncServiceForVaultProvider(path));
      await sync.enableDownload(
        baseUrl: credentials.baseUrl,
        username: credentials.username,
        password: credentials.password,
        remotePath: credentials.remotePath,
        vault: vault,
      );
      ref.invalidate(webDavSyncConfigurationForVaultProvider(path));
      await ref.read(activeVaultFileProvider.notifier).select(path);
      if (mounted) Navigator.of(context).pop(false);
    } on WebDavSyncException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<RemoteVaultInfo?> _chooseRemoteVault(List<RemoteVaultInfo> vaults) =>
      showModalBottomSheet<RemoteVaultInfo>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        useRootNavigator: true,
        builder: (sheetContext) => SheetScaffold(
          titleText: 'settingsVaultDownloadCloud'.tr(),
          heightFactor: 0.6,
          child: vaults.isEmpty
              ? ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  children: [const Text('settingsVaultNoCloudVaults').tr()],
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  children: [
                    for (final vault in vaults)
                      ListTile(
                        leading: const Icon(Symbols.lock),
                        title: Text(vault.name),
                        subtitle: Text(
                          'settingsVaultCloudVault'.tr(
                            args: [vault.revision.toString()],
                          ),
                        ),
                        onTap: () => Navigator.of(sheetContext).pop(vault),
                      ),
                  ],
                ),
        ),
      );

  Future<String?> _chooseVaultName({String? initialValue}) =>
      showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        useRootNavigator: true,
        builder: (sheetContext) =>
            _VaultNameSheet(initialValue: initialValue ?? ''),
      );
}

class _VaultNameSheet extends StatefulWidget {
  const _VaultNameSheet({required this.initialValue});

  final String initialValue;

  @override
  State<_VaultNameSheet> createState() => _VaultNameSheetState();
}

class _VaultNameSheetState extends State<_VaultNameSheet> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    if (value.isNotEmpty) Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) => SheetScaffold(
    titleText: 'settingsVaultName'.tr(),
    child: ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        TextField(
          controller: _controller,
          autofocus: true,
          decoration: InputDecoration(labelText: 'settingsVaultName'.tr()),
          onSubmitted: (_) => _submit(),
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
              child: const Text('commonContinue').tr(),
            ),
          ],
        ),
      ],
    ),
  );
}
