import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';
import 'package:just_audio/just_audio.dart';
import 'package:memefolder/backend/system_specs.dart';
import 'package:sqflite/sqflite.dart';
import 'package:flutter/material.dart';
import 'package:memefolder/backend/custom_tags_store.dart';
import 'package:memefolder/prefs.dart';
import 'package:memefolder/utils/crash_logger.dart';
import 'package:memefolder/utils/binary_paths.dart';
import 'package:memefolder/widgets/bubble_snackbar.dart';
import 'package:path/path.dart' as p;

import 'caption_service.dart';
import 'embedding_service.dart';
import 'mel_ffi.dart';
import 'tokenizer.dart';
import 'package:memefolder/widgets/morphing_index_fab.dart';

final _player = AudioPlayer();
final _warnplayer = AudioPlayer();

class CancellationToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class IndexResult {
  final int totalFiles;
  final int indexedOk;
  final int indexedFail;
  final int skipped;
  IndexResult({
    required this.totalFiles,
    required this.indexedOk,
    required this.indexedFail,
    required this.skipped,
  });
}

Future<IndexResult> indexDirectory(
  String currentPath, {
  void Function(String text, double progress)? onProgress,
  CancellationToken? cancelToken,
  IndexOptions? options,
}) async {
  options ??= IndexOptions.load();
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

  onProgress?.call('indexing...', 0);
  stderr.writeln(
    '[memefolder] indexDirectory: start path=$currentPath dbExists=$dbExists',
  );

  try {
    final totalCount = await _countFiles(currentPath);
    onProgress?.call('indexing 0/$totalCount', 0);

    await _initDB(currentPath, dbPath: tmpPath);
    final result = await _scanAndIndex(
      currentPath,
      dbPath: tmpPath,
      totalCount: totalCount,
      onProgress: onProgress,
      cancelToken: cancelToken,
      options: options,
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
      return result;
    }

    if (dbExists) {
      await File(dbPath).delete();
    }
    await File(tmpPath).rename(dbPath);

    onProgress?.call('done', 1.0);

    showBubble(
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            result.indexedFail > 0 ? Icons.warning : Icons.check_circle,
            color: Colors.white,
          ),
          const SizedBox(width: 12),
          Text(
            '${result.indexedOk} ok, ${result.indexedFail} fail, ${result.skipped} skip',
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

    return result;
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
    version: 3,
    onConfigure: (db) async {
      await db.execute('PRAGMA foreign_keys = ON;');
      await db.execute('PRAGMA journal_mode = WAL;');
    },
    onCreate: (db, version) async {
      await _createSchema(db, currentPath);
    },
    onUpgrade: (db, oldVersion, newVersion) async {
      if (oldVersion < 2) {
        await db.execute('''
          DELETE FROM files WHERE id NOT IN (
            SELECT MIN(id) FROM files GROUP BY rel_path
          )
        ''');
        await db.execute('''
          CREATE UNIQUE INDEX IF NOT EXISTS idx_files_rel_path_unique
          ON files(rel_path)
        ''');
      }
      if (oldVersion < 3) {
        await db.execute(
          'ALTER TABLE files ADD COLUMN search_emb BLOB',
        );
      }
    },
  );

  await db.close();
}

class IndexStatus {
  final Set<String> indexed;
  final Set<String> failed;
  const IndexStatus({this.indexed = const {}, this.failed = const {}});
}

Future<IndexStatus> getIndexedFiles(String rootPath) async {
  final dbPath = p.join(rootPath, '.memefolder.db');
  if (!File(dbPath).existsSync()) return const IndexStatus();

  try {
    final db = await openDatabase(dbPath, singleInstance: false);
    final results = await db.rawQuery(
      "SELECT rel_path, status FROM files WHERE media_type IN ('image','video','audio')",
    );
    await db.close();
    final indexed = <String>{};
    final failed = <String>{};
    for (final r in results) {
      final relPath = p.join(rootPath, r['rel_path'] as String);
      final status = r['status'] as String? ?? 'indexed';
      if (status == 'embed_failed') {
        failed.add(relPath);
      } else {
        indexed.add(relPath);
      }
    }
    return IndexStatus(indexed: indexed, failed: failed);
  } catch (e) {
    debugPrint('Error reading indexed files: $e');
    return const IndexStatus();
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

const _textExts = {'txt', 'srt', 'sub', 'vtt', 'ass', 'ssa', 'md'};

String _mediaTypeForExt(String? ext) {
  if (ext == null) return 'unknown';
  final e = ext.toLowerCase();
  if (_imageExts.contains(e)) return 'image';
  if (_videoExts.contains(e)) return 'video';
  if (_audioExts.contains(e)) return 'audio';
  if (_textExts.contains(e)) return 'text';
  return 'unknown';
}

Future<Map<String, String?>> _extractAudioMetadata(String filePath) async {
  try {
    final result = await Process.run(ffprobePath, [
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

Future<Map<String, Object?>> _extractVideoInfo(String filePath) async {
  try {
    final result = await Process.run(ffprobePath, [
      '-v',
      'error',
      '-select_streams',
      'v:0',
      '-show_entries',
      'stream=width,height,r_frame_rate,codec_type',
      '-select_streams',
      'a:0',
      '-show_entries',
      'stream=codec_type',
      '-of',
      'json',
      filePath,
    ]);
    if (result.exitCode != 0) return {};

    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>?;
    if (json == null) return {};
    final streams = json['streams'] as List<dynamic>? ?? [];

    int? width, height;
    double? fps;
    bool hasAudio = false;

    for (final s in streams) {
      final sMap = s as Map<String, dynamic>;
      final codecType = sMap['codec_type'] as String?;
      if (codecType == 'video') {
        width = sMap['width'] as int?;
        height = sMap['height'] as int?;
        final rFrameRate = sMap['r_frame_rate'] as String?;
        if (rFrameRate != null && rFrameRate.contains('/')) {
          final parts = rFrameRate.split('/');
          final num = double.tryParse(parts[0]);
          final den = double.tryParse(parts[1]);
          if (num != null && den != null && den > 0) fps = num / den;
        }
      } else if (codecType == 'audio') {
        hasAudio = true;
      }
    }

    return {
      'width': width,
      'height': height,
      'fps': fps,
      'has_audio': hasAudio ? 1 : 0,
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

Future<IndexResult> _scanAndIndex(
  String rootPath, {
  required String dbPath,
  int totalCount = 0,
  void Function(String text, double progress)? onProgress,
  CancellationToken? cancelToken,
  IndexOptions? options,
}) async {
  options ??= IndexOptions.load();
  final opts = options;
  final db = await openDatabase(dbPath);
  stderr.writeln(
    '[memefolder] _scanAndIndex: start rootPath=$rootPath totalCount=$totalCount',
  );

  // load already indexed files if onlyUnprocessed is true
  final Set<String> alreadyIndexed = {};
  if (opts.onlyUnprocessed) {
    try {
      final oldDbPath = p.join(rootPath, '.memefolder.db');
      if (File(oldDbPath).existsSync()) {
        final oldDb = await openDatabase(oldDbPath, singleInstance: false);
        final results = await oldDb.rawQuery(
          "SELECT rel_path FROM files WHERE media_type IN ('image','video','audio') AND status != 'embed_failed'",
        );
        await oldDb.close();
        for (final r in results) {
          alreadyIndexed.add(r['rel_path'] as String);
        }
        stderr.writeln(
          '[memefolder] onlyUnprocessed: ${alreadyIndexed.length} already indexed files',
        );
      }
    } catch (e) {
      stderr.writeln(
        '[memefolder] onlyUnprocessed: failed to load indexed files: $e',
      );
    }
  }

  var indexedCount = 0;
  var embedOk = 0;
  var embedFail = 0;

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

  // Collect files needing embedding (processed after transaction)
  final embedQueue = <_EmbedJob>[];

  Future<void> scanFolder(Transaction txn, String relPath, int depth) async {
    if (depth > 5) return; // cap at depth 5
    stderr.writeln('[memefolder] scanFolder: depth=$depth path=$relPath');
    await _player.setAsset('Assets/SFX/done.mp3');
    _player.load();
    await _warnplayer.setAsset('Assets/SFX/warning.mp3');
    _warnplayer.load();

    final folderId = await ensureFolder(txn, relPath);
    final dirPath = relPath.isEmpty ? rootPath : p.join(rootPath, relPath);

    final dir = Directory(dirPath);
    if (!await dir.exists()) return;

    await for (final entity in dir.list(followLinks: false)) {
      try {
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

          final stat = await entity.stat();
          final ext = p.extension(name).toLowerCase().replaceFirst('.', '');
          final stem = p.basenameWithoutExtension(name);
          final mediaType = _mediaTypeForExt(ext);
          // Only index images, videos, and audio. No text/docs/models/apps.
          if (mediaType == 'unknown' || mediaType == 'text') continue;

          Map<String, String?> audioMeta = {};
          if (mediaType == 'audio') {
            audioMeta = await _extractAudioMetadata(entity.path);
          }

          int? imgWidth, imgHeight;
          if (mediaType == 'image') {
            try {
              final bytes = await File(entity.path).readAsBytes();
              final codec = await instantiateImageCodec(bytes);
              final frame = await codec.getNextFrame();
              imgWidth = frame.image.width;
              imgHeight = frame.image.height;
              codec.dispose();
            } catch (_) {}
          }

          Map<String, Object?> videoInfo = {};
          if (mediaType == 'video') {
            videoInfo = await _extractVideoInfo(entity.path);
          }

          final isVideo = mediaType == 'video';
          final isGif = ext == 'gif';

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
            'width': imgWidth ?? videoInfo['width'] as int?,
            'height': imgHeight ?? videoInfo['height'] as int?,
            'duration_ms': audioMeta['duration_ms'] != null
                ? int.tryParse(audioMeta['duration_ms']!)
                : null,
            'fps': videoInfo['fps'] as double?,
            'has_audio': videoInfo['has_audio'] as int? ?? 0,
            'has_motion': isVideo || isGif ? 1 : 0,
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
            onProgress?.call('indexing $indexedCount/$totalCount', indexedCount / totalCount);
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
            case 'text':
              {
                final tagId = await ensureTag(txn, 'text', '@text', 'type');
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

          // Skip embedding if onlyUnprocessed and file already indexed
          if (!opts.onlyUnprocessed || !alreadyIndexed.contains(fileRel)) {
            embedQueue.add(
              _EmbedJob(
                fileId: fileId,
                absPath: entity.path,
                mediaType: mediaType,
                audioMeta: audioMeta,
                fileName: stem,
              ),
            );
          }
        }
      } catch (_) {}
    }
  }

  await db.transaction((txn) async {
    await scanFolder(txn, '', 0);
    final now = DateTime.now().millisecondsSinceEpoch;
    await txn.update('roots', {'indexed_at': now}, where: 'id = 1');
  });

  await db.close();

  if (embedQueue.isNotEmpty) {
    if (!EmbeddingService.instance.isInitialized) {
      if (cancelToken?.isCancelled ?? false) {
        return IndexResult(totalFiles: totalCount, indexedOk: 0, indexedFail: 0, skipped: 0);
      }
      onProgress?.call('loading', -1);
      await _autoInitEmbedding();
      final specs = await SystemSpecs.detect();
      final gpuProvider = specs.recommendedGpuProvider;
      final gpuErr = EmbeddingService.instance.gpuInitError;
      if (gpuProvider != 'CPU' && gpuErr != null) {
        showBubble(
          Text(
            "loaded! (CPU only. GPU acceleration failed:\n$gpuErr)",
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w500,
              decoration: TextDecoration.none,
            ),
            softWrap: true,
          ),
        );
      } else {
        if (gpuProvider == 'CPU') {
          showBubble(
            Text(
              "loaded! (CPU only)",
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w500,
                decoration: TextDecoration.none,
              ),
              softWrap: true,
            ),
          );
        } else {
          showBubble(
            Text(
              "loaded! (GPU: $gpuProvider)",
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w500,
                decoration: TextDecoration.none,
              ),
              softWrap: true,
            ),
          );
        }
      }
    }
    if (EmbeddingService.instance.isInitialized) {
      final (ok, fail) = await _processEmbedQueue(
        dbPath,
        embedQueue,
        onProgress,
        cancelToken,
        options: options,
      );
      embedOk += ok;
      embedFail += fail;
    } else {
      showBubble(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline),
            const SizedBox(width: 12),
            const Flexible(
              child: Text(
                'Models not loaded - embeddings skipped',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
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

  // free caption models (not needed for search)
  try {
    await CaptionService.instance.unload();
  } catch (_) {}

  await _congratulateScanEnd();

  return IndexResult(
    totalFiles: indexedCount,
    indexedOk: embedOk,
    indexedFail: embedFail,
    skipped: indexedCount - embedOk - embedFail,
  );
}

Future<void> _autoInitEmbedding() async {
  try {
    final modelsPath = await EmbeddingService.resolveModelsPath();
    final tier = PlayerPrefs.getString('model_tier', 'lite');
    await EmbeddingService.instance.initialize(
      modelsPath: modelsPath,
      tier: tier,
    );
  } catch (e) {
    debugPrint('[indexer] auto-init embedding failed: $e');
  }
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
      model_tier TEXT NOT NULL DEFAULT 'lite',
      model_name TEXT NOT NULL DEFAULT 'clip-vit-b32',
      text_model TEXT,
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
      status TEXT NOT NULL DEFAULT 'indexed',
      clip_emb BLOB,
      clap_emb BLOB,
      metadata_emb BLOB,
      metadata_text TEXT,
      ocr_emb BLOB,
      transcript_emb BLOB,
      search_emb BLOB
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
      transcription TEXT,
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
    CREATE INDEX IF NOT EXISTS idx_tags_slug ON tags(slug);
  ''');

  var currentTier = PlayerPrefs.getString('model_tier', 'lite');
  if (currentTier == 'low') currentTier = 'lite';
  if (currentTier == 'high') currentTier = 'full';
  await db.insert('roots', {
    'id': 1,
    'root_path': currentPath,
    'root_name': rootName,
    'created_at': now,
    'indexed_at': null,
    'model_tier': currentTier,
    'model_name': 'siglip2-$currentTier',
    'app_version': null,
    'schema_version': 2,
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

Future<Map<String, dynamic>> getFileEmbeddingInfo(
  String rootPath,
  String absPath,
) async {
  final dbPath = p.join(rootPath, '.memefolder.db');
  if (!File(dbPath).existsSync()) return {};

  try {
    final db = await openDatabase(dbPath, singleInstance: false);
    final rows = await db.rawQuery(
      '''
      SELECT f.clip_emb, f.clap_emb, f.metadata_emb, f.ocr_emb,
             f.transcript_emb,
             ft.ocr_text, ft.transcript_text
      FROM files f
      LEFT JOIN file_text ft ON ft.file_id = f.id
      WHERE f.rel_path = ?
      LIMIT 1
    ''',
      [p.relative(absPath, from: rootPath)],
    );
    await db.close();
    if (rows.isEmpty) return {};
    return rows.first;
  } catch (e) {
    debugPrint('[embeddings] getFileEmbeddingInfo error: $e');
    return {};
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
  allTags.addAll(CustomTagsStore.instance.tagNames);

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

class _EmbedJob {
  final int fileId;
  final String absPath;
  final String mediaType;
  final Map<String, String?> audioMeta;
  final String fileName;
  const _EmbedJob({
    required this.fileId,
    required this.absPath,
    required this.mediaType,
    required this.audioMeta,
    required this.fileName,
  });
}

Future<(int, int)> _processEmbedQueue(
  String dbPath,
  List<_EmbedJob> queue,
  void Function(String text, double progress)? onProgress,
  CancellationToken? cancelToken, {
  IndexOptions? options,
}) async {
  options ??= IndexOptions.load();
  final opts = options;
  final svc = EmbeddingService.instance;
  stderr.writeln('[memefolder] _processEmbedQueue: queueSize=${queue.length}');
  final tokenizer = HuggingFaceTokenizer.fromFile(
    p.join(svc.modelsPath!, 'clip', 'tokenizer.json'),
  );
  var currentTier = PlayerPrefs.getString('model_tier', 'lite');
  if (currentTier == 'low') currentTier = 'lite';
  if (currentTier == 'high') currentTier = 'full';
  final isMidOrFull = currentTier == 'mid' || currentTier == 'full';
  // initialize caption service for mid/full tiers
  if (isMidOrFull && !CaptionService.instance.isInitialized) {
    if (cancelToken?.isCancelled ?? false) return (0, 0);
    try {
      final captionGpu = EmbeddingService.instance.gpuProvider;
      await CaptionService.instance.initialize(
        modelsPath: svc.modelsPath!,
        gpuProvider: captionGpu,
      );
      stderr.writeln(
        '[memefolder] caption service initialized ($captionGpu) modelsPath=${svc.modelsPath}',
      );
    } catch (e) {
      stderr.writeln('[memefolder] caption service init failed: $e');
      debugPrint('[embed] caption service init failed: $e');
    }
  } else {
    if (isMidOrFull) {
      stderr.writeln('[memefolder] caption service already initialized');
    }
  }
  final db = await openDatabase(dbPath);
  var done = 0;
  var ok = 0;
  var fail = 0;

  try {
    for (final job in queue) {
      if (cancelToken?.isCancelled ?? false) break;
      stderr.writeln(
        '[memefolder] embedJob: fileId=${job.fileId} type=${job.mediaType} path=${job.absPath}',
      );
      try {
        await _embedOneFile(
          db,
          svc,
          tokenizer,
          job,
          tier: currentTier,
          options: opts,
          cancelToken: cancelToken,
        );
        ok++;
      } catch (e) {
        fail++;
        debugPrint('[embed] error for ${job.absPath}: $e');
        // mark file status as 'embed_failed' so UI can show X
        try {
          await db.update(
            'files',
            {'status': 'embed_failed'},
            where: 'id = ?',
            whereArgs: [job.fileId],
          );
        } catch (_) {}
      }
      done++;
      if (queue.length > 1) {
        onProgress?.call('embedding $done/${queue.length}', done / queue.length);
      }
    }
  } finally {
    await db.close();
  }
  return (ok, fail);
}

Future<void> _embedOneFile(
  Database db,
  EmbeddingService svc,
  HuggingFaceTokenizer tokenizer,
  _EmbedJob job, {
  String tier = 'lite',
  IndexOptions? options,
  CancellationToken? cancelToken,
}) async {
  options ??= IndexOptions.load();
  final opts = options;
  final isMidOrFull = tier == 'mid' || tier == 'full';
  final isFull = tier == 'full';
  final updates = <String, Object?>{};
  final crashLog = CrashLogger.instance;

  if (cancelToken?.isCancelled ?? false) return;

  if (opts.enableClip) {
    try {
      final clipEmb = await _embedClipForFile(svc, tokenizer, job);
      if (clipEmb != null && clipEmb.length == svc.clipDim) {
        updates['clip_emb'] = clipEmb.buffer.asUint8List();
      }
    } catch (e) {
      debugPrint('[embed] clip embedding failed for ${job.absPath}: $e');
    }
  }

  if (opts.enableClap && isFull) {
    if (cancelToken?.isCancelled ?? false) return;
    try {
      final clapEmb = await _embedClapForFile(svc, job);
      if (clapEmb != null && clapEmb.length == svc.clapDim) {
        updates['clap_emb'] = clapEmb.buffer.asUint8List();
      }
    } catch (e) {
      debugPrint('[embed] clap embedding failed for ${job.absPath}: $e');
    }
  }

  if (cancelToken?.isCancelled ?? false) return;

  try {
    final textEmb = await _embedTextForFile(svc, tokenizer, job);
    if (textEmb != null && textEmb.length == svc.clipDim) {
      updates['clip_emb'] = textEmb.buffer.asUint8List();
    }
  } catch (e) {
    debugPrint('[embed] text embedding failed for ${job.absPath}: $e');
  }

  if (cancelToken?.isCancelled ?? false) return;

  try {
    final metadataResult = await _embedMetadata(svc, tokenizer, job);
    if (metadataResult != null && metadataResult.$1.length == svc.clipDim) {
      updates['metadata_emb'] = metadataResult.$1.buffer.asUint8List();
      updates['metadata_text'] = metadataResult.$2;
    }
  } catch (e) {
    debugPrint('[embed] metadata embedding failed for ${job.absPath}: $e');
  }

  if (cancelToken?.isCancelled ?? false) return;

  // ocr for images and video keyframes (mid/full)
  final captionReady = CaptionService.instance.isInitialized;
  String? ocrText;
  if (opts.enableOcr &&
      isMidOrFull &&
      captionReady &&
      (job.mediaType == 'image' || job.mediaType == 'video')) {
    try {
      Uint8List? imageBytes;
      if (job.mediaType == 'image') {
        imageBytes = await File(job.absPath).readAsBytes();
      } else {
        // extract first frame from video
        final keyframePath = '${job.absPath}.ocr_keyframe.jpg';
        final result = await Process.run(ffmpegPath, [
          '-y',
          '-hwaccel', 'auto',
          '-i',
          job.absPath,
          '-vframes',
          '1',
          '-f',
          'image2',
          keyframePath,
        ]);
        if (result.exitCode == 0) {
          final kf = File(keyframePath);
          if (await kf.exists() && await kf.length() > 0) {
            imageBytes = await kf.readAsBytes();
          }
          try {
            await kf.delete();
          } catch (_) {}
        }
      }
      if (imageBytes != null) {
        stderr.writeln('[caption] OCR: start file=${job.absPath}');
        ocrText = await CaptionService.instance.runOcr(imageBytes);
        stderr.writeln('[caption] OCR: done len=${ocrText.length}');
      }
    } catch (e) {
      stderr.writeln('[caption] OCR failed for ${job.absPath}: $e');
    }
  }

  if (cancelToken?.isCancelled ?? false) return;

  // whisper transcription for audio/video (mid/full)
  String? transcript;
  if (opts.enableWhisper &&
      isMidOrFull &&
      captionReady &&
      (job.mediaType == 'audio' || job.mediaType == 'video')) {
    try {
      stderr.writeln(
        '[caption] Whisper: start extractAudio file=${job.absPath}',
      );
      final pcm = await _extractAudio16kHz(
        job.absPath,
        job.mediaType == 'video',
      );
      if (pcm != null) {
        stderr.writeln(
          '[caption] Whisper: start runWhisper pcmLen=${pcm.length}',
        );
        transcript = await CaptionService.instance.runWhisper(pcm);
        stderr.writeln('[caption] Whisper: done len=${transcript.length}');
      } else {
        stderr.writeln('[caption] Whisper: extractAudio returned null');
      }
    } catch (e) {
      stderr.writeln('[caption] Whisper failed for ${job.absPath}: $e');
    }
  }

  // store ocr/transcript text and their clip text embeddings
  if (ocrText != null && ocrText.isNotEmpty) {
    _upsertFileText(db, job.fileId, ocrText: ocrText);
    final tokenIds = tokenizer.encodeClip(ocrText);
    final emb = await svc.embedClipText(tokenIds);
    updates['ocr_emb'] = emb.buffer.asUint8List();
    updates['has_text'] = 1;
  }
  if (transcript != null && transcript.isNotEmpty) {
    _upsertFileText(db, job.fileId, transcript: transcript);
    final tokenIds = tokenizer.encodeClip(transcript);
    final emb = await svc.embedClipText(tokenIds);
    updates['transcript_emb'] = emb.buffer.asUint8List();
    updates['has_speech'] = 1;
  }

  // compute search_emb: lerp(mean, elementwise_max, 0.6) of all available
  // CLIP-space embeddings, then L2-normalize
  {
    final vectors = <Float32List>[];
    final dim = svc.clipDim;
    if (updates['clip_emb'] != null) {
      vectors.add(Float32List.view(
        (updates['clip_emb'] as Uint8List).buffer, 0, dim));
    }
    if (updates['metadata_emb'] != null) {
      vectors.add(Float32List.view(
        (updates['metadata_emb'] as Uint8List).buffer, 0, dim));
    }
    if (updates['ocr_emb'] != null) {
      vectors.add(Float32List.view(
        (updates['ocr_emb'] as Uint8List).buffer, 0, dim));
    }
    if (updates['transcript_emb'] != null) {
      vectors.add(Float32List.view(
        (updates['transcript_emb'] as Uint8List).buffer, 0, dim));
    }
    if (vectors.isNotEmpty) {
      final searchEmb = _combineEmbeddings(vectors, dim);
      updates['search_emb'] = searchEmb.buffer.asUint8List();
    }
  }

  crashLog.mark('embedOneFile:save', {'updateKeys': updates.keys.join(',')});

  if (updates.isNotEmpty) {
    await db.update('files', updates, where: 'id = ?', whereArgs: [job.fileId]);
  }
}

/// Combine multiple CLIP-space embeddings into a single search embedding.
/// Uses lerp(mean, elementwise_max, 0.6) then L2-normalizes.
Float32List _combineEmbeddings(List<Float32List> vectors, int dim) {
  final n = vectors.length;
  final meanVec = Float32List(dim);
  final maxVec = Float32List(dim);

  // copy first vector into both
  meanVec.setAll(0, vectors[0]);
  maxVec.setAll(0, vectors[0]);

  // accumulate mean and elementwise max
  for (int d = 0; d < dim; d++) {
    for (int v = 1; v < n; v++) {
      meanVec[d] += vectors[v][d];
      if (vectors[v][d] > maxVec[d]) maxVec[d] = vectors[v][d];
    }
    meanVec[d] /= n;
  }

  // lerp: result = 0.4 * mean + 0.6 * max
  final result = Float32List(dim);
  double normSq = 0;
  for (int d = 0; d < dim; d++) {
    result[d] = 0.4 * meanVec[d] + 0.6 * maxVec[d];
    normSq += result[d] * result[d];
  }

  // L2 normalize
  if (normSq > 0) {
    final invNorm = 1.0 / sqrt(normSq);
    for (int d = 0; d < dim; d++) {
      result[d] *= invNorm;
    }
  }

  return result;
}

/// Compute CLIP text embedding for text/subtitle files.
Future<Float32List?> _embedTextForFile(
  EmbeddingService svc,
  HuggingFaceTokenizer tokenizer,
  _EmbedJob job,
) async {
  if (job.mediaType != 'text') return null;
  try {
    final content = await File(job.absPath).readAsString();
    final truncated = content.length > 1000
        ? content.substring(0, 1000)
        : content;
    final tokenIds = tokenizer.encodeClip(truncated);
    return svc.embedClipText(tokenIds);
  } catch (e) {
    debugPrint('[embed] text embedding failed for ${job.absPath}: $e');
    return null;
  }
}

/// Compute CLIP vision embedding for image/video files.
Future<Float32List?> _embedClipForFile(
  EmbeddingService svc,
  HuggingFaceTokenizer tokenizer,
  _EmbedJob job,
) async {
  if (job.mediaType == 'image') {
    final bytes = await File(job.absPath).readAsBytes();
    return svc.embedImage(bytes);
  }
  if (job.mediaType == 'video') {
    // Extract keyframe via ffmpeg
    final keyframePath = '${job.absPath}.keyframe.jpg';
    try {
      stderr.writeln('[memefolder] ffmpeg keyframe: start path=${job.absPath}');
      final result = await Process.run(ffmpegPath, [
        '-y',
        '-hwaccel', 'auto',
        '-i',
        job.absPath,
        '-vframes',
        '1',
        '-s',
        '224x224',
        '-f',
        'image2',
        keyframePath,
      ]);
      stderr.writeln(
        '[memefolder] ffmpeg keyframe: exitCode=${result.exitCode} stderr=${result.stderr}',
      );
      if (result.exitCode != 0) return null;
      final keyframe = File(keyframePath);
      if (!await keyframe.exists() || await keyframe.length() == 0) {
        stderr.writeln('[memefolder] ffmpeg keyframe: file missing or empty');
        return null;
      }
      final bytes = await keyframe.readAsBytes();
      stderr.writeln(
        '[memefolder] ffmpeg keyframe: size=${bytes.length} calling embedImage',
      );
      final emb = await svc.embedImage(bytes);
      return emb;
    } finally {
      try {
        await File(keyframePath).delete();
      } catch (_) {}
    }
  }
  return null;
}

/// Compute CLAP audio embedding for audio/video files.
Future<Float32List?> _embedClapForFile(
  EmbeddingService svc,
  _EmbedJob job,
) async {
  if (job.mediaType != 'audio' && job.mediaType != 'video') return null;

  final pcmPath = '${job.absPath}.pcm';
  try {
    stderr.writeln('[memefolder] ffmpeg pcm: start path=${job.absPath}');
    final args = <String>[
      '-y',
      '-i',
      job.absPath,
      '-acodec',
      'pcm_s16le',
      '-ar',
      '48000',
      '-ac',
      '1',
      '-f',
      's16le',
    ];
    if (job.mediaType == 'video') {
      args.insertAll(1, ['-vn']);
    }
    args.add(pcmPath);
    final result = await Process.run(ffmpegPath, args);
    stderr.writeln(
      '[memefolder] ffmpeg pcm: exitCode=${result.exitCode} stderr=${result.stderr}',
    );
    if (result.exitCode != 0) return null;

    final pcmFile = File(pcmPath);
    if (!await pcmFile.exists()) {
      stderr.writeln('[memefolder] ffmpeg pcm: file not found');
      return null;
    }
    final pcmLen = await pcmFile.length();
    // skip if PCM is empty or exceeds ~60s of audio (48000*60*2 = 5.76MB)
    if (pcmLen == 0 || pcmLen > 6 * 1024 * 1024) {
      stderr.writeln('[memefolder] ffmpeg pcm: skipped size=$pcmLen');
      return null;
    }

    final pcmBytes = await pcmFile.readAsBytes();
    final samples = Int16List.view(pcmBytes.buffer);
    stderr.writeln(
      '[memefolder] pcm samples=${samples.length} calling embedAudio',
    );
    final floatPcm = Float32List(samples.length);
    for (int i = 0; i < samples.length; i++) {
      floatPcm[i] = samples[i] / 32768.0;
    }
    return svc.embedAudio(floatPcm);
  } finally {
    try {
      await File(pcmPath).delete();
    } catch (_) {}
  }
}

/// Extract 16kHz mono PCM from audio/video file via ffmpeg.
/// Returns null on failure. Max 30s (480000 samples).
Future<Float32List?> _extractAudio16kHz(String absPath, bool isVideo) async {
  final pcmPath = '$absPath.whisper.pcm';
  try {
    final args = <String>[
      '-y',
      '-i',
      absPath,
      '-acodec',
      'pcm_s16le',
      '-ar',
      '16000',
      '-ac',
      '1',
      '-f',
      's16le',
    ];
    if (isVideo) args.insertAll(1, ['-vn']);
    args.add(pcmPath);
    stderr.writeln('[caption] ffmpeg audio: start path=$absPath');
    final result = await Process.run(ffmpegPath, args);
    stderr.writeln('[caption] ffmpeg audio: exitCode=${result.exitCode}');
    if (result.exitCode != 0) return null;
    final pcmFile = File(pcmPath);
    if (!await pcmFile.exists()) return null;
    final pcmLen = await pcmFile.length();
    stderr.writeln('[caption] ffmpeg audio: pcmLen=$pcmLen');
    if (pcmLen == 0 || pcmLen > MelFFI.whisperMaxSamples * 2) return null;
    final pcmBytes = await pcmFile.readAsBytes();
    final samples = Int16List.view(pcmBytes.buffer);
    final floatPcm = Float32List(samples.length);
    for (int i = 0; i < samples.length; i++) {
      floatPcm[i] = samples[i] / 32768.0;
    }
    return floatPcm;
  } finally {
    try {
      await File(pcmPath).delete();
    } catch (_) {}
  }
}

/// Build metadata text and embed via CLIP text encoder.
/// Returns (embedding, metadata_text) or null.
Future<(Float32List, String)?> _embedMetadata(
  EmbeddingService svc,
  HuggingFaceTokenizer tokenizer,
  _EmbedJob job,
) async {
  final parts = <String>[];
  parts.add('file: ${job.fileName}');

  if (job.mediaType == 'audio') {
    final meta = job.audioMeta;
    if (meta['artist'] != null && meta['artist']!.isNotEmpty) {
      parts.add('artist: ${meta['artist']}');
    }
    if (meta['album'] != null && meta['album']!.isNotEmpty) {
      parts.add('album: ${meta['album']}');
    }
    if (meta['genre'] != null && meta['genre']!.isNotEmpty) {
      parts.add('genre: ${meta['genre']}');
    }
    if (meta['year'] != null && meta['year']!.isNotEmpty) {
      parts.add('year: ${meta['year']}');
    }
    if (meta['track'] != null && meta['track']!.isNotEmpty) {
      parts.add('track: ${meta['track']}');
    }
    if (meta['comment'] != null && meta['comment']!.isNotEmpty) {
      parts.add('comment: ${meta['comment']}');
    }
    if (meta['duration_ms'] != null) {
      final secs = int.tryParse(meta['duration_ms']!) ?? 0;
      parts.add('duration: ${(secs / 1000).toStringAsFixed(1)}s');
    }
  }

  // nudge: append custom tag definitions so the embedder understands user's vocabulary
  final customTags = CustomTagsStore.instance.tags;
  if (customTags.isNotEmpty) {
    final tagParts = customTags.entries
        .map((e) {
          final desc = e.value.isNotEmpty ? ': ${e.value}' : '';
          return '@${e.key}$desc';
        })
        .join(', ');
    parts.add('tags: {$tagParts}');
  }

  final metadataText = parts.join(', ');
  if (metadataText.isEmpty) return null;

  final tokenIds = tokenizer.encodeClip(metadataText);
  final emb = await svc.embedClipText(tokenIds);
  return (emb, metadataText);
}

/// upsert a single column in file_text without clobbering other columns.
Future<void> _upsertFileText(
  Database db,
  int fileId, {
  String? ocrText,
  String? transcript,
}) async {
  if (ocrText == null && transcript == null) return;
  final existing = await db.query(
    'file_text',
    columns: ['file_id'],
    where: 'file_id = ?',
    whereArgs: [fileId],
  );
  if (existing.isNotEmpty) {
    final vals = <String, Object?>{};
    if (ocrText != null) vals['ocr_text'] = ocrText;
    if (transcript != null) vals['transcript_text'] = transcript;
    await db.update(
      'file_text',
      vals,
      where: 'file_id = ?',
      whereArgs: [fileId],
    );
  } else {
    await db.insert('file_text', {
      'file_id': fileId,
      if (ocrText != null) 'ocr_text': ocrText,
      if (transcript != null) 'transcript_text': transcript,
    });
  }
}
