import 'dart:io';

enum EmbeddingModelKind { clipVitB32, jinaV5OmniNano }

enum EmbeddingModality { text, image, audio, video }

/// Parsed model manifest from package.txt inside a model ZIP.
class ModelManifest {
  final String type;
  final String name;
  final List<String> supports;
  final String runtime;
  final String modelDir;
  final double scoreScale;
  final double scoreBias;

  const ModelManifest({
    required this.type,
    required this.name,
    required this.supports,
    required this.runtime,
    required this.modelDir,
    this.scoreScale = 1.0,
    this.scoreBias = 0.0,
  });

  /// Parse package.txt from a model directory.
  /// Returns null if file is missing or malformed.
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

      final type = kv['type'];
      final name = kv['name'];
      final supportsRaw = kv['supports'];
      final runtime = kv['runtime'];
      if (type == null || name == null || supportsRaw == null || runtime == null) {
        return null;
      }

      return ModelManifest(
        type: type,
        name: name,
        supports: supportsRaw.split(',').map((s) => s.trim().toLowerCase()).where((s) => s.isNotEmpty).toList(),
        runtime: runtime,
        modelDir: dirPath,
        scoreScale: double.tryParse(kv['score_scale'] ?? '') ?? 1.0,
        scoreBias: double.tryParse(kv['score_bias'] ?? '') ?? 0.0,
      );
    } catch (_) {
      return null;
    }
  }

  bool get supportsText => supports.contains('text');
  bool get supportsImage => supports.contains('image');
  bool get supportsAudio => supports.contains('audio');
  bool get supportsVideo => supports.contains('video');

  /// Human-readable summary of supported modalities.
  String get supportsSummary => supports.join(', ');
}

class ModelInstallInfo {
  final EmbeddingModelKind kind;
  final String name;
  final bool installed;
  final bool enabled;
  final String? modelDir;
  final String? version;
  final String? runtime; // onnx, native-sidecar, python, etc.

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
