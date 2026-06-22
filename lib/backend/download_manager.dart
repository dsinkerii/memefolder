import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:memefolder/backend/semantic_search/semantic_search_classes.dart';
import 'package:path/path.dart' as p;

class DownloadManager {
  static final DownloadManager instance = DownloadManager._();
  DownloadManager._();

  final Map<String, DownloadTask> _active = {};

  String get _modelsDir {
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '/tmp';
    return p.join(home, '.local', 'share', 'memefolder', 'models');
  }

  Future<String> get modelsDirectory async {
    final dir = Directory(_modelsDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return _modelsDir;
  }

  Future<DownloadResult> downloadFile({
    required String url,
    required String fileName,
    void Function(double progress)? onProgress,
  }) async {
    final dir = await modelsDirectory;
    final savePath = p.join(dir, fileName);

    final taskId = '$url|$fileName';
    if (_active.containsKey(taskId)) {
      return const DownloadAlreadyDownloading();
    }

    final task = DownloadTask(url: url, savePath: savePath);
    _active[taskId] = task;

    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 15);

      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );

      if (response.statusCode != 200) {
        final error = 'HTTP ${response.statusCode}: ${response.reasonPhrase}';
        _active.remove(taskId);
        client.close(force: true);
        return DownloadFailure(error);
      }

      final totalBytes = response.contentLength;
      int receivedBytes = 0;

      final file = File(savePath);
      final sink = file.openWrite();

      await for (final chunk in response) {
        if (task.cancelled) {
          await sink.close();
          await file.delete();
          _active.remove(taskId);
          client.close(force: true);
          return DownloadFailure('Download cancelled');
        }

        sink.add(chunk);
        receivedBytes += chunk.length;

        if (onProgress != null) {
          if (totalBytes > 0) {
            onProgress(receivedBytes / totalBytes);
          } else {
            onProgress(-1);
          }
        }

        task.receivedBytes = receivedBytes;
        task.totalBytes = totalBytes;
      }

      await sink.close();
      client.close(force: true);
      _active.remove(taskId);

      return DownloadSuccess(savePath);
    } on SocketException catch (e) {
      _active.remove(taskId);
      return DownloadFailure('Network error: ${e.message}');
    } on TimeoutException catch (_) {
      _active.remove(taskId);
      return DownloadFailure('Connection timed out');
    } on HttpException catch (e) {
      _active.remove(taskId);
      return DownloadFailure('HTTP error: ${e.message}');
    } catch (e) {
      _active.remove(taskId);
      return DownloadFailure('Download failed: $e');
    }
  }

  Future<DownloadResult> downloadFromUrl({
    required String url,
    void Function(double progress)? onProgress,
  }) async {
    final fileName = url.split('/').last;
    return downloadFile(url: url, fileName: fileName, onProgress: onProgress);
  }

  void cancelDownload(String url, String fileName) {
    final taskId = '$url|$fileName';
    _active[taskId]?.cancelled = true;
  }

  bool isDownloading(String url, String fileName) {
    return _active.containsKey('$url|$fileName');
  }

  Future<ModelManifest?> pickAndExtractModel(String sourcePath) async {
    final file = File(sourcePath);
    if (!await file.exists()) return null;
    if (!sourcePath.endsWith('.zip')) return null;

    final dir = await modelsDirectory;
    final zipName = p.basenameWithoutExtension(sourcePath);
    final extractDir = p.join(dir, zipName);

    try {
      // clean previous install if exists
      final existing = Directory(extractDir);
      if (await existing.exists()) {
        await existing.delete(recursive: true);
      }

      // read and decode zip
      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      // detect if all files are under a single top-level folder
      // e.g. "low-tier-clip/vocab.json" -> strip the common prefix
      final topLevelFolders = <String>{};
      for (final archiveFile in archive) {
        if (archiveFile.name.isEmpty) continue;
        final parts = archiveFile.name.split('/');
        // ignore trailing empty parts from directory entries
        final nonEmpty = parts.where((p) => p.isNotEmpty).toList();
        if (nonEmpty.length > 1) {
          topLevelFolders.add(nonEmpty.first);
        }
      }

      // if exactly one top-level folder and all files are under it, strip it
      final stripPrefix = topLevelFolders.length == 1
          ? '${topLevelFolders.first}/'
          : '';

      // extract all files
      for (final archiveFile in archive) {
        var name = archiveFile.name;
        if (stripPrefix.isNotEmpty && name.startsWith(stripPrefix)) {
          name = name.substring(stripPrefix.length);
        }
        if (name.isEmpty) continue;

        final filePath = p.join(extractDir, name);
        if (archiveFile.isFile) {
          final outFile = File(filePath);
          await outFile.create(recursive: true);
          await outFile.writeAsBytes(archiveFile.content as List<int>);
        } else {
          await Directory(filePath).create(recursive: true);
        }
      }

      // parse manifest
      final manifest = ModelManifest.fromDir(extractDir);
      return manifest;
    } catch (_) {
      // clean up on failure
      final failed = Directory(extractDir);
      if (await failed.exists()) {
        await failed.delete(recursive: true);
      }
      return null;
    }
  }

  // remove an installed model by directory name.
  Future<void> removeModel(String modelDirName) async {
    final dir = Directory(p.join(_modelsDir, modelDirName));
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  /// get the manifest of the currently installed model, if any.
  ModelManifest? getInstalledModel() {
    final modelsDir = Directory(_modelsDir);
    if (!modelsDir.existsSync()) return null;

    for (final entity in modelsDir.listSync()) {
      if (entity is Directory) {
        final manifest = ModelManifest.fromDir(entity.path);
        if (manifest != null) return manifest;
      }
    }
    return null;
  }

  // get directory name of the installed model, if any.
  String? getInstalledModelDirName() {
    final modelsDir = Directory(_modelsDir);
    if (!modelsDir.existsSync()) return null;

    for (final entity in modelsDir.listSync()) {
      if (entity is Directory) {
        final manifest = ModelManifest.fromDir(entity.path);
        if (manifest != null) return p.basename(entity.path);
      }
    }
    return null;
  }
}

class DownloadTask {
  final String url;
  final String savePath;
  int receivedBytes;
  int totalBytes;
  bool cancelled;

  DownloadTask({
    required this.url,
    required this.savePath,
    this.receivedBytes = 0,
    this.totalBytes = -1,
    this.cancelled = false,
  });

  double get progress => totalBytes > 0 ? receivedBytes / totalBytes : -1;
}

sealed class DownloadResult {
  const DownloadResult();
}

class DownloadSuccess extends DownloadResult {
  final String filePath;
  const DownloadSuccess(this.filePath);
}

class DownloadFailure extends DownloadResult {
  final String error;
  const DownloadFailure(this.error);
}

class DownloadAlreadyDownloading extends DownloadResult {
  const DownloadAlreadyDownloading();
}
