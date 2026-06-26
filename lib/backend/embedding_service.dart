import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:memefolder/prefs.dart';
import 'package:memefolder/utils/crash_logger.dart';

import 'package:onnxruntime_v2/onnxruntime_v2.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'mel_ffi.dart';

enum ModelType { clipVision, clipText, clapAudio, clapText }

class EmbeddingService {
  static final EmbeddingService instance = EmbeddingService._();

  EmbeddingService._();

  bool _initialized = false;
  bool get isInitialized => _initialized;

  // Model sessions
  OrtSession? _clipVision;
  OrtSession? _clipText;
  OrtSession? _clapAudio;
  OrtSession? _clapText;

  /// Embedding dimensions depend on model tier.
  /// Low tier (ViT-B/32): CLIP=512, CLAP=512.
  /// Mid/high tier (ViT-L/14): CLIP=768, CLAP=512.
  int clipDim = 512;
  int get clapDim => 512;
  String _gpuProvider = 'CPU';
  String get gpuProvider => _gpuProvider;
  String? _gpuInitError;
  String? get gpuInitError => _gpuInitError;

  // C FFI for audio preprocessing
  MelFFI? _mel;

  /// Path to directory containing model files
  String? _modelsPath;
  String? get modelsPath => _modelsPath;
  String? _modelsBasePath;

  Timer? _idleTimer;
  int get _idleTimeoutMinutes =>
      PlayerPrefs.getInt('model_idle_timeout', 10);
  String? _lastTier;
  String? _lastGpuProvider;
  int? _lastClipDim;

  void _touchIdleTimer() {
    _idleTimer?.cancel();
    final minutes = _idleTimeoutMinutes;
    if (minutes <= 0) return;
    _idleTimer = Timer(Duration(minutes: minutes), unload);
  }

  void restartIdleTimer() => _touchIdleTimer();

  Future<void> unload() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    if (!_initialized) return;
    debugPrint('[embedding] unloading models after idle timeout');
    await _clapAudio?.release();
    await _clapText?.release();
    await _clipVision?.release();
    await _clipText?.release();
    _clapAudio = null;
    _clapText = null;
    _clipVision = null;
    _clipText = null;
    _mel = null;
    _initialized = false;
  }

  Future<void> initialize({
    String? modelsPath,
    String? gpuProvider,
    int? clipDim,
    String? tier,
  }) async {
    if (_initialized) return;

    final base = modelsPath ?? await _resolveModelsPath();
    _modelsBasePath = base;
    _modelsPath = tier != null ? p.join(base, tier) : base;
    debugPrint('[embedding] models path: $_modelsPath');
    if (clipDim != null) this.clipDim = clipDim;
    _mel = MelFFI();

    final options = OrtSessionOptions();
    await options.appendDefaultProviders();
    if (gpuProvider != null && gpuProvider != 'CPU') {
      try {
        switch (gpuProvider) {
          case 'CUDA':
            options.appendCudaProvider(CUDAFlags.useNone);
            break;
          case 'ROCm':
            options.appendRocmProvider(ROCmFlags.useNone);
            break;
          case 'DirectML':
            options.appendDirectMLProvider();
            break;
          case 'CoreML':
            options.appendCoreMLProvider(CoreMLFlags.useNone);
            break;
          case 'OpenVINO':
            options.appendOpenVINOProvider();
            break;
          case 'TensorRT':
            options.appendTensorRTProvider();
            break;
        }
        _gpuProvider = gpuProvider;
      } catch (e) {
        _gpuInitError = '$e';
        debugPrint('[embedding] GPU provider $gpuProvider not available: $e');
      }
    }
    options.setIntraOpNumThreads(4);
    options.setSessionGraphOptimizationLevel(
      GraphOptimizationLevel.ortEnableAll,
    );

    // Load models (fromBuffer to avoid char/wchar_t path encoding on Windows)
    try {
      _clapAudio = OrtSession.fromBuffer(
        await File(p.join(_modelsPath!, 'clap', 'audio_model_quantized.onnx'))
            .readAsBytes(),
        options,
      );
      _clapText = OrtSession.fromBuffer(
        await File(p.join(_modelsPath!, 'clap', 'text_model_quantized.onnx'))
            .readAsBytes(),
        options,
      );
      _clipVision = OrtSession.fromBuffer(
        await File(p.join(_modelsPath!, 'clip', 'vision_model.onnx'))
            .readAsBytes(),
        options,
      );
      _clipText = OrtSession.fromBuffer(
        await File(p.join(_modelsPath!, 'clip', 'text_model.onnx'))
            .readAsBytes(),
        options,
      );
    } catch (e) {
      final path = _modelsPath;
      _modelsPath = null;
      _modelsBasePath = null;
      _initialized = false;
      throw Exception(
        'Failed to load models from $path: $e',
      );
    }

    _lastTier = tier;
    _lastGpuProvider = gpuProvider;
    _lastClipDim = clipDim;
    _initialized = true;
    _touchIdleTimer();
  }

  /// Embed audio file → 512d CLAP embedding.
  /// Requires 48kHz mono PCM data.
  Future<Float32List> embedAudio(Float32List pcm48kHz) async {
    await _ensureInitialized();
    _touchIdleTimer();

    if (pcm48kHz.isEmpty) {
      throw ArgumentError('PCM data is empty');
    }
    if (pcm48kHz.length > MelFFI.clapMaxSamples) {
      throw ArgumentError(
        'PCM too long: ${pcm48kHz.length} samples (max ${MelFFI.clapMaxSamples})',
      );
    }
    // Check for all-zeros which can cause NaN in mel filterbank
    bool allZero = true;
    for (int i = 0; i < pcm48kHz.length && i < 1000; i++) {
      if (pcm48kHz[i] != 0.0) {
        allZero = false;
        break;
      }
    }
    if (allZero) {
      debugPrint('[embed] warning: PCM data is all zeros');
    }

    CrashLogger.instance.mark('embedAudio:computeClapMel', {
      'pcmLen': pcm48kHz.length,
      'allZero': allZero,
    });
    final mel = _mel!.computeClapMel(pcm48kHz);

    CrashLogger.instance.mark('embedAudio:clapAudio.run', {
      'melShape': '${mel.length} (1x1x${MelFFI.clapNFrames}x${MelFFI.clapNMels})',
    });
    final input = OrtValueTensor.createTensorWithDataList(
      [mel],
      [1, 1, MelFFI.clapNFrames, MelFFI.clapNMels],
    );
    final outputs = _clapAudio!.run(OrtRunOptions(), {'input_features': input});
    return _extractFloat32List(outputs[0] as OrtValueTensor);
  }

  /// Embed image bytes → CLIP embedding (clipDim-d).
  /// Handles JPEG, PNG, etc.
  Future<Float32List> embedImage(Uint8List imageBytes) async {
    await _ensureInitialized();
    _touchIdleTimer();

    if (imageBytes.isEmpty) {
      throw ArgumentError('Image bytes are empty');
    }

    CrashLogger.instance.mark('embedImage:decode', {
      'byteLen': imageBytes.length,
    });

    // Decode and resize to 224x224
    final codec = await ui.instantiateImageCodec(
      imageBytes,
      targetWidth: 224,
      targetHeight: 224,
    );
    final frame = await codec.getNextFrame();
    final bitmap = await frame.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    if (bitmap == null) throw Exception('Failed to decode image');

    // Convert RGBA (4 bytes per pixel) to normalized RGB float32 CHW
    final pixels = bitmap.buffer.asUint8List();
    final size = 224;
    final floatData = Float32List(3 * size * size);
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

    CrashLogger.instance.mark('embedImage:clipVision.run', {
      'floatDataLen': floatData.length,
    });
    final input = OrtValueTensor.createTensorWithDataList(
      [floatData],
      [1, 3, size, size],
    );
    final outputs = _clipVision!.run(OrtRunOptions(), {'pixel_values': input});
    return _extractFloat32List(outputs[0] as OrtValueTensor);
  }

  /// Embed text → CLIP embedding (clipDim-d, for text queries and text files).
  /// Requires token IDs as Int64List.
  Future<Float32List> embedClipText(Int64List tokenIds) async {
    await _ensureInitialized();
    _touchIdleTimer();
    if (tokenIds.isEmpty) {
      throw ArgumentError('Token IDs are empty');
    }
    CrashLogger.instance.mark('embedClipText:clipText.run', {
      'tokenLen': tokenIds.length,
    });
    final input = OrtValueTensor.createTensorWithDataList(
      [tokenIds],
      [1, tokenIds.length],
    );
    final outputs = _clipText!.run(OrtRunOptions(), {'input_ids': input});
    return _extractFloat32List(outputs[0] as OrtValueTensor);
  }

  /// Embed text → 512d CLAP embedding (for audio-related text queries).
  /// Requires token IDs as Int64List.
  Future<Float32List> embedClapText(Int64List tokenIds) async {
    await _ensureInitialized();
    _touchIdleTimer();
    if (tokenIds.isEmpty) {
      throw ArgumentError('Token IDs are empty');
    }
    CrashLogger.instance.mark('embedClapText:clapText.run', {
      'tokenLen': tokenIds.length,
    });
    final input = OrtValueTensor.createTensorWithDataList(
      [tokenIds],
      [1, tokenIds.length],
    );
    final outputs = _clapText!.run(OrtRunOptions(), {'input_ids': input});
    return _extractFloat32List(outputs[0] as OrtValueTensor);
  }

  /// Copy models from [src] to app support dir
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
    if (_lastTier != null) {
      await initialize(
        modelsPath: _modelsBasePath,
        tier: _lastTier,
        gpuProvider: _lastGpuProvider,
        clipDim: _lastClipDim,
      );
    }
    if (!_initialized) {
      throw StateError('EmbeddingService not initialized');
    }
  }

  static int clipDimForTier(String tier) => tier == 'high' ? 768 : 512;

  static Future<String> resolveModelsPath() => _resolveModelsPath();

  static Float32List _extractFloat32List(OrtValueTensor tensor) {
    final v = tensor.value;
    if (v is Float64List) return Float32List.fromList(v);
    if (v is Float32List) return v;
    if (v is List<double>) return Float32List.fromList(v);
    if (v is List<num>) {
      return Float32List.fromList(v.map((e) => e.toDouble()).toList());
    }
    if (v is List<List<double>>) {
      return Float32List.fromList(v.expand((r) => r).toList());
    }
    if (v is List) {
      final flat = <double>[];
      for (final e in v) {
        if (e is List) {
          for (final inner in e) {
            if (inner is double) flat.add(inner);
          }
        }
      }
      if (flat.isNotEmpty) return Float32List.fromList(flat);
    }
    throw Exception('Unexpected tensor value type: ${v.runtimeType}');
  }
}

Future<String> _resolveModelsPath() async {
  return p.join((await getApplicationSupportDirectory()).path, 'models');
}
