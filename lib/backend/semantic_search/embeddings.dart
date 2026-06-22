import 'dart:typed_data';
import 'dart:io';

import 'package:memefolder/backend/semantic_search/model_code/clip_backend.dart';
import 'package:memefolder/backend/semantic_search/model_code/jina_backend.dart';
import 'package:memefolder/backend/semantic_search/semantic_search_classes.dart';

// FACTORY!
class EmbeddingBackendFactory {
  static EmbeddingBackend create(ModelInstallInfo info) {
    switch (info.kind) {
      case EmbeddingModelKind.clipVitB32:
        return ClipBackend(modelDir: info.modelDir!);
      case EmbeddingModelKind.jinaV5OmniNano:
        return JinaBackend(modelDir: info.modelDir!);
    }
  }
}

class EmbeddingVector {
  final Float32List values;
  final EmbeddingModelKind model;
  final EmbeddingModality modality;
  final int dims;

  const EmbeddingVector({
    required this.values,
    required this.model,
    required this.modality,
    required this.dims,
  });
}

abstract class EmbeddingBackend {
  EmbeddingModelKind get kind;
  String get displayName;

  Future<bool> isAvailable();
  Future<void> warmup();
  Future<void> dispose();

  Future<EmbeddingVector> embedText(String text);

  Future<EmbeddingVector> embedImageFile(File file);

  Future<List<EmbeddingVector>> embedImageFiles(List<File> files) async {
    final out = <EmbeddingVector>[];
    for (final file in files) {
      out.add(await embedImageFile(file));
    }
    return out;
  }

  Future<List<EmbeddingVector>> embedTexts(List<String> texts) async {
    final out = <EmbeddingVector>[];
    for (final text in texts) {
      out.add(await embedText(text));
    }
    return out;
  }

  bool supports(EmbeddingModality modality);
}
