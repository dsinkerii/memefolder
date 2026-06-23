import 'dart:io';

import 'package:memefolder/backend/semantic_search/embeddings.dart';
import 'package:memefolder/backend/semantic_search/model_code/clip_helpers.dart';
import 'package:memefolder/backend/semantic_search/semantic_search_classes.dart';
import 'package:onnxruntime_v2/onnxruntime_v2.dart';
import 'package:path/path.dart' as p;

class ClipBackend extends EmbeddingBackend {
  final String modelDir;
  final bool useGpu;

  OrtSession? _visionSession;
  OrtSession? _textSession;
  ClipBpeTokenizer? _tokenizer;

  ClipBackend({required this.modelDir, this.useGpu = false});

  @override
  EmbeddingModelKind get kind => EmbeddingModelKind.clipVitB32;

  @override
  String get displayName => 'CLIP ViT-B/32';

  @override
  bool supports(EmbeddingModality modality) {
    return modality == EmbeddingModality.image ||
        modality == EmbeddingModality.text;
  }

  @override
  Future<bool> isAvailable() async {
    final dir = Directory(modelDir);
    if (!dir.existsSync()) return false;

    final needed = [
      'vision_model.onnx',
      'text_model.onnx',
      'vocab.json',
      'merges.txt',
    ];

    return needed.every((name) => File(p.join(modelDir, name)).existsSync());
  }

  @override
  Future<void> warmup() async {
    final visionPath = p.join(modelDir, 'vision_model.onnx');
    final textPath = p.join(modelDir, 'text_model.onnx');
    final vocabPath = p.join(modelDir, 'vocab.json');
    final mergesPath = p.join(modelDir, 'merges.txt');

    _tokenizer = await ClipBpeTokenizer.load(
      vocabPath: vocabPath,
      mergesPath: mergesPath,
    );

    _visionSession = await createOrtSession(visionPath, useGpu: useGpu);
    _textSession = await createOrtSession(textPath, useGpu: useGpu);
  }

  @override
  Future<void> dispose() async {
    await closeOrtSession(_visionSession);
    await closeOrtSession(_textSession);
    _visionSession = null;
    _textSession = null;
  }

  @override
  Future<EmbeddingVector> embedImageFile(File file) async {
    final bytes = await file.readAsBytes();
    final input = preprocessClipImage(bytes);
    final output = await runClipVision(_visionSession!, input);

    return EmbeddingVector(
      values: output,
      model: kind,
      modality: EmbeddingModality.image,
      dims: output.length,
    );
  }

  @override
  Future<EmbeddingVector> embedText(String text) async {
    final tokens = _tokenizer!.encode(text);
    final output = await runClipText(_textSession!, tokens);

    return EmbeddingVector(
      values: output,
      model: kind,
      modality: EmbeddingModality.text,
      dims: output.length,
    );
  }
}
