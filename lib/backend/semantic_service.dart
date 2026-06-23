import 'dart:io';
import 'dart:typed_data';

import 'package:memefolder/backend/semantic_search/embeddings.dart';
import 'package:memefolder/backend/semantic_search/cosine_search.dart';
import 'package:memefolder/backend/semantic_search/semantic_search_classes.dart';

class SemanticSearchService {
  SemanticSearchConfig _config;
  EmbeddingBackend? _backend;
  final bool useGpu;

  SemanticSearchService(this._config, {this.useGpu = false});

  SemanticSearchConfig get config => _config;
  EmbeddingBackend? get backend => _backend;

  Future<void> initialize() async {
    final info = _config.activeInfo;
    if (!info.installed || !info.enabled) {
      _backend = null;
      return;
    }

    final backend = EmbeddingBackendFactory.create(info, useGpu: useGpu);
    if (!await backend.isAvailable()) {
      _backend = null;
      return;
    }

    await backend.warmup();
    _backend = backend;
  }

  Future<void> reconfigure(SemanticSearchConfig newConfig) async {
    await _backend?.dispose();
    _config = newConfig;
    _backend = null;
    await initialize();
  }

  bool get isReady => _backend != null;

  Future<EmbeddingVector> embedText(String text) async {
    final backend = _backend;
    if (backend == null) {
      throw StateError('Semantic backend is not initialized');
    }
    return backend.embedText(text);
  }

  Future<EmbeddingVector> embedImageFile(File file) async {
    final backend = _backend;
    if (backend == null) {
      throw StateError('Semantic backend is not initialized');
    }
    return backend.embedImageFile(file);
  }

  // semantic search: embed query text, compare against stored embeddings
  Future<List<CosineResult>> search(
    String rootPath,
    String query, {
    int topK = 50,
    double minScore = 0.65,
    String? filterMediaType,
    Set<String>? restrictFileIds,
    double scoreScale = 1.0,
    double scoreBias = 0.0,
  }) async {
    final vec = await embedText(query);
    return cosineSearch(
      rootPath,
      vec.values,
      topK: topK,
      minScore: minScore,
      filterMediaType: filterMediaType,
      restrictFileIds: restrictFileIds,
      scoreScale: scoreScale,
      scoreBias: scoreBias,
    );
  }

  // serialize embedding to BLOB for DB storage
  static Uint8List embeddingToBlob(EmbeddingVector vec) {
    final byteData = ByteData(vec.values.length * 4);
    for (var i = 0; i < vec.values.length; i++) {
      byteData.setFloat32(i * 4, vec.values[i], Endian.little);
    }
    return byteData.buffer.asUint8List();
  }

  // deserialize embedding BLOB from DB
  static Float32List blobToEmbedding(Uint8List blob, int dims) {
    final byteData = ByteData.view(blob.buffer);
    final vec = Float32List(dims);
    for (var i = 0; i < dims; i++) {
      vec[i] = byteData.getFloat32(i * 4, Endian.little);
    }
    return vec;
  }
}
