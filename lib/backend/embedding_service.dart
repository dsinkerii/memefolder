import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:memefolder/prefs.dart';
import 'package:memefolder/utils/crash_logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'embedding_isolate.dart';
import 'mel_ffi.dart';

enum ModelType { clipVision, clipText, clapAudio, clapText }

class EmbeddingService {
  static final EmbeddingService instance = EmbeddingService._();

  EmbeddingService._();

  bool _initialized = false;
  bool get isInitialized => _initialized;

  Isolate? _isolate;
  SendPort? _isolateSendPort;

  int clipDim = 512;
  int get clapDim => 512;
  String _gpuProvider = 'CPU';
  String get gpuProvider => _gpuProvider;
  String? _gpuInitError;
  String? get gpuInitError => _gpuInitError;

  String? _modelsPath;
  String? get modelsPath => _modelsPath;
  String? _modelsBasePath;

  Timer? _idleTimer;
  int get _idleTimeoutMinutes => PlayerPrefs.getInt('model_idle_timeout', 10);
  String? _lastGpuProvider;

  // idle keepalive
  void _touchIdleTimer() {
    _idleTimer?.cancel();
    final minutes = _idleTimeoutMinutes;
    if (minutes <= 0) return;
    _idleTimer = Timer(Duration(minutes: minutes), () => unload());
  }

  void restartIdleTimer() => _touchIdleTimer();

  Future<void> unload() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    if (!_initialized) return;
    debugPrint('[embedding] unloading models after idle timeout');
    if (_isolateSendPort != null) {
      final rp = ReceivePort();
      _isolateSendPort!.send([6, rp.sendPort]);
      rp.close();
    }
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _isolateSendPort = null;
    _initialized = false;
  }

  Future<SendPort> _spawnIsolate() async {
    final receivePort = ReceivePort();
    debugPrint('[embedding] Isolate.spawn: creating embedding isolate...');
    _isolate = await Isolate.spawn(embeddingIsolateMain, receivePort.sendPort);
    debugPrint('[embedding] Isolate.spawn: waiting for SendPort...');
    final sendPort = await receivePort.first as SendPort;
    _isolateSendPort = sendPort;
    debugPrint('[embedding] Isolate.spawn: got SendPort');
    return sendPort;
  }

  Future<T> _sendToIsolate<T>(List<dynamic> msg) async {
    if (_isolateSendPort == null) {
      throw StateError('Isolate not initialized');
    }
    final rp = ReceivePort();
    _isolateSendPort!.send([msg[0], rp.sendPort, ...msg.sublist(1)]);
    final result = await rp.first;
    rp.close();
    final list = result as List;
    final code = list[0] as int;
    if (code == 1) throw Exception('${list[1]}');
    return list.length > 1 ? list[1] as T : (null as T);
  }

  Future<void> initialize({
    String? modelsPath,
    String? gpuProvider,
    String? tier,
  }) async {
    if (_initialized) return;

    final base = modelsPath ?? await _resolveModelsPath();
    _modelsBasePath = base;
    _modelsPath = tier != null ? p.join(base, tier) : base;
    debugPrint('[embedding] ═══ SERVICE INIT ═══');
    debugPrint('[embedding] models path: $_modelsPath');
    debugPrint('[embedding] requested gpuProvider: $gpuProvider');
    debugPrint('[embedding] tier: $tier');

    debugPrint('[embedding] spawning isolate...');
    await _spawnIsolate();
    debugPrint('[embedding] isolate spawned, sending init message...');

    try {
      final result = await _sendToIsolate<List>([0, _modelsPath, gpuProvider, tier]);
      clipDim = result[0] as int;
      _gpuInitError = result[1] as String?;
      final activeProvider = result.length > 2 ? result[2] as String? : null;
      _gpuProvider = (_gpuInitError != null) ? 'CPU' : (activeProvider ?? gpuProvider ?? 'CPU');

      debugPrint('[embedding] isolate replied: clipDim=$clipDim activeProvider=$activeProvider gpuInitError=$_gpuInitError');
      debugPrint('[embedding] final gpuProvider=$_gpuProvider');
    } catch (e) {
      debugPrint('[embedding] CRASH during isolate init: $e');
      rethrow;
    }

    _lastGpuProvider = gpuProvider;
    _initialized = true;
    _touchIdleTimer();
    debugPrint('[embedding] ═══ SERVICE INIT DONE ═══');
  }

  Future<Float32List> embedAudio(Float32List pcm48kHz) async {
    await _ensureInitialized();
    _touchIdleTimer();
    if (pcm48kHz.isEmpty) throw ArgumentError('PCM data is empty');
    var pcm = pcm48kHz;
    if (pcm.length > MelFFI.clapMaxSamples) {
      pcm = Float32List.sublistView(pcm, 0, MelFFI.clapMaxSamples);
    }
    CrashLogger.instance.mark('embedAudio:isolate.send', {
      'pcmLen': pcm.length,
    });
    return _sendToIsolate<Float32List>([1, pcm]);
  }

  Future<Float32List> embedImage(Uint8List imageBytes) async {
    await _ensureInitialized();
    _touchIdleTimer();
    if (imageBytes.isEmpty) throw ArgumentError('Image bytes are empty');

    CrashLogger.instance.mark('embedImage:decode', {
      'byteLen': imageBytes.length,
    });

    final codec = await ui.instantiateImageCodec(
      imageBytes,
      targetWidth: 224,
      targetHeight: 224,
    );
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final bitmap = await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    image.dispose();
    codec.dispose();
    if (bitmap == null) throw Exception('Failed to decode image');

    final pixels = bitmap.buffer.asUint8List();
    const size = 224;
    final floatData = Float32List(3 * size * size);

    if (clipDim == 768) {
      // SigLIP normalization: mean=0.5, std=0.5 (same for all channels)
      for (int y = 0; y < size; y++) {
        for (int x = 0; x < size; x++) {
          final srcIdx = (y * size + x) * 4;
          floatData[0 * size * size + y * size + x] =
              pixels[srcIdx] / 127.5 - 1.0;
          floatData[1 * size * size + y * size + x] =
              pixels[srcIdx + 1] / 127.5 - 1.0;
          floatData[2 * size * size + y * size + x] =
              pixels[srcIdx + 2] / 127.5 - 1.0;
        }
      }
    } else {
      // CLIP normalization: per-channel mean/std
      const meanR = 0.48145466, meanG = 0.4578275, meanB = 0.40821073;
      const stdR = 0.26862954, stdG = 0.26130258, stdB = 0.27577711;
      for (int y = 0; y < size; y++) {
        for (int x = 0; x < size; x++) {
          final srcIdx = (y * size + x) * 4;
          floatData[0 * size * size + y * size + x] =
              (pixels[srcIdx] / 255.0 - meanR) / stdR;
          floatData[1 * size * size + y * size + x] =
              (pixels[srcIdx + 1] / 255.0 - meanG) / stdG;
          floatData[2 * size * size + y * size + x] =
              (pixels[srcIdx + 2] / 255.0 - meanB) / stdB;
        }
      }
    }

    CrashLogger.instance.mark('embedImage:isolate.send', {
      'floatDataLen': floatData.length,
    });
    return _sendToIsolate<Float32List>([2, floatData]);
  }

  Future<Float32List> embedClipText(Int64List tokenIds) async {
    await _ensureInitialized();
    _touchIdleTimer();
    if (tokenIds.isEmpty) throw ArgumentError('Token IDs are empty');
    CrashLogger.instance.mark('embedClipText:isolate.send', {
      'tokenLen': tokenIds.length,
    });
    final emb = await _sendToIsolate<Float32List>([3, tokenIds]);
    debugPrint(
      '[embed] embedClipText: dim=${emb.length} first5=${emb[0].toStringAsFixed(4)},${emb[1].toStringAsFixed(4)},${emb[2].toStringAsFixed(4)},${emb[3].toStringAsFixed(4)},${emb[4].toStringAsFixed(4)}',
    );
    return emb;
  }

  Future<Float32List> embedClapText(Int64List tokenIds) async {
    await _ensureInitialized();
    _touchIdleTimer();
    if (tokenIds.isEmpty) throw ArgumentError('Token IDs are empty');
    CrashLogger.instance.mark('embedClapText:isolate.send', {
      'tokenLen': tokenIds.length,
    });
    return _sendToIsolate<Float32List>([4, tokenIds]);
  }

  Future<String> ensureModelsInAppDir({String? src}) async {
    final dest = p.join(
      (await getApplicationSupportDirectory()).path,
      'models',
    );
    final srcPath = src ?? p.join(Directory.current.path, 'searchmodels');
    if (await Directory(p.join(dest, 'clip')).exists()) return dest;
    try {
      await _copyDir(
        Directory(p.join(srcPath, 'clip')),
        Directory(p.join(dest, 'clip')),
      );
      await _copyDir(
        Directory(p.join(srcPath, 'clap')),
        Directory(p.join(dest, 'clap')),
      );
      // OCR + Whisper (from 'new' tier or fallback)
      final ocrSrc = p.join(srcPath, 'new', 'ocr');
      if (await Directory(ocrSrc).exists()) {
        await _copyDir(Directory(ocrSrc), Directory(p.join(dest, 'ocr')));
      }
      final whisperSrc = p.join(srcPath, 'new', 'whisper');
      if (await Directory(whisperSrc).exists()) {
        await _copyDir(Directory(whisperSrc), Directory(p.join(dest, 'whisper')));
      }
      debugPrint('[embedding] models copied to $dest');
    } catch (e) {
      debugPrint('[embedding] failed to copy models: $e');
    }
    return dest;
  }

  Future<void> _copyDir(Directory src, Directory dst) async {
    await dst.create(recursive: true);
    await for (final entity in src.list()) {
      if (entity is File) {
        await entity.copy(p.join(dst.path, p.basename(entity.path)));
      }
    }
  }

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    if (_modelsBasePath != null) {
      await initialize(
        modelsPath: _modelsBasePath,
        gpuProvider: _lastGpuProvider,
      );
    }
    if (!_initialized) {
      throw StateError('EmbeddingService not initialized');
    }
  }

  static int clipDimForTier(String tier) => 768;

  static Future<String> resolveModelsPath() => _resolveModelsPath();
}

Future<String> _resolveModelsPath() async {
  return p.join((await getApplicationSupportDirectory()).path, 'models');
}
