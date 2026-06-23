import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:just_audio/just_audio.dart';
import 'package:sqflite/sqflite.dart';
import 'package:flutter/material.dart';
import 'package:memefolder/backend/download_manager.dart';
import 'package:memefolder/backend/custom_tags_store.dart';
import 'package:memefolder/backend/semantic_search/embeddings.dart';
import 'package:memefolder/backend/semantic_search/semantic_search_classes.dart';
import 'package:memefolder/backend/semantic_service.dart';
import 'package:memefolder/prefs.dart';
import 'package:memefolder/widgets/bubble_snackbar.dart';
import 'package:path/path.dart' as p;

final _player = AudioPlayer();
final _warnplayer = AudioPlayer();

class CancellationToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

Future<void> indexDirectory(
  String currentPath, {
  void Function(double progress)? onProgress,
  CancellationToken? cancelToken,
}) async {
  final dbPath = p.join(currentPath, '.memefolder.db');
  final tmpPath = '$dbPath.tmp';
  final dbExists = File(dbPath).existsSync();

  showBubble(
    Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.warning, color: Colors.white),
        const SizedBox(width: 12),
        Text(
          dbExists ? 'reindexing...' : 'initializing...',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w500,
            decoration: TextDecoration.none,
          ),
          softWrap: true,
        ),
      ],
    ),
  );

  onProgress?.call(0);

  try {
    final totalCount = await _countFiles(currentPath);

    await _initDB(currentPath, dbPath: tmpPath);
    await _scanAndIndex(
      currentPath,
      dbPath: tmpPath,
      totalCount: totalCount,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );

    if (cancelToken?.isCancelled ?? false) {
      await _cleanupTmp(tmpPath);
      _warnplayer.play();
      showBubble(
        const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cancel, color: Colors.white),
            SizedBox(width: 12),
            Text(
              'cancelled',
              style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w500,
                decoration: TextDecoration.none,
              ),
              softWrap: true,
            ),
          ],
        ),
      );
      return;
    }

    if (dbExists) {
      await File(dbPath).delete();
    }
    await File(tmpPath).rename(dbPath);
    onProgress?.call(1.0);

    // after metadata scan, auto-embed for each model
    final models = DownloadManager.instance.getInstalledModels();
    for (final manifest in models) {
      if (cancelToken?.isCancelled ?? false) break;
      await embedDirectory(
        currentPath,
        onProgress: onProgress != null ? (p, _) => onProgress(p) : null,
        manifest: manifest,
        cancelToken: cancelToken,
      );
    }
  } catch (e) {
    await _cleanupTmp(tmpPath);
    rethrow;
  }
}

Future<void> _cleanupTmp(String tmpPath) async {
  try {
    final f = File(tmpPath);
    if (await f.exists()) await f.delete();
    final wal = File('$tmpPath-wal');
    if (await wal.exists()) await wal.delete();
    final shm = File('$tmpPath-shm');
    if (await shm.exists()) await shm.delete();
  } catch (_) {}
}

Future<void> _initDB(String currentPath, {required String dbPath}) async {
  final db = await openDatabase(
    dbPath,
    version: 1,
    onConfigure: (db) async {
      await db.execute('PRAGMA foreign_keys = ON;');
      await db.execute('PRAGMA journal_mode = WAL;');
    },
    onCreate: (db, version) async {
      await _createSchema(db, currentPath);
    },
  );

  await db.close();
}

Future<Set<String>> getIndexedFiles(String rootPath) async {
  final dbPath = p.join(rootPath, '.memefolder.db');
  if (!File(dbPath).existsSync()) return {};

  try {
    final db = await openDatabase(dbPath, singleInstance: false);
    final results = await db.rawQuery('SELECT rel_path FROM files');
    await db.close();
    return results.map((r) {
      final relPath = r['rel_path'] as String;
      return p.join(rootPath, relPath);
    }).toSet();
  } catch (e) {
    debugPrint('Error reading indexed files: $e');
    return {};
  }
}

const _imageExts = {
  'jpg',
  'jpeg',
  'png',
  'gif',
  'webp',
  'avif',
  'heic',
  'heif',
  'bmp',
  'tiff',
  'tif',
  'ico',
  'apng',
};

const _videoExts = {
  'mp4',
  'webm',
  'mkv',
  'avi',
  'mov',
  'flv',
  'wmv',
  'ogv',
  '3gp',
  '3g2',
  'm4v',
  'ts',
  'mts',
  'm2ts',
  'vob',
};

const _audioExts = {
  'mp3',
  'ogg',
  'wav',
  'flac',
  'aac',
  'm4a',
  'opus',
  'wma',
  'aiff',
  'aif',
  'alac',
};

String _mediaTypeForExt(String? ext) {
  if (ext == null) return 'unknown';
  final e = ext.toLowerCase();
  if (_imageExts.contains(e)) return 'image';
  if (_videoExts.contains(e)) return 'video';
  if (_audioExts.contains(e)) return 'audio';
  return 'unknown';
}

Future<Map<String, String?>> _extractAudioMetadata(String filePath) async {
  try {
    final result = await Process.run('ffprobe', [
      '-v',
      'error',
      '-show_entries',
      'format_tags=artist,album,genre,date,comment,track',
      '-show_entries',
      'format=duration',
      '-of',
      'json',
      filePath,
    ]);

    if (result.exitCode != 0) return {};

    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>?;
    if (json == null) return {};

    final tags = json['format']?['tags'] as Map<String, dynamic>?;
    final duration = double.tryParse(
      json['format']?['duration']?.toString() ?? '',
    );

    return {
      'artist': tags?['artist']?.toString(),
      'album': tags?['album']?.toString(),
      'genre': tags?['genre']?.toString(),
      'year': tags?['date']?.toString(),
      'comment': tags?['comment']?.toString(),
      'track': tags?['track']?.toString(),
      'duration_ms': duration != null
          ? (duration * 1000).round().toString()
          : null,
    };
  } catch (_) {
    return {};
  }
}

Future<int> _countFiles(String rootPath) async {
  var count = 0;
  try {
    final dir = Directory(rootPath);
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File && !p.basename(entity.path).startsWith('.')) {
        count++;
      }
    }
  } catch (_) {}
  return count;
}

Future<void> _scanAndIndex(
  String rootPath, {
  required String dbPath,
  int totalCount = 0,
  void Function(double progress)? onProgress,
  CancellationToken? cancelToken,
}) async {
  final db = await openDatabase(dbPath);

  var indexedCount = 0;

  // small in-memory caches to avoid hammering SQLite
  final folderIdByRelPath = <String, int>{};
  final tagIdBySlug = <String, int>{};

  Future<int> ensureFolder(Transaction txn, String relPath) async {
    if (folderIdByRelPath.containsKey(relPath)) {
      return folderIdByRelPath[relPath]!;
    }
    final name = relPath.isEmpty ? p.basename(rootPath) : p.basename(relPath);
    final depth = relPath.isEmpty ? 0 : relPath.split('/').length;
    int? parentId;
    if (relPath.isNotEmpty) {
      final parentRel = p.dirname(relPath).replaceAll('\\', '/');
      final parentNorm = parentRel == '.' ? '' : parentRel;
      parentId = await ensureFolder(txn, parentNorm);
    }

    final dirPath = relPath.isEmpty ? rootPath : p.join(rootPath, relPath);
    final stat = await Directory(dirPath).stat();

    final id = await txn.insert('folders', {
      'rel_path': relPath,
      'name': name,
      'depth': depth,
      'parent_id': parentId,
      'mtime': stat.modified.millisecondsSinceEpoch,
      'indexed_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);

    final folderId = id == 0
        ? (await txn.query(
                'folders',
                columns: ['id'],
                where: 'rel_path = ?',
                whereArgs: [relPath],
              )).first['id']
              as int
        : id;

    folderIdByRelPath[relPath] = folderId;
    return folderId;
  }

  Future<int> ensureTag(
    Transaction txn,
    String slug,
    String display,
    String kind,
  ) async {
    if (tagIdBySlug.containsKey(slug)) {
      return tagIdBySlug[slug]!;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = await txn.insert('tags', {
      'slug': slug,
      'display_name': display,
      'kind': kind,
      'color': null,
      'description': null,
      'created_at': now,
      'usage_count': 0,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    final tagId = id == 0
        ? (await txn.query(
                'tags',
                columns: ['id'],
                where: 'slug = ?',
                whereArgs: [slug],
              )).first['id']
              as int
        : id;

    tagIdBySlug[slug] = tagId;
    return tagId;
  }

  Future<void> attachTag(
    Transaction txn,
    int fileId,
    int tagId,
    String source,
  ) async {
    await txn.insert('file_tags', {
      'file_id': fileId,
      'tag_id': tagId,
      'source': source,
      'confidence': null,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await txn.rawUpdate(
      'UPDATE tags SET usage_count = usage_count + 1 WHERE id = ?',
      [tagId],
    );
  }

  Future<void> scanFolder(Transaction txn, String relPath, int depth) async {
    if (depth > 5) return; // cap at depth 5
    await _player.setAsset('Assets/SFX/done.mp3');
    _player.load();
    await _warnplayer.setAsset('Assets/SFX/warning.mp3');
    _warnplayer.load();

    final folderId = await ensureFolder(txn, relPath);
    final dirPath = relPath.isEmpty ? rootPath : p.join(rootPath, relPath);

    final dir = Directory(dirPath);
    if (!await dir.exists()) return;

    final entries = dir.listSync(followLinks: false);
    for (final entity in entries) {
      if (cancelToken?.isCancelled ?? false) return;
      final name = p.basename(entity.path);
      if (name == '.memefolder.db' ||
          name.startsWith('.memefolder.db') ||
          name == '.memefolder.db.tmp') {
        continue;
      }
      if (entity is Directory) {
        final subRel = relPath.isEmpty
            ? name
            : p.join(relPath, name).replaceAll('\\', '/');
        await scanFolder(txn, subRel, depth + 1);
        await txn.rawUpdate(
          'UPDATE folders SET folder_count = folder_count + 1 WHERE id = ?',
          [folderId],
        );
      } else if (entity is File) {
        final fileRel = relPath.isEmpty
            ? name
            : p.join(relPath, name).replaceAll('\\', '/');

        final stat = entity.statSync();
        final ext = p.extension(name).toLowerCase().replaceFirst('.', '');
        final stem = p.basenameWithoutExtension(name);
        final mediaType = _mediaTypeForExt(ext);

        Map<String, String?> audioMeta = {};
        if (mediaType == 'audio') {
          audioMeta = await _extractAudioMetadata(entity.path);
        }

        final fileId = await txn.insert('files', {
          'folder_id': folderId,
          'rel_path': fileRel,
          'name': name,
          'stem': stem,
          'ext': ext.isEmpty ? null : ext,
          'media_type': mediaType,
          'size_bytes': stat.size,
          'mtime': stat.modified.millisecondsSinceEpoch,
          'ctime': stat.changed.millisecondsSinceEpoch,
          'duration_ms': audioMeta['duration_ms'] != null
              ? int.tryParse(audioMeta['duration_ms']!)
              : null,
          'artist': audioMeta['artist'],
          'album': audioMeta['album'],
          'genre': audioMeta['genre'],
          'year': audioMeta['year'] != null
              ? int.tryParse(audioMeta['year']!)
              : null,
          'comment': audioMeta['comment'],
          'track': audioMeta['track'],
          'indexed_at': DateTime.now().millisecondsSinceEpoch,
          'status': 'indexed',
        }, conflictAlgorithm: ConflictAlgorithm.replace);

        await txn.rawUpdate(
          'UPDATE folders SET file_count = file_count + 1 WHERE id = ?',
          [folderId],
        );

        indexedCount++;
        if (totalCount > 0) {
          onProgress?.call(indexedCount / totalCount);
        }

        if (relPath.isNotEmpty) {
          final parts = relPath.split('/');
          final prefixes = <String>[];
          for (var i = 0; i < parts.length; i++) {
            prefixes.add(parts.sublist(0, i + 1).join('/'));
          }
          for (final prefix in prefixes) {
            final depthParts = prefix.split('/');
            if (depthParts.length > 5) break;

            final slug = 'folder:$prefix';
            final display = '@$prefix';
            final tagId = await ensureTag(txn, slug, display, 'folder');
            await attachTag(txn, fileId, tagId, 'folder');
          }
        }

        switch (mediaType) {
          case 'image':
            {
              final tagId = await ensureTag(txn, 'image', '@image', 'type');
              await attachTag(txn, fileId, tagId, 'system');
              break;
            }
          case 'video':
            {
              final tagId = await ensureTag(txn, 'video', '@video', 'type');
              await attachTag(txn, fileId, tagId, 'system');
              break;
            }
          case 'audio':
            {
              final tagId = await ensureTag(txn, 'audio', '@audio', 'type');
              await attachTag(txn, fileId, tagId, 'system');
              break;
            }
        }

        if (ext.isNotEmpty) {
          final slug = '.${ext.toLowerCase()}';
          final display = '@.$ext';
          final tagId = await ensureTag(txn, slug, display, 'ext');
          await attachTag(txn, fileId, tagId, 'system');
        }
      }
    }
  }

  await db.transaction((txn) async {
    await scanFolder(txn, '', 0);
    final now = DateTime.now().millisecondsSinceEpoch;
    await txn.update('roots', {'indexed_at': now}, where: 'id = 1');
  });

  await db.close();
  await _congratulateScanEnd(); // awesome!! we're done
}

Future<void> _congratulateScanEnd() async {
  showBubble(
    const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.check_circle, color: Colors.white),
        SizedBox(width: 12),
        Text(
          'done!',
          style: TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w500,
            decoration: TextDecoration.none,
          ),
          softWrap: true,
        ),
      ],
    ),
  );
}

// boring stuff

Future<void> _createSchema(Database db, String currentPath) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  final rootName = p.basename(currentPath);

  await db.execute('''
    CREATE TABLE roots (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      root_path TEXT NOT NULL,
      root_name TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      indexed_at INTEGER,
      model_tier TEXT NOT NULL DEFAULT 'low',
      model_name TEXT NOT NULL DEFAULT 'clip-vit-b32',
      app_version TEXT,
      schema_version INTEGER NOT NULL
    );
  ''');

  await db.execute('''
    CREATE TABLE folders (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      rel_path TEXT NOT NULL UNIQUE,
      name TEXT NOT NULL,
      depth INTEGER NOT NULL CHECK(depth >= 0 AND depth <= 5),
      parent_id INTEGER REFERENCES folders(id) ON DELETE CASCADE,
      file_count INTEGER NOT NULL DEFAULT 0,
      folder_count INTEGER NOT NULL DEFAULT 0,
      mtime INTEGER,
      indexed_at INTEGER
    );
  ''');

  await db.execute('''
    CREATE TABLE files (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
      rel_path TEXT NOT NULL UNIQUE,
      name TEXT NOT NULL,
      stem TEXT NOT NULL,
      ext TEXT,
      media_type TEXT NOT NULL,
      size_bytes INTEGER NOT NULL DEFAULT 0,
      mtime INTEGER,
      ctime INTEGER,
      sha256 TEXT,
      width INTEGER,
      height INTEGER,
      duration_ms INTEGER,
      fps REAL,
      has_audio INTEGER NOT NULL DEFAULT 0,
      has_text INTEGER NOT NULL DEFAULT 0,
      has_speech INTEGER NOT NULL DEFAULT 0,
      has_motion INTEGER NOT NULL DEFAULT 0,
      artist TEXT,
      album TEXT,
      genre TEXT,
      year INTEGER,
      comment TEXT,
      track TEXT,
      indexed_at INTEGER,
      status TEXT NOT NULL DEFAULT 'indexed'
    );
  ''');

  await db.execute('''
    CREATE TABLE tags (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      slug TEXT NOT NULL UNIQUE,
      display_name TEXT NOT NULL,
      kind TEXT NOT NULL,
      color TEXT,
      description TEXT,
      created_at INTEGER,
      usage_count INTEGER NOT NULL DEFAULT 0
    );
  ''');

  await db.execute('''
    CREATE TABLE file_tags (
      file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
      tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
      source TEXT NOT NULL,
      confidence REAL,
      PRIMARY KEY (file_id, tag_id, source)
    );
  ''');

  await db.execute('''
    CREATE TABLE file_text (
      file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
      ocr_text TEXT,
      transcript_text TEXT,
      ai_description TEXT,
      filename_hint TEXT,
      combined_text TEXT
    );
  ''');

  await db.execute('''
    CREATE TABLE file_segments (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
      segment_index INTEGER NOT NULL,
      start_ms INTEGER NOT NULL,
      end_ms INTEGER NOT NULL,
      transcript_text TEXT,
      ocr_text TEXT,
      ai_description TEXT
    );
  ''');

  await db.execute('''
    CREATE TABLE file_embeddings (
      file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
      modality TEXT NOT NULL,          -- image / text
      model_name TEXT NOT NULL,        -- clip-vit-b32
      dims INTEGER NOT NULL,
      embedding BLOB NOT NULL,
      created_at INTEGER NOT NULL
    );
  ''');

  await db.execute('''
    CREATE TABLE segment_embeddings (
      segment_id INTEGER PRIMARY KEY REFERENCES file_segments(id) ON DELETE CASCADE,
      embedding BLOB NOT NULL,
      dims INTEGER NOT NULL,
      modality TEXT NOT NULL,
      model_name TEXT NOT NULL
    );
  ''');

  await db.execute('''
    CREATE INDEX idx_folders_parent_id ON folders(parent_id);
  ''');

  await db.execute('''
    CREATE INDEX idx_files_folder_id ON files(folder_id);
  ''');

  await db.execute('''
    CREATE INDEX idx_files_rel_path ON files(rel_path);
  ''');

  await db.execute('''
    CREATE INDEX idx_files_ext ON files(ext);
  ''');

  await db.execute('''
    CREATE INDEX idx_files_media_type ON files(media_type);
  ''');

  await db.execute('''
    CREATE INDEX idx_files_status ON files(status);
  ''');

  await db.execute('''
    CREATE INDEX idx_file_tags_tag_id ON file_tags(tag_id);
  ''');

  await db.execute('''
    CREATE INDEX idx_file_tags_file_id ON file_tags(file_id);
  ''');

  await db.execute('''
    CREATE INDEX idx_tags_slug ON tags(slug);
  ''');

  await db.execute('''
    CREATE TABLE IF NOT EXISTS embedding_failures (
      file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
      reason TEXT NOT NULL,
      failed_at INTEGER NOT NULL
    );
  ''');

  await db.insert('roots', {
    'id': 1,
    'root_path': currentPath,
    'root_name': rootName,
    'created_at': now,
    'indexed_at': null,
    'model_tier': 'low',
    'model_name': 'clip-vit-b32',
    'app_version': null,
    'schema_version': 1,
  });

  await db.insert('folders', {
    'rel_path': '',
    'name': rootName,
    'depth': 0,
    'parent_id': null,
    'file_count': 0,
    'folder_count': 0,
    'mtime': Directory(currentPath).statSync().modified.millisecondsSinceEpoch,
    'indexed_at': null,
  });

  // seed base system tags
  final seedTags = [
    {
      'slug': 'image',
      'display_name': '@image',
      'kind': 'type',
      'color': '#b1f024',
    },
    {
      'slug': 'picture',
      'display_name': '@picture',
      'kind': 'type',
      'color': '#b1f024',
    },
    {
      'slug': 'photo',
      'display_name': '@photo',
      'kind': 'type',
      'color': '#b1f024',
    },
    {
      'slug': 'video',
      'display_name': '@video',
      'kind': 'type',
      'color': '#b1f024',
    },
    {
      'slug': 'audio',
      'display_name': '@audio',
      'kind': 'type',
      'color': '#b1f024',
    },
    {
      'slug': 'sound',
      'display_name': '@sound',
      'kind': 'type',
      'color': '#b1f024',
    },

    {
      'slug': 'has:audio',
      'display_name': '@has:audio',
      'kind': 'modality',
      'color': '#f36e36',
    },
    {
      'slug': 'has:speech',
      'display_name': '@has:speech',
      'kind': 'modality',
      'color': '#f36e36',
    },
    {
      'slug': 'has:text',
      'display_name': '@has:text',
      'kind': 'modality',
      'color': '#f36e36',
    },
    {
      'slug': 'has:motion',
      'display_name': '@has:motion',
      'kind': 'modality',
      'color': '#f36e36',
    },
  ];

  for (final tag in seedTags) {
    await db.insert('tags', {
      ...tag,
      'description': null,
      'created_at': now,
      'usage_count': 0,
    });
  }
}

// embedding indexer

class _EmbedPassResult {
  final int embedded;
  final int failed;
  const _EmbedPassResult({required this.embedded, required this.failed});
}

Future<SemanticSearchService> _initService(
  String modelDir,
  bool useGpu, {
  String? label,
}) async {
  if (label != null) {
    showBubble(
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            'loading $label...',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w500,
              decoration: TextDecoration.none,
            ),
            softWrap: true,
          ),
        ],
      ),
    );
  }
  final config = SemanticSearchConfig(
    activeModel: EmbeddingModelKind.clipVitB32,
    models: {
      EmbeddingModelKind.clipVitB32: ModelInstallInfo(
        kind: EmbeddingModelKind.clipVitB32,
        name: 'CLIP ViT-B/32',
        installed: true,
        enabled: true,
        modelDir: modelDir,
      ),
    },
  );
  final service = SemanticSearchService(config, useGpu: useGpu);
  await service.initialize();
  return service;
}

Future<_EmbedPassResult> _embedPass(
  Database db,
  String rootPath,
  List<Map<String, Object?>> rows,
  String modalityPass, {
  required ModelManifest? manifest,
  required String modelDir,
  required bool useGpu,
  CancellationToken? cancelToken,
  void Function(double, String)? onProgress,
}) async {
  final isText = modalityPass == 'text';
  final service = await _initService(
    modelDir,
    useGpu,
    label: '${manifest?.name ?? 'model'} ($modalityPass)',
  );
  if (!service.isReady) return const _EmbedPassResult(embedded: 0, failed: 0);

  var embedded = 0;
  var failed = 0;

  try {
    for (int i = 0; i < rows.length; i++) {
      if (cancelToken?.isCancelled ?? false) break;

      final row = rows[i];
      final fileId = row['id'] as int;
      final relPath = row['rel_path'] as String;
      final mediaType = row['media_type'] as String;
      final name = row['name'] as String;
      final stem = row['stem'] as String;
      final combinedText = row['combined_text'] as String?;
      final aiDesc = row['ai_description'] as String?;
      final artist = row['artist'] as String?;
      final album = row['album'] as String?;
      final genre = row['genre'] as String?;
      final year = row['year'] as int?;
      final comment = row['comment'] as String?;

      onProgress?.call(i / rows.length, name);

      try {
        if (isText) {
          final textContext = _buildTextContext(
            stem: stem,
            name: name,
            combinedText: combinedText,
            aiDesc: aiDesc,
            artist: artist,
            album: album,
            genre: genre,
            year: year,
            comment: comment,
            tags: mediaType == 'image'
                ? []
                : await getFileTags(rootPath, p.join(rootPath, relPath)),
          );
          final vec = await service.embedText(textContext);
          await _storeEmbedding(
            db,
            fileId,
            vec,
            'text',
            embeddingHint: textContext,
          );
        } else {
          final file = File(p.join(rootPath, relPath));
          if (await file.exists()) {
            final vec = await service.embedImageFile(file);
            await _storeEmbedding(
              db,
              fileId,
              vec,
              'image',
              embeddingHint: '[image embedding]',
            );
          }
        }
        embedded++;
      } catch (e) {
        failed++;
        debugPrint('embed $modalityPass failed for $relPath: $e');
        await _storeFailure(db, fileId, '$e');
        _warnplayer.play();
      }
    }
  } finally {
    await service.backend?.dispose();
  }

  return _EmbedPassResult(embedded: embedded, failed: failed);
}

Future<_EmbedPassResult> _embedKeyframePass(
  Database db,
  String rootPath,
  List<Map<String, Object?>> rows, {
  required bool extractVideoKeyframes,
  required bool extractAudioKeyframes,
  int videoFrameCount = 1,
  required ModelManifest? manifest,
  required String modelDir,
  required bool useGpu,
  CancellationToken? cancelToken,
  void Function(double, String)? onProgress,
}) async {
  final service = await _initService(
    modelDir,
    useGpu,
    label: '${manifest?.name ?? 'model'} (keyframes)',
  );
  if (!service.isReady) return const _EmbedPassResult(embedded: 0, failed: 0);

  var embedded = 0;
  var failed = 0;

  try {
    for (int i = 0; i < rows.length; i++) {
      if (cancelToken?.isCancelled ?? false) break;

      final row = rows[i];
      final fileId = row['id'] as int;
      final relPath = row['rel_path'] as String;
      final mediaType = row['media_type'] as String;
      final name = row['name'] as String;
      final absPath = p.join(rootPath, relPath);

      onProgress?.call(i / rows.length, name);

      try {
        if (mediaType == 'video' && extractVideoKeyframes) {
          if (videoFrameCount > 1) {
            // multi-frame: extract N keyframes, average embeddings
            final frames = await _extractVideoKeyframes(
              absPath,
              videoFrameCount,
            );
            if (frames.isNotEmpty) {
              final vecs = <Float32List>[];
              for (final f in frames) {
                final v = await service.embedImageFile(f);
                vecs.add(v.values);
                await f.delete();
              }
              final avg = Float32List(vecs.first.length);
              for (final v in vecs) {
                for (int j = 0; j < avg.length; j++) avg[j] += v[j];
              }
              for (int j = 0; j < avg.length; j++) avg[j] /= vecs.length;
              final vec = EmbeddingVector(
                values: avg,
                model: EmbeddingModelKind.clipVitB32,
                modality: EmbeddingModality.image,
                dims: avg.length,
              );
              await _storeEmbedding(
                db,
                fileId,
                vec,
                'video',
                embeddingHint: '[${videoFrameCount}-frame video embedding]',
              );
            }
          } else {
            final keyframe = await _extractVideoKeyframe(absPath);
            if (keyframe != null) {
              final vec = await service.embedImageFile(keyframe);
              await _storeEmbedding(
                db,
                fileId,
                vec,
                'image',
                embeddingHint: '[video keyframe embedding]',
              );
              await keyframe.delete();
            }
          }
        } else if (mediaType == 'audio' && extractAudioKeyframes) {
          final keyframe = await _extractAudioKeyframe(absPath);
          if (keyframe != null) {
            final vec = await service.embedImageFile(keyframe);
            await _storeEmbedding(
              db,
              fileId,
              vec,
              'image',
              embeddingHint: '[audio spectrogram embedding]',
            );
            await keyframe.delete();
          }
        } else {
          continue;
        }
        embedded++;
      } catch (e) {
        failed++;
        debugPrint('keyframe embed failed for $relPath: $e');
        await _storeFailure(db, fileId, '$e');
        _warnplayer.play();
      }
    }
  } finally {
    await service.backend?.dispose();
  }

  return _EmbedPassResult(embedded: embedded, failed: failed);
}

Future<void> embedDirectory(
  String rootPath, {
  void Function(double progress, String currentFile)? onProgress,
  CancellationToken? cancelToken,
  ModelManifest? manifest,
}) async {
  final dbPath = p.join(rootPath, '.memefolder.db');
  if (!File(dbPath).existsSync()) return;

  final embedImages = manifest?.supportsImage ?? true;
  final embedTexts = manifest?.supportsText ?? true;
  final extractVideoKeyframes =
      manifest?.supportsVideo ?? manifest?.supportsImage ?? false;
  final extractAudioKeyframes =
      manifest?.supportsAudio ?? manifest?.supportsImage ?? false;
  final videoFrameCount = manifest?.supportsVideo == true ? 6 : 1;

  final modelDir = findModelDir();
  if (modelDir == null) return;

  final useGpu = PlayerPrefs.getBool(PlayerPrefs.gpuAccelerationKey, true);

  try {
    final db = await openDatabase(dbPath, singleInstance: false);

    await db.execute('''
      CREATE TABLE IF NOT EXISTS embedding_failures (
        file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
        reason TEXT NOT NULL,
        failed_at INTEGER NOT NULL
      );
    ''');

    await db.execute('''
      DELETE FROM file_embeddings WHERE file_id IN (
        SELECT id FROM files WHERE name LIKE '.memefolder.db%'
      );
    ''');
    await db.execute('''
      DELETE FROM file_text WHERE file_id IN (
        SELECT id FROM files WHERE name LIKE '.memefolder.db%'
      );
    ''');
    await db.execute('''
      DELETE FROM files WHERE name LIKE '.memefolder.db%'
    ''');

    final rows = await db.rawQuery('''
      SELECT f.id, f.rel_path, f.media_type, f.name, f.stem,
             ft.combined_text, ft.ai_description,
             f.artist, f.album, f.genre, f.year, f.comment
      FROM files f
      LEFT JOIN file_text ft ON ft.file_id = f.id
      LEFT JOIN file_embeddings fe ON fe.file_id = f.id
      WHERE fe.file_id IS NULL
    ''');

    final totalCount = rows.length;
    if (totalCount == 0) {
      await db.close();
      return;
    }

    var embeddedCount = 0;
    var failedCount = 0;

    // lazy load/unload per modality:
    // each pass initializes service → processes files → disposes

    if (embedTexts) {
      final textRows = rows.where((r) {
        final mt = r['media_type'] as String;
        return mt != 'image';
      }).toList();
      if (textRows.isNotEmpty) {
        showBubble(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.text_fields, color: Colors.white),
              const SizedBox(width: 12),
              Text(
                manifest != null
                    ? '${manifest.name}: embedding text...'
                    : 'embedding text...',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.none,
                ),
                softWrap: true,
              ),
            ],
          ),
        );
        final r = await _embedPass(
          db,
          rootPath,
          textRows,
          'text',
          manifest: manifest,
          modelDir: modelDir,
          useGpu: useGpu,
          cancelToken: cancelToken,
          onProgress: (p, f) => onProgress?.call(
            (embeddedCount + p * textRows.length) / totalCount,
            f,
          ),
        );
        embeddedCount += r.embedded;
        failedCount += r.failed;
        if (cancelToken?.isCancelled ?? false) {
          await db.close();
          return;
        }
      }
    }

    if (embedImages) {
      final imgRows = rows.where((r) {
        final mt = r['media_type'] as String;
        return mt == 'image';
      }).toList();
      if (imgRows.isNotEmpty) {
        showBubble(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.image, color: Colors.white),
              const SizedBox(width: 12),
              Text(
                manifest != null
                    ? '${manifest.name}: embedding images...'
                    : 'embedding images...',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.none,
                ),
                softWrap: true,
              ),
            ],
          ),
        );
        final r = await _embedPass(
          db,
          rootPath,
          imgRows,
          'image',
          manifest: manifest,
          modelDir: modelDir,
          useGpu: useGpu,
          cancelToken: cancelToken,
          onProgress: (p, f) => onProgress?.call(
            (embeddedCount + p * imgRows.length) / totalCount,
            f,
          ),
        );
        embeddedCount += r.embedded;
        failedCount += r.failed;
        if (cancelToken?.isCancelled ?? false) {
          await db.close();
          return;
        }
      }
    }

    if (extractVideoKeyframes || extractAudioKeyframes) {
      final kfRows = rows.where((r) {
        final mt = r['media_type'] as String;
        return mt == 'video' || mt == 'audio';
      }).toList();
      if (kfRows.isNotEmpty) {
        showBubble(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.movie, color: Colors.white),
              const SizedBox(width: 12),
              Text(
                manifest != null
                    ? '${manifest.name}: keyframes...'
                    : 'keyframes...',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.none,
                ),
                softWrap: true,
              ),
            ],
          ),
        );
        final r = await _embedKeyframePass(
          db,
          rootPath,
          kfRows,
          extractVideoKeyframes: extractVideoKeyframes,
          extractAudioKeyframes: extractAudioKeyframes,
          videoFrameCount: videoFrameCount,
          manifest: manifest,
          modelDir: modelDir,
          useGpu: useGpu,
          cancelToken: cancelToken,
          onProgress: (p, f) => onProgress?.call(
            (embeddedCount + p * kfRows.length) / totalCount,
            f,
          ),
        );
        embeddedCount += r.embedded;
        failedCount += r.failed;
      }
    }

    await db.close();
    onProgress?.call(1.0, '');

    final msg = failedCount > 0
        ? 'embedded $embeddedCount files ($failedCount failed)'
        : 'embedded $embeddedCount files';

    await _player.play();
    showBubble(
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            failedCount > 0 ? Icons.warning : Icons.check_circle,
            color: Colors.white,
          ),
          const SizedBox(width: 12),
          Text(
            msg,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w500,
              decoration: TextDecoration.none,
            ),
            softWrap: true,
          ),
        ],
      ),
    );
  } catch (e) {
    showBubble(
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error, color: Colors.white),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              'Embedding error: $e',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w500,
                decoration: TextDecoration.none,
              ),
              softWrap: true,
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _storeEmbedding(
  Database db,
  int fileId,
  EmbeddingVector vec,
  String modality, {
  String? embeddingHint,
}) async {
  final blob = SemanticSearchService.embeddingToBlob(vec);
  await db.insert('file_embeddings', {
    'file_id': fileId,
    'modality': modality,
    'model_name': 'clip-vit-b32',
    'dims': vec.dims,
    'embedding': blob,
    'created_at': DateTime.now().millisecondsSinceEpoch,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  // store the text hint used for embedding in file_text.combined_text
  if (embeddingHint != null) {
    await db.rawUpdate(
      '''
      UPDATE file_text
      SET combined_text = CASE
        WHEN combined_text IS NULL THEN ?
        WHEN combined_text = '' THEN ?
        ELSE combined_text || '\n' || ?
      END
      WHERE file_id = ?
    ''',
      [embeddingHint, embeddingHint, embeddingHint, fileId],
    );
  }
}

Future<void> _storeFailure(Database db, int fileId, String reason) async {
  await db.insert('embedding_failures', {
    'file_id': fileId,
    'reason': reason,
    'failed_at': DateTime.now().millisecondsSinceEpoch,
  }, conflictAlgorithm: ConflictAlgorithm.replace);
}

// get user-assigned tags for a file (returns display names like "@farticles").
Future<List<String>> getFileTags(String rootPath, String absPath) async {
  final dbPath = p.join(rootPath, '.memefolder.db');
  if (!File(dbPath).existsSync()) return [];

  try {
    final db = await openDatabase(dbPath, singleInstance: false);
    final rows = await db.rawQuery(
      '''
      SELECT t.display_name
      FROM file_tags ft
      JOIN files f ON f.id = ft.file_id
      JOIN tags t ON t.id = ft.tag_id
      WHERE f.rel_path = ? AND ft.source = 'user'
      ORDER BY t.display_name
    ''',
      [p.relative(absPath, from: rootPath)],
    );
    await db.close();
    return rows.map((r) => r['display_name'] as String).toList();
  } catch (e) {
    debugPrint('[tags] getFileTags error: $e');
    return [];
  }
}

Future<void> addFileTag(String rootPath, String absPath, String tagName) async {
  final dbPath = p.join(rootPath, '.memefolder.db');
  if (!File(dbPath).existsSync()) return;

  final slug = tagName.replaceFirst('@', '').toLowerCase().trim();
  if (slug.isEmpty) return;
  final displayName = '@$slug';

  try {
    final db = await openDatabase(dbPath, singleInstance: false);

    // ensure tag exists in tags table
    var rows = await db.rawQuery('SELECT id FROM tags WHERE slug = ?', [slug]);
    int tagId;
    if (rows.isNotEmpty) {
      tagId = rows.first['id'] as int;
    } else {
      tagId = await db.insert('tags', {
        'slug': slug,
        'display_name': displayName,
        'kind': 'custom',
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'usage_count': 0,
      });
    }

    // get file id
    final relPath = p.relative(absPath, from: rootPath);
    rows = await db.rawQuery('SELECT id FROM files WHERE rel_path = ?', [
      relPath,
    ]);
    if (rows.isEmpty) {
      await db.close();
      return;
    }
    final fileId = rows.first['id'] as int;

    // attach tag
    await db.insert('file_tags', {
      'file_id': fileId,
      'tag_id': tagId,
      'source': 'user',
    }, conflictAlgorithm: ConflictAlgorithm.ignore);

    // bump usage count
    await db.rawUpdate(
      'UPDATE tags SET usage_count = usage_count + 1 WHERE id = ?',
      [tagId],
    );

    await db.close();

    // sync to CustomTagsStore for autocomplete
    CustomTagsStore.instance.refresh();
  } catch (e) {
    debugPrint('[tags] addFileTag error: $e');
  }
}

// remove a custom tag from a file.
Future<void> removeFileTag(
  String rootPath,
  String absPath,
  String tagName,
) async {
  final dbPath = p.join(rootPath, '.memefolder.db');
  if (!File(dbPath).existsSync()) return;

  final slug = tagName.replaceFirst('@', '').toLowerCase().trim();
  if (slug.isEmpty) return;

  try {
    final db = await openDatabase(dbPath, singleInstance: false);

    final relPath = p.relative(absPath, from: rootPath);
    await db.rawDelete(
      '''
      DELETE FROM file_tags
      WHERE file_id = (SELECT id FROM files WHERE rel_path = ?)
        AND tag_id = (SELECT id FROM tags WHERE slug = ?)
        AND source = 'user'
    ''',
      [relPath, slug],
    );

    await db.rawUpdate(
      'UPDATE tags SET usage_count = MAX(0, usage_count - 1) WHERE slug = ?',
      [slug],
    );

    await db.close();
  } catch (e) {
    debugPrint('[tags] removeFileTag error: $e');
  }
}

/// get all available custom tags
Future<List<String>> getAvailableTags(String rootPath) async {
  final dbPath = p.join(rootPath, '.memefolder.db');
  Set<String> allTags = {};

  // from CustomTagsStore (user-defined)
  allTags.addAll(CustomTagsStore.instance.tags);

  // from DB (any custom tags that were created via addFileTag)
  if (File(dbPath).existsSync()) {
    try {
      final db = await openDatabase(dbPath, singleInstance: false);
      final rows = await db.rawQuery(
        "SELECT slug FROM tags WHERE kind = 'custom'",
      );
      await db.close();
      for (final r in rows) {
        allTags.add(r['slug'] as String);
      }
    } catch (_) {}
  }

  final sorted = allTags.toList()..sort();
  return sorted;
}

// get files that failed embedding, as map of absPath ->  reason.
Future<Map<String, String>> getEmbeddingFailures(String rootPath) async {
  final dbPath = p.join(rootPath, '.memefolder.db');
  if (!File(dbPath).existsSync()) return {};

  try {
    final db = await openDatabase(dbPath, singleInstance: false);

    // ensure table exists (for old DBs created before this table)
    await db.execute('''
      CREATE TABLE IF NOT EXISTS embedding_failures (
        file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
        reason TEXT NOT NULL,
        failed_at INTEGER NOT NULL
      );
    ''');

    final rows = await db.rawQuery('''
      SELECT f.rel_path, ef.reason
      FROM embedding_failures ef
      JOIN files f ON f.id = ef.file_id
    ''');
    await db.close();

    return {
      for (final r in rows)
        p.join(rootPath, r['rel_path'] as String): r['reason'] as String,
    };
  } catch (e) {
    debugPrint('Error reading embedding failures: $e');
    return {};
  }
}

// get embedding info for a file (for preview/debug).
Future<Map<String, dynamic>?> getEmbeddingInfo(
  String rootPath,
  String relPath,
) async {
  final dbPath = p.join(rootPath, '.memefolder.db');
  if (!File(dbPath).existsSync()) return null;

  try {
    final db = await openDatabase(dbPath, singleInstance: false);
    final rows = await db.rawQuery(
      '''
      SELECT fe.modality, fe.model_name, fe.dims, fe.created_at,
             ft.combined_text, ft.ai_description
      FROM file_embeddings fe
      JOIN files f ON f.id = fe.file_id
      LEFT JOIN file_text ft ON ft.file_id = f.id
      WHERE f.rel_path = ?
    ''',
      [relPath],
    );
    await db.close();

    if (rows.isEmpty) return null;
    final row = rows.first;
    return {
      'modality': row['modality'],
      'model': row['model_name'],
      'dims': row['dims'],
      'hint': row['combined_text'],
      'ai_description': row['ai_description'],
      'created_at': row['created_at'],
    };
  } catch (_) {
    return null;
  }
}

String _buildTextContext({
  required String stem,
  required String name,
  String? combinedText,
  String? aiDesc,
  String? artist,
  String? album,
  String? genre,
  int? year,
  String? comment,
  List<String> tags = const [],
}) {
  final parts = <String>['file: $stem'];
  if (tags.isNotEmpty) parts.add('tags: ${tags.join(", ")}');
  if (aiDesc != null && aiDesc.isNotEmpty) parts.add('description: $aiDesc');
  if (combinedText != null && combinedText.isNotEmpty) {
    parts.add('text: $combinedText');
  }
  if (artist != null && artist.isNotEmpty) parts.add('artist: $artist');
  if (album != null && album.isNotEmpty) parts.add('album: $album');
  if (genre != null && genre.isNotEmpty) parts.add('genre: $genre');
  if (year != null) parts.add('year: $year');
  if (comment != null && comment.isNotEmpty) parts.add('comment: $comment');
  return parts.join(', ');
}

String? findModelDir() {
  // try resolving from the executable location (works in both dev and packaged)
  final exeDir = File(Platform.resolvedExecutable).parent;

  // possible locations relative to executable
  final candidates = <String>[];

  // during flutter run: exe is in build/linux/x64/debug/
  // project root is 4 levels up
  candidates.add('${exeDir.path}/../../../../searchmodels/low-tier-clip');

  // during packaged app: exe is in bundle/
  // project root might be elsewhere, check common locations
  candidates.add('${exeDir.path}/searchmodels/low-tier-clip');

  // check CWD (works during flutter run from project root)
  candidates.add('searchmodels/low-tier-clip');

  // check home directory for downloaded models
  final home = Platform.environment['HOME'] ?? '';
  if (home.isNotEmpty) {
    candidates.add('$home/.local/share/memefolder/models/low-tier-clip');
  }

  for (final candidate in candidates) {
    final dir = Directory(candidate);
    if (dir.existsSync()) {
      // verify it has the required files
      final visionFile = File('${dir.path}/vision_model.onnx');
      if (visionFile.existsSync()) return dir.path;
    }
  }

  // last resort: search upward from exe for searchmodels directory
  var current = exeDir;
  for (var i = 0; i < 6; i++) {
    final smDir = Directory('${current.path}/searchmodels/low-tier-clip');
    if (smDir.existsSync()) {
      final visionFile = File('${smDir.path}/vision_model.onnx');
      if (visionFile.existsSync()) return smDir.path;
    }
    current = current.parent;
    if (current.path == '/') break;
  }

  return null;
}

bool isEmbeddingModelValid() => findModelDir() != null;

Future<File?> _extractVideoKeyframe(String videoPath) async {
  try {
    final tmpDir = Directory.systemTemp.createTempSync('clip_keyframe_');
    final outputPath = '${tmpDir.path}/frame.jpg';

    final result = await Process.run('ffmpeg', [
      '-i',
      videoPath,
      '-vframes',
      '1',
      '-q:v',
      '2',
      '-y',
      outputPath,
    ]);

    if (result.exitCode == 0 && File(outputPath).existsSync()) {
      return File(outputPath);
    }
    tmpDir.deleteSync(recursive: true);
  } catch (_) {}
  return null;
}

Future<List<File>> _extractVideoKeyframes(String videoPath, int count) async {
  final files = <File>[];
  try {
    // get video duration
    final probe = await Process.run('ffprobe', [
      '-v',
      'error',
      '-show_entries',
      'format=duration',
      '-of',
      'csv=p=0',
      videoPath,
    ]);
    final duration = double.tryParse(probe.stdout.toString().trim());
    if (duration == null || duration <= 0) return files;

    final tmpDir = Directory.systemTemp.createTempSync('clip_keyframes_');
    final interval = duration / (count + 1); // skip first/last

    for (int i = 1; i <= count; i++) {
      final seek = interval * i;
      final outPath = '${tmpDir.path}/frame_$i.jpg';
      final result = await Process.run('ffmpeg', [
        '-ss',
        seek.toStringAsFixed(2),
        '-i',
        videoPath,
        '-vframes',
        '1',
        '-q:v',
        '2',
        '-y',
        outPath,
      ]);
      if (result.exitCode == 0 && File(outPath).existsSync()) {
        files.add(File(outPath));
      }
    }

    if (files.isEmpty) tmpDir.deleteSync(recursive: true);
  } catch (_) {}
  return files;
}

Future<File?> _extractAudioKeyframe(String audioPath) async {
  // generate a simple spectrogram-like visual for audio embedding
  try {
    final tmpDir = Directory.systemTemp.createTempSync('clip_audio_');
    final outputPath = '${tmpDir.path}/spectrogram.png';

    final result = await Process.run('ffmpeg', [
      '-i',
      audioPath,
      '-lavfi',
      'showspectrumpic=s=224x224:mode=combined:color=intensity',
      '-y',
      outputPath,
    ]);

    if (result.exitCode == 0 && File(outputPath).existsSync()) {
      return File(outputPath);
    }
    tmpDir.deleteSync(recursive: true);
  } catch (_) {}
  return null;
}
