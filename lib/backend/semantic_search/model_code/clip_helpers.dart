import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:onnxruntime_v2/onnxruntime_v2.dart';

bool _ortInitialized = false;

Future<OrtSession> createOrtSession(String modelPath) async {
  if (!_ortInitialized) {
    OrtEnv.instance.init();
    _ortInitialized = true;
  }
  final options = OrtSessionOptions();
  await options.appendDefaultProviders();
  final file = File(modelPath);
  final session = OrtSession.fromFile(file, options);
  return session;
}

Future<void> closeOrtSession(OrtSession? session) async {
  if (session != null) {
    await session.release();
  }
}

Float32List normalizeEmbedding(List<num> raw) {
  final vec = Float32List(raw.length);
  var norm = 0.0;
  for (var i = 0; i < raw.length; i++) {
    final v = raw[i].toDouble();
    vec[i] = v;
    norm += v * v;
  }
  norm = sqrt(norm);
  if (norm > 0) {
    for (var i = 0; i < vec.length; i++) {
      vec[i] /= norm;
    }
  }
  return vec;
}

// resize to 224x224, normalize with CLIP mean/std, convert to CHW float tensor.

Float32List preprocessClipImage(Uint8List imageBytes) {
  final decoded = img.decodeImage(imageBytes);
  if (decoded == null) throw Exception('Failed to decode image');

  final resized = img.copyResize(
    decoded,
    width: 224,
    height: 224,
    interpolation: img.Interpolation.linear,
  );

  const mean = [0.48145466, 0.4578275, 0.40821073];
  const std = [0.26862954, 0.26130258, 0.27577711];

  final floatData = Float32List(1 * 3 * 224 * 224);

  for (var y = 0; y < 224; y++) {
    for (var x = 0; x < 224; x++) {
      final pixel = resized.getPixel(x, y);
      final r = pixel.r / 255.0;
      final g = pixel.g / 255.0;
      final b = pixel.b / 255.0;

      // CHW layout
      floatData[0 * 224 * 224 + y * 224 + x] = (r - mean[0]) / std[0];
      floatData[1 * 224 * 224 + y * 224 + x] = (g - mean[1]) / std[1];
      floatData[2 * 224 * 224 + y * 224 + x] = (b - mean[2]) / std[2];
    }
  }

  return floatData;
}

Future<Float32List> runClipVision(
  OrtSession session,
  Float32List pixelData,
) async {
  final inputName = session.inputNames.first;
  final tensor = OrtValueTensor.createTensorWithDataList(pixelData, [
    1,
    3,
    224,
    224,
  ]);

  final inputs = {inputName: tensor};
  final runOptions = OrtRunOptions();
  final outputs = await session.runAsync(runOptions, inputs);

  tensor.release();
  runOptions.release();

  if (outputs == null || outputs.isEmpty || outputs.first == null) {
    throw Exception('CLIP vision model produced no output');
  }

  final output = outputs.first!;
  final rawValues = (output as OrtValueTensor).value;
  output.release();

  if (rawValues is List<num>) {
    return normalizeEmbedding(rawValues);
  }
  if (rawValues is List && rawValues.isNotEmpty && rawValues.first is List) {
    return normalizeEmbedding((rawValues.first as List).cast<num>());
  }
  throw Exception('Unexpected vision output type: ${rawValues.runtimeType}');
}

Future<Float32List> runClipText(OrtSession session, List<int> tokenIds) async {
  final inputIdsName = session.inputNames.firstWhere(
    (n) => n == 'input_ids',
    orElse: () => session.inputNames.first,
  );
  final attentionMaskName = session.inputNames.firstWhere(
    (n) => n == 'attention_mask',
    orElse: () => session.inputNames.length > 1 ? session.inputNames[1] : '',
  );

  final int64Data = Int64List.fromList(tokenIds);
  final inputIdsTensor = OrtValueTensor.createTensorWithDataList(int64Data, [
    1,
    tokenIds.length,
  ]);

  // attention mask: 1 for real tokens, 0 for padding
  final maskData = Int64List.fromList(
    tokenIds.map((t) => t == ClipBpeTokenizer.padToken ? 0 : 1).toList(),
  );
  final maskTensor = OrtValueTensor.createTensorWithDataList(maskData, [
    1,
    tokenIds.length,
  ]);

  final inputs = <String, OrtValueTensor>{
    inputIdsName: inputIdsTensor,
    if (attentionMaskName.isNotEmpty) attentionMaskName: maskTensor,
  };
  final runOptions = OrtRunOptions();
  final outputs = await session.runAsync(runOptions, inputs);

  inputIdsTensor.release();
  maskTensor.release();
  runOptions.release();

  if (outputs == null || outputs.isEmpty || outputs.first == null) {
    throw Exception('CLIP text model produced no output');
  }

  final output = outputs.first!;
  final rawValues = (output as OrtValueTensor).value;
  output.release();

  if (rawValues is List<num>) {
    return normalizeEmbedding(rawValues);
  }
  if (rawValues is List && rawValues.isNotEmpty && rawValues.first is List) {
    return normalizeEmbedding((rawValues.first as List).cast<num>());
  }
  throw Exception('Unexpected text output type: ${rawValues.runtimeType}');
}

class ClipBpeTokenizer {
  final Map<String, int> _vocab;
  final List<(String, String)> _merges;

  static const int maxLength = 77;
  static const int bosToken = 49406;
  static const int eosToken = 49407;
  static const int padToken = 0;

  ClipBpeTokenizer._(this._vocab, this._merges);

  static Future<ClipBpeTokenizer> load({
    required String vocabPath,
    required String mergesPath,
  }) async {
    final vocabJson = await File(vocabPath).readAsString();
    final vocab = (jsonDecode(vocabJson) as Map<String, dynamic>).map(
      (k, v) => MapEntry(k, v as int),
    );

    final mergesLines = await File(mergesPath).readAsLines();
    final merges = <(String, String)>[];
    // first line is header, skip it
    for (var i = 1; i < mergesLines.length; i++) {
      final line = mergesLines[i].trim();
      if (line.isEmpty) continue;
      final parts = line.split(' ');
      if (parts.length == 2) {
        merges.add((parts[0], parts[1]));
      }
    }

    return ClipBpeTokenizer._(vocab, merges);
  }

  List<int> encode(String text) {
    // lowercase + whitespace collapse
    final normalized = text.toLowerCase().trim().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );

    // split into words
    final words = normalized.split(' ');

    // BPE each word
    final bpeTokens = <String>[];
    for (final word in words) {
      if (word.isEmpty) continue;
      final chars = word.split('');
      final merged = bpeMerge(chars);
      bpeTokens.addAll(merged);
    }

    // map to token ids
    final tokenIds = <int>[bosToken];
    for (final token in bpeTokens) {
      final id = _vocab[token];
      if (id != null) {
        tokenIds.add(id);
      } else {
        // try with </w> suffix for last token
        final withEnd = '$token</w>';
        final endId = _vocab[withEnd];
        if (endId != null) {
          tokenIds.add(endId);
        }
      }
    }
    tokenIds.add(eosToken);

    // pad or truncate to maxLength
    if (tokenIds.length > maxLength) {
      return tokenIds.sublist(0, maxLength);
    }

    final padded = List<int>.filled(maxLength, padToken);
    for (var i = 0; i < tokenIds.length; i++) {
      padded[i] = tokenIds[i];
    }
    return padded;
  }

  List<String> bpeMerge(List<String> tokens) {
    var result = List<String>.from(tokens);

    while (result.length > 1) {
      var bestIdx = -1;
      for (var i = 0; i < result.length - 1; i++) {
        final pair = (result[i], result[i + 1]);
        final idx = _merges.indexOf(pair);
        if (idx == -1) continue;
        if (bestIdx == -1 || idx < bestIdx) {
          bestIdx = idx;
        }
      }

      if (bestIdx == -1) break;

      final mergePair = _merges[bestIdx];
      final merged = <String>[];
      var i = 0;
      while (i < result.length) {
        if (i < result.length - 1 &&
            result[i] == mergePair.$1 &&
            result[i + 1] == mergePair.$2) {
          merged.add('${mergePair.$1}${mergePair.$2}');
          i += 2;
        } else {
          merged.add(result[i]);
          i += 1;
        }
      }
      result = merged;
    }

    return result;
  }
}
