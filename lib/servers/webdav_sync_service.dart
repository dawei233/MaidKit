import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import '../shared/presentation/maidkit_alert.dart';

/// Configuration is deliberately opt-in and scoped to one local vault.
///
/// The remote layout is deliberately simple: a directory on any standard
/// WebDAV server (Nextcloud, Seafile, ownCloud, nutstore, a NAS, ...) that
/// holds two files per vault:
///
///   {remotePath}/{blobId}.mkb   — client-encrypted vault archive
///   {remotePath}/{blobId}.meta  — JSON sync metadata (revision etc.)
///
/// The server only stores and serves bytes; it never sees the decrypted
/// vault content (the archive is produced by [DatabaseBackupService] which
/// encrypts it with the vault passphrase).
class WebDavSyncConfiguration {
  const WebDavSyncConfiguration({
    required this.baseUrl,
    required this.username,
    required this.password,
    required this.remotePath,
    required this.blobId,
    required this.revision,
    this.pendingDownload = false,
    this.lastSyncedAt,
    this.lastContentFingerprint,
  });

  /// WebDAV endpoint, e.g. `https://dav.jianguoyun.com/dav/` or
  /// `https://nextcloud.example.com/remote.php/dav/files/user/`.
  final String baseUrl;

  final String username;

  /// Stored in the OS keychain via flutter_secure_storage. Never written to
  /// logs or sent anywhere except the WebDAV server (Basic auth).
  final String password;

  /// Remote folder that holds the sync files, e.g. `/MaidKit/`.
  final String remotePath;

  /// Stable vault identifier used to derive the remote file names.
  final String blobId;

  final int revision;
  final bool pendingDownload;
  final DateTime? lastSyncedAt;

  /// SHA-256 of the syncable content at the last successful sync. A matching
  /// fingerprint means the local database is unchanged and no upload is needed.
  final String? lastContentFingerprint;

  String get archivePath => '$_normalizedBase$_normalizedRemotePath$blobId.mkb';
  String get metaPath => '$_normalizedBase$_normalizedRemotePath$blobId.meta';
  String get _normalizedBase {
    var value = baseUrl.trim();
    if (!value.endsWith('/')) value = '$value/';
    return value;
  }

  String get _normalizedRemotePath {
    var value = remotePath.trim();
    if (!value.startsWith('/')) value = '/$value';
    if (!value.endsWith('/')) value = '$value/';
    return value;
  }

  Map<String, Object?> toJson() => {
    'baseUrl': baseUrl,
    'username': username,
    'password': password,
    'remotePath': remotePath,
    'blobId': blobId,
    'revision': revision,
    'pendingDownload': pendingDownload,
    'lastSyncedAt': lastSyncedAt?.toUtc().toIso8601String(),
    'lastContentFingerprint': lastContentFingerprint,
  };

  factory WebDavSyncConfiguration.fromJson(Map<String, dynamic> json) =>
      WebDavSyncConfiguration(
        baseUrl: json['baseUrl'] as String? ?? '',
        username: json['username'] as String? ?? '',
        password: json['password'] as String? ?? '',
        remotePath: json['remotePath'] as String? ?? '/MaidKit/',
        blobId: json['blobId'] as String? ?? const Uuid().v4(),
        revision: (json['revision'] as num?)?.toInt() ?? 0,
        pendingDownload: json['pendingDownload'] == true,
        lastSyncedAt: DateTime.tryParse(
          json['lastSyncedAt'] as String? ?? '',
        )?.toLocal(),
        lastContentFingerprint: json['lastContentFingerprint'] as String?,
      );
}

class RemoteVaultInfo {
  const RemoteVaultInfo({
    required this.name,
    required this.blobId,
    required this.revision,
    required this.updatedAt,
  });

  final String name;
  final String blobId;
  final int revision;
  final DateTime? updatedAt;
}

class WebDavSyncException implements Exception {
  const WebDavSyncException(this.message);
  final String message;

  @override
  String toString() => message;
}

enum WebDavSyncConflictResolution { downloadRemote, overwriteRemote }

/// Raised before either copy is changed when the remote has a newer revision.
class WebDavSyncConflictException extends WebDavSyncException {
  const WebDavSyncConflictException({this.remoteRevision})
    : super('This vault has a newer cloud version.');

  final int? remoteRevision;
}

String _webDavErrorMessage(DioException error) {
  final status = error.response?.statusCode;
  if (status == 401 || status == 403) {
    return 'WebDAV authentication failed. Check your username and password.';
  }
  if (status == 404) {
    return 'The WebDAV folder was not found on the server.';
  }
  return error.message ?? 'WebDAV request failed (HTTP $status).';
}

/// Syncs the encrypted vault archive over a standard WebDAV server.
///
/// This replaces the previous Solarpass/Flywheel transport: no account, no
/// paid workspace, no vendor lock-in. Any WebDAV endpoint works (nutstore,
/// Nextcloud, Seafile, a NAS, ...).
class WebDavSyncService {
  WebDavSyncService({
    required String vaultId,
    FlutterSecureStorage? secureStorage,
    Dio? dio,
  }) : _vaultKey = base64UrlEncode(utf8.encode(vaultId)),
       _storage = secureStorage ?? const FlutterSecureStorage(),
       _dio = dio ?? Dio();

  final String _vaultKey;
  final FlutterSecureStorage _storage;
  final Dio _dio;

  static const _configKeyPrefix = 'maidkit_webdav_sync_';
  static const _metaVersion = 1;

  String get _configurationKey => '$_configKeyPrefix$_vaultKey';

  Future<WebDavSyncConfiguration?> configuration() async {
    final raw = await _storage.read(key: _configurationKey);
    if (raw == null) return null;
    try {
      return WebDavSyncConfiguration.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      await disable();
      return null;
    }
  }

  Future<void> disable() => _storage.delete(key: _configurationKey);

  /// Saves a new WebDAV binding. [password] is kept in the OS keychain.
  /// When the remote already has a `.meta` file, the local vault is marked
  /// as a pending download so the next unlock adopts the remote copy.
  Future<WebDavSyncConfiguration> enable({
    required String baseUrl,
    required String username,
    required String password,
    String remotePath = '/MaidKit/',
  }) async {
    final previous = await configuration();
    final reuse = previous != null;
    final blobId = reuse ? previous.blobId : const Uuid().v4();

    final config = WebDavSyncConfiguration(
      baseUrl: baseUrl,
      username: username,
      password: password,
      remotePath: remotePath,
      blobId: blobId,
      revision: reuse ? previous.revision : 0,
      pendingDownload: false,
      lastSyncedAt: previous?.lastSyncedAt,
      lastContentFingerprint: previous?.lastContentFingerprint,
    );

    // Probe connectivity + detect an existing remote copy.
    final meta = await _tryReadRemoteMeta(config);
    final pending = meta != null && meta.revision > config.revision;

    final updated = WebDavSyncConfiguration(
      baseUrl: baseUrl,
      username: username,
      password: password,
      remotePath: remotePath,
      blobId: blobId,
      revision: pending ? meta.revision : config.revision,
      pendingDownload: pending,
      lastSyncedAt: meta?.updatedAt ?? config.lastSyncedAt,
      lastContentFingerprint: config.lastContentFingerprint,
    );
    await _storage.write(
      key: _configurationKey,
      value: jsonEncode(updated.toJson()),
    );
    return updated;
  }

  Future<void> completePendingDownload() async {
    final configuration = await this.configuration();
    if (configuration == null || !configuration.pendingDownload) return;
    await _saveConfiguration(
      WebDavSyncConfiguration(
        baseUrl: configuration.baseUrl,
        username: configuration.username,
        password: configuration.password,
        remotePath: configuration.remotePath,
        blobId: configuration.blobId,
        revision: configuration.revision,
        lastSyncedAt: configuration.lastSyncedAt,
        lastContentFingerprint: configuration.lastContentFingerprint,
      ),
    );
  }

  /// Binds this vault to an existing remote [RemoteVaultInfo] so the next
  /// unlock downloads that archive. Used by the "download from cloud" flow.
  Future<WebDavSyncConfiguration> enableDownload({
    required String baseUrl,
    required String username,
    required String password,
    required String remotePath,
    required RemoteVaultInfo vault,
  }) async {
    final config = WebDavSyncConfiguration(
      baseUrl: baseUrl,
      username: username,
      password: password,
      remotePath: remotePath,
      blobId: vault.blobId,
      revision: vault.revision,
      pendingDownload: true,
      lastSyncedAt: vault.updatedAt,
    );
    await _storage.write(
      key: _configurationKey,
      value: jsonEncode(config.toJson()),
    );
    return config;
  }

  /// Lists remote vaults found in the configured remote folder (for the
  /// "download a vault from the cloud" flow).
  Future<List<RemoteVaultInfo>> listRemoteVaults({
    required String baseUrl,
    required String username,
    required String password,
    String remotePath = '/MaidKit/',
  }) async {
    final probe = WebDavSyncConfiguration(
      baseUrl: baseUrl,
      username: username,
      password: password,
      remotePath: remotePath,
      blobId: 'probe',
      revision: 0,
    );
    final entries = await _propFind(probe);
    final vaults = <RemoteVaultInfo>[];
    for (final entry in entries) {
      final href = entry['href']?.toString() ?? '';
      if (!href.endsWith('.meta')) continue;
      final blobId = _baseName(href).replaceFirst(RegExp(r'\.meta$'), '');
      if (blobId.isEmpty || blobId == 'probe') continue;
      final meta = await _tryReadRemoteMetaByBlob(
        probe,
        blobId: blobId,
      );
      if (meta == null) continue;
      vaults.add(
        RemoteVaultInfo(
          name: meta.name,
          blobId: blobId,
          revision: meta.revision,
          updatedAt: meta.updatedAt,
        ),
      );
    }
    vaults.sort((a, b) {
      final at = a.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bt = b.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bt.compareTo(at);
    });
    return vaults;
  }

  /// Downloads a remote vault archive by [blobId] and returns the raw
  /// (still encrypted) archive string, or null when the server has no file.
  Future<String?> downloadRemoteArchive(
    String blobId, {
    required String baseUrl,
    required String username,
    required String password,
    String remotePath = '/MaidKit/',
  }) async {
    final config = WebDavSyncConfiguration(
      baseUrl: baseUrl,
      username: username,
      password: password,
      remotePath: remotePath,
      blobId: blobId,
      revision: 0,
    );
    try {
      final response = await _authorizedGetBytes(config.archivePath, config);
      return utf8.decode(response.data ?? const []);
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  /// Uploads/downloads a client-encrypted archive. The WebDAV server never
  /// decrypts it.
  ///
  /// The remote revision is always read first. When the cloud is newer and no
  /// [conflictResolution] is given, the user is asked whether to take the
  /// remote copy or keep the local one.
  ///
  /// When [contentFingerprint] is provided, the upload is skipped if it
  /// matches the fingerprint stored at the last successful sync and the local
  /// revision was not superseded.
  Future<WebDavSyncConfiguration> sync({
    required String archive,
    required Future<void> Function(String archive) applyArchive,
    Future<String> Function()? contentFingerprint,
    WebDavSyncConflictResolution? conflictResolution,
    int conflictRetryCount = 0,
  }) async {
    final configuration = await this.configuration();
    if (configuration == null) {
      throw const WebDavSyncException(
        'Configure WebDAV sync for this vault first.',
      );
    }
    try {
      var revision = configuration.revision;
      final remote = await _tryReadRemoteMeta(configuration);
      final remoteRevision = remote?.revision ?? 0;

      if (remoteRevision > revision) {
        final resolution =
            conflictResolution ?? await _resolveConflict(remoteRevision);
        if (resolution == WebDavSyncConflictResolution.downloadRemote) {
          final content = await _authorizedGetBytes(
            configuration.archivePath,
            configuration,
          );
          final remoteArchive = utf8.decode(content.data ?? const []);
          await applyArchive(remoteArchive);
          final updated = _updatedConfiguration(
            configuration,
            revision: remoteRevision,
            contentFingerprint: await contentFingerprint?.call(),
          );
          await _saveConfiguration(updated);
          return updated;
        }
        // Normal sync is local-authoritative. It keeps this vault's stable
        // blob ID and creates the next revision from the latest remote one.
        revision = remoteRevision;
      }

      final fingerprint = await contentFingerprint?.call();
      if (fingerprint != null &&
          fingerprint == configuration.lastContentFingerprint &&
          revision == configuration.revision) {
        // Nothing changed locally and no newer remote revision was adopted.
        return configuration;
      }

      // Upload the archive first, then the metadata so a partial upload never
      // looks like a successful revision bump.
      await _authorizedPutBytes(configuration.archivePath, archive, configuration);
      final nextRevision = revision + 1;
      await _putRemoteMeta(
        configuration,
        revision: nextRevision,
        fingerprint: fingerprint,
        name: _displayName,
      );
      final updated = _updatedConfiguration(
        configuration,
        revision: nextRevision,
        contentFingerprint: fingerprint,
      );
      await _saveConfiguration(updated);
      return updated;
    } on DioException catch (error) {
      if (error.response?.statusCode == 409 && conflictRetryCount < 1) {
        // Another device won the race after metadata was read. Re-read its
        // revision and retry the local-authoritative upload once.
        return sync(
          archive: archive,
          applyArchive: applyArchive,
          contentFingerprint: contentFingerprint,
          conflictResolution:
              WebDavSyncConflictResolution.overwriteRemote,
          conflictRetryCount: conflictRetryCount + 1,
        );
      }
      if (error.response?.statusCode == 409) {
        throw const WebDavSyncException(
          'This cloud vault changed again while syncing. Try once more.',
        );
      }
      throw WebDavSyncException(_webDavErrorMessage(error));
    }
  }

  String get _displayName {
    final vaultId = utf8.decode(
      base64Url.decode(base64Url.normalize(_vaultKey)),
      allowMalformed: true,
    );
    return vaultId;
  }

  /// Asks the user whether to adopt the newer remote revision or keep the
  /// local copy. Without an app overlay (headless), the local copy wins.
  Future<WebDavSyncConflictResolution> _resolveConflict(
    int remoteRevision,
  ) async {
    final useRemote = await showMaidKitCloudSyncConflictAlert(
      remoteRevision: remoteRevision,
    );
    return useRemote
        ? WebDavSyncConflictResolution.downloadRemote
        : WebDavSyncConflictResolution.overwriteRemote;
  }

  WebDavSyncConfiguration _updatedConfiguration(
    WebDavSyncConfiguration configuration, {
    required int revision,
    String? contentFingerprint,
  }) => WebDavSyncConfiguration(
    baseUrl: configuration.baseUrl,
    username: configuration.username,
    password: configuration.password,
    remotePath: configuration.remotePath,
    blobId: configuration.blobId,
    revision: revision,
    pendingDownload: configuration.pendingDownload,
    lastSyncedAt: DateTime.now(),
    lastContentFingerprint:
        contentFingerprint ?? configuration.lastContentFingerprint,
  );

  Future<void> _saveConfiguration(WebDavSyncConfiguration configuration) =>
      _storage.write(
        key: _configurationKey,
        value: jsonEncode(configuration.toJson()),
      );

  // ── WebDAV primitives ─────────────────────────────────────────────────────

  Options _authOptions(WebDavSyncConfiguration configuration) => Options(
    headers: {
      'Authorization':
          'Basic ${base64Encode(utf8.encode('${configuration.username}:${configuration.password}'))}',
    },
  );

  Future<Response<List<int>>> _authorizedGetBytes(
    String url,
    WebDavSyncConfiguration configuration,
  ) => _dio.get<List<int>>(
    url,
    options: _authOptions(configuration).copyWith(
      responseType: ResponseType.bytes,
    ),
  );

  Future<void> _authorizedPutBytes(
    String url,
    String data,
    WebDavSyncConfiguration configuration,
  ) => _dio.put<void>(
    url,
    data: utf8.encode(data),
    options: _authOptions(configuration).copyWith(
      contentType: 'application/octet-stream',
    ),
  );

  /// PROPFIND with Depth: 1; returns a list of {href, data?} entries.
  Future<List<Map<String, Object?>>> _propFind(
    WebDavSyncConfiguration configuration,
  ) async {
    final url =
        '${configuration._normalizedBase}${configuration._normalizedRemotePath}';
    final auth = _authOptions(configuration);
    final response = await _dio.request<dynamic>(
      url,
      options: Options(
        method: 'PROPFIND',
        headers: {...auth.headers!, 'Depth': '1'},
        responseType: ResponseType.plain,
      ),
      data:
          '<?xml version="1.0"?>'
          '<d:propfind xmlns:d="DAV:"><d:prop>'
          '<d:displayname/><d:getlastmodified/>'
          '</d:prop></d:propfind>',
    );
    final body = response.data?.toString() ?? '';
    return _parsePropFind(body, baseUrl: url);
  }

  List<Map<String, Object?>> _parsePropFind(
    String body, {
    required String baseUrl,
  }) {
    final entries = <Map<String, Object?>>[];
    // WebDAV servers disagree on the XML namespace prefix case (d:/D:).
    final responseRegex = RegExp(
      r'<(?:d|D):response>(.*?)</(?:d|D):response>',
      dotAll: true,
    );
    final hrefRegex = RegExp(r'<(?:d|D):href>(.*?)</(?:d|D):href>', dotAll: true);
    for (final match in responseRegex.allMatches(body)) {
      final block = match.group(1) ?? '';
      final hrefMatch = hrefRegex.firstMatch(block);
      if (hrefMatch == null) continue;
      final href = hrefMatch.group(1)?.trim() ?? '';
      entries.add({'href': href});
    }
    return entries;
  }

  Future<({int revision, DateTime? updatedAt})?> _tryReadRemoteMeta(
    WebDavSyncConfiguration configuration,
  ) async {
    try {
      final response = await _authorizedGetBytes(
        configuration.metaPath,
        configuration,
      );
      final raw = utf8.decode(response.data ?? const []);
      final value = jsonDecode(raw);
      if (value is! Map) return null;
      final map = Map<String, dynamic>.from(value);
      return (
        revision: (map['revision'] as num?)?.toInt() ?? 0,
        updatedAt: DateTime.tryParse(
          map['updatedAt']?.toString() ?? '',
        )?.toLocal(),
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<RemoteVaultInfo?> _tryReadRemoteMetaByBlob(
    WebDavSyncConfiguration configuration, {
    required String blobId,
  }) async {
    final metaConfig = WebDavSyncConfiguration(
      baseUrl: configuration.baseUrl,
      username: configuration.username,
      password: configuration.password,
      remotePath: configuration.remotePath,
      blobId: blobId,
      revision: 0,
    );
    try {
      final response = await _authorizedGetBytes(
        metaConfig.metaPath,
        metaConfig,
      );
      final raw = utf8.decode(response.data ?? const []);
      final value = jsonDecode(raw);
      if (value is! Map) return null;
      final map = Map<String, dynamic>.from(value);
      return RemoteVaultInfo(
        name: map['name']?.toString() ?? blobId,
        blobId: blobId,
        revision: (map['revision'] as num?)?.toInt() ?? 0,
        updatedAt: DateTime.tryParse(
          map['updatedAt']?.toString() ?? '',
        )?.toLocal(),
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<void> _putRemoteMeta(
    WebDavSyncConfiguration configuration, {
    required int revision,
    String? fingerprint,
    required String name,
  }) async {
    final meta = jsonEncode({
      'version': _metaVersion,
      'revision': revision,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'fingerprint': fingerprint,
      'name': name,
    });
    await _authorizedPutBytes(configuration.metaPath, meta, configuration);
  }

  String _baseName(String href) {
    var value = href.replaceFirst(RegExp(r'^.*?([^/]+)$'), r'$1');
    value = Uri.decodeComponent(value);
    return value;
  }
}
