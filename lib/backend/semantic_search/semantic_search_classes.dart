import 'dart:io';

enum EmbeddingModality { text, image, audio, video }

enum EmbeddingTask {
  metadataText,
  imageEmbedding,
  audioAnalysis,
  ocr,
  speechToText;

  String get label {
    switch (this) {
      case EmbeddingTask.metadataText:
        return 'metadata & text';
      case EmbeddingTask.imageEmbedding:
        return 'image embedding';
      case EmbeddingTask.audioAnalysis:
        return 'audio analysis';
      case EmbeddingTask.ocr:
        return 'OCR';
      case EmbeddingTask.speechToText:
        return 'speech-to-text';
    }
  }
}

class ModelManifest {
  final int version;
  final String type;
  final String name;
  final List<String> supports;
  final List<EmbeddingTask> tasks;
  final String runtime;
  final String modelDir;
  final double scoreScale;
  final double scoreBias;

  const ModelManifest({
    required this.version,
    required this.type,
    required this.name,
    required this.supports,
    required this.tasks,
    required this.runtime,
    required this.modelDir,
    this.scoreScale = 1.0,
    this.scoreBias = 0.0,
  });

  static ModelManifest? fromDir(String dirPath) {
    final file = File('$dirPath/package.txt');
    if (!file.existsSync()) return null;

    try {
      final lines = file.readAsLinesSync();
      final kv = <String, String>{};
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
        final eq = trimmed.indexOf('=');
        if (eq < 0) continue;
        final key = trimmed.substring(0, eq).trim().toLowerCase();
        final val = trimmed.substring(eq + 1).trim();
        kv[key] = val;
      }

      final versionStr = kv['version'];
      final version = int.tryParse(versionStr ?? '');
      if (version == null || version != 2) return null;

      final type = kv['type'];
      final name = kv['name'];
      final runtime = kv['runtime'];
      if (type == null || name == null || runtime == null) return null;

      final supportsRaw = kv['supports'];
      final supports = supportsRaw != null
          ? supportsRaw
              .split(',')
              .map((s) => s.trim().toLowerCase())
              .where((s) => s.isNotEmpty)
              .toList()
          : <String>[];

      final taskRaw = kv['task'];
      final tasks = taskRaw != null
          ? taskRaw
              .split(',')
              .map((s) => s.trim().toLowerCase())
              .where((s) => s.isNotEmpty)
              .map((s) => _parseTask(s))
              .whereType<EmbeddingTask>()
              .toList()
          : _inferTasksFromType(type, supports);

      if (tasks.isEmpty) return null;

      return ModelManifest(
        version: version,
        type: type,
        name: name,
        supports: supports,
        tasks: tasks,
        runtime: runtime,
        modelDir: dirPath,
        scoreScale: double.tryParse(kv['score_scale'] ?? '') ?? 1.0,
        scoreBias: double.tryParse(kv['score_bias'] ?? '') ?? 0.0,
      );
    } catch (_) {
      return null;
    }
  }

  static EmbeddingTask? _parseTask(String s) {
    switch (s) {
      case 'metadata_text':
        return EmbeddingTask.metadataText;
      case 'image_embedding':
        return EmbeddingTask.imageEmbedding;
      case 'audio_analysis':
        return EmbeddingTask.audioAnalysis;
      case 'ocr':
        return EmbeddingTask.ocr;
      case 'speech_to_text':
        return EmbeddingTask.speechToText;
      default:
        return null;
    }
  }

  static List<EmbeddingTask> _inferTasksFromType(String type, List<String> supports) {
    final t = type.toLowerCase();
    if (t == 'clip' || t == 'jina') {
      final tasks = [EmbeddingTask.metadataText];
      if (supports.contains('image')) tasks.add(EmbeddingTask.imageEmbedding);
      return tasks;
    }
    if (t == 'whisper') return [EmbeddingTask.speechToText];
    if (t == 'ocr' || t == 'trocr') return [EmbeddingTask.ocr];
    if (t == 'musicgen' || t == 'clap' || t == 'audio_analysis') {
      return [EmbeddingTask.audioAnalysis];
    }
    return [];
  }

  bool get supportsText => supports.contains('text');
  bool get supportsImage => supports.contains('image');
  bool get supportsAudio => supports.contains('audio');
  bool get supportsVideo => supports.contains('video');

  String get supportsSummary => supports.isEmpty ? 'none' : supports.join(', ');
  String get tasksSummary => tasks.map((t) => t.label).join(', ');
}

// ---- legacy types (used by existing backends) ----

enum EmbeddingModelKind { clipVitB32, jinaV5OmniNano }

class ModelInstallInfo {
  final EmbeddingModelKind kind;
  final String name;
  final bool installed;
  final bool enabled;
  final String? modelDir;
  final String? version;
  final String? runtime;

  const ModelInstallInfo({
    required this.kind,
    required this.name,
    required this.installed,
    required this.enabled,
    this.modelDir,
    this.version,
    this.runtime,
  });

  ModelInstallInfo copyWith({
    bool? installed,
    bool? enabled,
    String? modelDir,
    String? version,
    String? runtime,
  }) {
    return ModelInstallInfo(
      kind: kind,
      name: name,
      installed: installed ?? this.installed,
      enabled: enabled ?? this.enabled,
      modelDir: modelDir ?? this.modelDir,
      version: version ?? this.version,
      runtime: runtime ?? this.runtime,
    );
  }
}

class SemanticSearchConfig {
  final EmbeddingModelKind activeModel;
  final Map<EmbeddingModelKind, ModelInstallInfo> models;

  const SemanticSearchConfig({required this.activeModel, required this.models});

  ModelInstallInfo get activeInfo => models[activeModel]!;

  bool get hasActiveInstalled => activeInfo.installed && activeInfo.enabled;

  SemanticSearchConfig copyWith({
    EmbeddingModelKind? activeModel,
    Map<EmbeddingModelKind, ModelInstallInfo>? models,
  }) {
    return SemanticSearchConfig(
      activeModel: activeModel ?? this.activeModel,
      models: models ?? this.models,
    );
  }
}