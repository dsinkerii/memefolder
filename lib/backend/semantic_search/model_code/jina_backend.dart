import 'dart:io';

import 'package:memefolder/backend/semantic_search/embeddings.dart';
import 'package:memefolder/backend/semantic_search/semantic_search_classes.dart';

class JinaBackend implements EmbeddingBackend {
  @override
  EmbeddingModelKind get kind => EmbeddingModelKind.jinaV5OmniNano;

  @override
  String get displayName => 'Jina v5 Omni Nano';

  final String modelDir;

  JinaBackend({required this.modelDir});

  @override
  Future<bool> isAvailable() async {
    return Directory(modelDir).existsSync();
  }

  @override
  Future<void> warmup() async {}

  @override
  Future<void> dispose() async {}

  @override
  bool supports(EmbeddingModality modality) {
    return true; // intended API-wise, even if not implemented yet
  }

  @override
  Future<EmbeddingVector> embedText(String text) async {
    throw UnimplementedError('Jina backend not implemented yet');
  }

  @override
  Future<EmbeddingVector> embedImageFile(File file) async {
    throw UnimplementedError('Jina backend not implemented yet');
  }

  @override
  Future<List<EmbeddingVector>> embedImageFiles(List<File> files) {
    // TODO: implement embedImageFiles
    throw UnimplementedError();
  }

  @override
  Future<List<EmbeddingVector>> embedTexts(List<String> texts) {
    // TODO: implement embedTexts
    throw UnimplementedError();
  }
}
