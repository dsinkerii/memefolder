import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:onnxruntime_v2/onnxruntime_v2.dart';
import 'package:path/path.dart' as p;

import 'mel_ffi.dart';
import 'tokenizer.dart';

const _sotId = 50258;
const _enId = 50259;
const _transcribeId = 50359;
const _notimestampsId = 50363;
const _eosId = 50257;
const _maxDecodeTokens = 224;

void captionIsolateMain(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  OrtSession? ocrDet;
  OrtSession? ocrRec;
  OrtSession? whisperEnc;
  OrtSession? whisperDec;
  OrtSession? whisperDecCached;
  MelFFI? mel;
  List<String>? ocrVocab;
  WhisperTokenizer? whisperTokenizer;

  receivePort.listen((dynamic message) {
    final msg = message as List;
    final method = msg[0] as int;
    final replyPort = msg[1] as SendPort;

    try {
      switch (method) {
        case 0: // init
          final modelsPath = msg[2] as String;
          final gpuProvider = msg[3] as String?;

          mel = MelFFI();

          final lines = File(p.join(modelsPath, 'ocr', 'vocab.txt'))
              .readAsLinesSync();
          ocrVocab = [''] + lines;

          OrtEnv.instance.init();
          final availableProviders = OrtEnv.instance.availableProviders();
          final options = OrtSessionOptions();
          final gpuUpper = gpuProvider?.toUpperCase();
          if (gpuProvider != null && gpuUpper != 'CPU') {
            try {
              if (gpuUpper == 'CUDA' && availableProviders.contains(OrtProvider.cuda)) {
                options.appendCudaProvider(CUDAFlags.useNone);
              }
            } catch (_) {}
            try {
              if (gpuUpper == 'TENSORRT' && (availableProviders.contains(OrtProvider.tensorrt) || availableProviders.contains(OrtProvider.nvTensorRtRtx))) {
                options.appendNvTensorRtRtxProvider();
              }
            } catch (_) {}
          }
          try {
            options.appendCPUProvider(CPUFlags.useArena);
          } catch (_) {}
          options.setIntraOpNumThreads(4);
          options.setSessionGraphOptimizationLevel(
            GraphOptimizationLevel.ortEnableAll,
          );

          whisperTokenizer = WhisperTokenizer.fromFile(
            p.join(modelsPath, 'whisper', 'tokenizer.json'),
          );

          ocrDet = OrtSession.fromBuffer(
            File(p.join(modelsPath, 'ocr', 'detection.onnx'))
                .readAsBytesSync(),
            options,
          );
          ocrRec = OrtSession.fromBuffer(
            File(p.join(modelsPath, 'ocr', 'recognition.onnx'))
                .readAsBytesSync(),
            options,
          );
          whisperEnc = OrtSession.fromBuffer(
            File(p.join(modelsPath, 'whisper', 'tiny_encoder.onnx'))
                .readAsBytesSync(),
            options,
          );
          whisperDec = OrtSession.fromBuffer(
            File(p.join(modelsPath, 'whisper', 'tiny_decoder.onnx'))
                .readAsBytesSync(),
            options,
          );
          try {
            whisperDecCached = OrtSession.fromBuffer(
              File(p.join(modelsPath, 'whisper', 'tiny_decoder_with_past.onnx'))
                  .readAsBytesSync(),
              options,
            );
          } catch (_) {}

          replyPort.send([0, null]);
          break;

        case 1: // ocr recognition
          final floatData = msg[2] as Float32List;
          final width = msg[3] as int;
          final sw = Stopwatch()..start();
          final input = OrtValueTensor.createTensorWithDataList(
            [floatData],
            [1, 3, 48, width],
          );
          final runOpts = OrtRunOptions();
          final outputs = ocrRec!.run(runOpts, {'x': input});
          final logits = _extractFloat32List(outputs[0] as OrtValueTensor);
          for (final o in outputs) {
            try { (o as OrtValueTensor).release(); } catch (_) {}
          }
          input.release();
          runOpts.release();
          final t = logits.length ~/ 18385;
          final text = _ctcGreedyDecode(logits, t, 18385, ocrVocab!);
          sw.stop();
          stderr.writeln('[caption-iso] ocr rec: ${sw.elapsedMilliseconds}ms w=$width t=$t');
          replyPort.send([0, text]);
          break;

        case 4: // ocr detection
          final floatData = msg[2] as Float32List;
          final height = msg[3] as int;
          final width = msg[4] as int;
          final sw = Stopwatch()..start();
          final input = OrtValueTensor.createTensorWithDataList(
            [floatData],
            [1, 3, height, width],
          );
          final runOpts = OrtRunOptions();
          final outputs = ocrDet!.run(runOpts, {'x': input});
          final prob = _extractFloat32List(outputs[0] as OrtValueTensor);
          for (final o in outputs) {
            try { (o as OrtValueTensor).release(); } catch (_) {}
          }
          input.release();
          runOpts.release();
          sw.stop();
          stderr.writeln('[caption-iso] ocr det: ${sw.elapsedMilliseconds}ms ${width}x$height');
          replyPort.send([0, prob]);
          break;

        case 2: // whisper
          final pcm = msg[2] as Float32List;
          stderr.writeln('[caption-iso] whisper: pcmLen=${pcm.length} start mel');
          final text = _runWhisper(whisperEnc!, whisperDec!, whisperDecCached, mel!, pcm, whisperTokenizer!);
          stderr.writeln('[caption-iso] whisper: done len=${text.length}');
          replyPort.send([0, text]);
          break;

        case 3: // dispose
          ocrDet?.release();
          ocrRec?.release();
          whisperEnc?.release();
          whisperDec?.release();
          whisperDecCached?.release();
          mel?.dispose();
          ocrDet = null;
          ocrRec = null;
          whisperEnc = null;
          whisperDec = null;
          whisperDecCached = null;
          mel = null;
          break;
      }
    } catch (e) {
      replyPort.send([1, '$e']);
    }
  });
}

String _runWhisper(
  OrtSession enc,
  OrtSession dec,
  OrtSession? decCached,
  MelFFI mel,
  Float32List pcm,
  WhisperTokenizer tokenizer,
) {
  var processed = pcm;
  if (pcm.length > MelFFI.whisperMaxSamples) {
    processed = Float32List.sublistView(pcm, 0, MelFFI.whisperMaxSamples);
  }
  final melData = mel.computeWhisperMel(processed);

  // transpose [3000,80] to [80,3000] for onnx encoder
  final transposed = Float32List(MelFFI.whisperNFrames * MelFFI.whisperNMels);
  for (int t = 0; t < MelFFI.whisperNFrames; t++) {
    for (int m = 0; m < MelFFI.whisperNMels; m++) {
      transposed[m * MelFFI.whisperNFrames + t] = melData[t * MelFFI.whisperNMels + m];
    }
  }
  final melInput = OrtValueTensor.createTensorWithDataList(
    [transposed],
    [1, MelFFI.whisperNMels, MelFFI.whisperNFrames],
  );

  final encRunOpts = OrtRunOptions();
  final encOuts = enc.run(encRunOpts, {'input_features': melInput});
  final encState = _extractFloat32List(encOuts[0] as OrtValueTensor);
  for (final o in encOuts) {
    try { (o as OrtValueTensor).release(); } catch (_) {}
  }
  melInput.release();
  encRunOpts.release();

  // Create encoder hidden states tensor (reused across all decoder steps)
  final encTensor = OrtValueTensor.createTensorWithDataList(
    [encState],
    [1, 1500, 384],
  );

  // --- Step 0: run regular decoder with full prompt ---
  final promptTokens = Int64List.fromList([_sotId, _enId, _transcribeId, _notimestampsId]);
  final idsTensor = OrtValueTensor.createTensorWithDataList(
    [promptTokens],
    [1, 4],
  );
  final decRunOpts = OrtRunOptions();
  final decOuts = dec.run(
    decRunOpts,
    {'input_ids': idsTensor, 'encoder_hidden_states': encTensor},
  );
  final logits0 = _extractFloat32List(decOuts[0] as OrtValueTensor);

  // Capture KV cache from step 0 outputs (index-based, order is deterministic)
  // Regular decoder outputs: [logits, present.0.dec.k, present.0.dec.v, present.0.enc.k, present.0.enc.v, ...]
  List<Float32List>? decKvKeys;   // [4 layers] of Float32List
  List<Float32List>? decKvValues; // [4 layers] of Float32List
  List<Float32List>? encKvKeys;   // [4 layers] of Float32List
  List<Float32List>? encKvValues; // [4 layers] of Float32List
  if (decCached != null) {
    decKvKeys = List.generate(4, (_) => Float32List(0));
    decKvValues = List.generate(4, (_) => Float32List(0));
    encKvKeys = List.generate(4, (_) => Float32List(0));
    encKvValues = List.generate(4, (_) => Float32List(0));
    // Output order: logits(0), then for each layer 0-3: dec.k(1+4*L), dec.v(2+4*L), enc.k(3+4*L), enc.v(4+4*L)
    for (int layer = 0; layer < 4; layer++) {
      decKvKeys[layer] = _extractFloat32List(decOuts[1 + layer * 4] as OrtValueTensor);
      decKvValues[layer] = _extractFloat32List(decOuts[2 + layer * 4] as OrtValueTensor);
      encKvKeys[layer] = _extractFloat32List(decOuts[3 + layer * 4] as OrtValueTensor);
      encKvValues[layer] = _extractFloat32List(decOuts[4 + layer * 4] as OrtValueTensor);
    }
  }
  for (final o in decOuts) {
    try { (o as OrtValueTensor).release(); } catch (_) {}
  }
  idsTensor.release();
  decRunOpts.release();

  // Get first predicted token from last position of prompt logits
  final vocabSize = 51865;
  final lastLogits0 = logits0.sublist(3 * vocabSize, 4 * vocabSize);
  var nextToken = _argmax(lastLogits0);
  if (nextToken == _eosId) {
    encTensor.release();
    return tokenizer.decodeWhisper([_sotId, _enId, _transcribeId, _notimestampsId]);
  }

  final generated = <int>[_sotId, _enId, _transcribeId, _notimestampsId, nextToken];

  // --- Steps 1+: use cached decoder if available ---
  if (decCached != null) {
    while (generated.length < _maxDecodeTokens) {
      // Build input map for cached decoder
      final inputMap = <String, OrtValueTensor>{};
      final newIds = Int64List.fromList([generated.last]);
      inputMap['input_ids'] = OrtValueTensor.createTensorWithDataList(
        [newIds], [1, 1],
      );
      inputMap['encoder_hidden_states'] = encTensor;
      for (int layer = 0; layer < 4; layer++) {
        final decK = decKvKeys![layer];
        final decV = decKvValues![layer];
        final pastLen = decK.length ~/ 64 ~/ 6;
        inputMap['past_key_values.$layer.decoder.key'] = OrtValueTensor.createTensorWithDataList(
          [decK], [1, 6, pastLen, 64],
        );
        inputMap['past_key_values.$layer.decoder.value'] = OrtValueTensor.createTensorWithDataList(
          [decV], [1, 6, pastLen, 64],
        );
        inputMap['past_key_values.$layer.encoder.key'] = OrtValueTensor.createTensorWithDataList(
          [encKvKeys![layer]], [1, 6, 1500, 64],
        );
        inputMap['past_key_values.$layer.encoder.value'] = OrtValueTensor.createTensorWithDataList(
          [encKvValues![layer]], [1, 6, 1500, 64],
        );
      }

      final runOpts = OrtRunOptions();
      final outs = decCached.run(runOpts, inputMap);
      final logits = _extractFloat32List(outs[0] as OrtValueTensor);

      // Update decoder KV cache from present outputs
      // Cached decoder output order: logits(0), then for each layer 0-3: dec.k(1+2*L), dec.v(2+2*L)
      for (int layer = 0; layer < 4; layer++) {
        decKvKeys![layer] = _extractFloat32List(outs[1 + layer * 2] as OrtValueTensor);
        decKvValues![layer] = _extractFloat32List(outs[2 + layer * 2] as OrtValueTensor);
      }

      // Release all tensors
      for (final o in outs) {
        try { (o as OrtValueTensor).release(); } catch (_) {}
      }
      for (final entry in inputMap.entries) {
        if (entry.key != 'encoder_hidden_states') {
          entry.value.release();
        }
      }
      runOpts.release();

      nextToken = _argmax(logits.sublist(0, vocabSize));
      if (nextToken == _eosId) break;
      generated.add(nextToken);
    }
  } else {
    // Fallback: no cached decoder, use original O(N) loop
    while (generated.length < _maxDecodeTokens) {
      final inputIds = Int64List.fromList(generated);
      final idsT = OrtValueTensor.createTensorWithDataList(
        [inputIds], [1, generated.length],
      );
      final runOpts = OrtRunOptions();
      final outs = dec.run(
        runOpts,
        {'input_ids': idsT, 'encoder_hidden_states': encTensor},
      );
      final logits = _extractFloat32List(outs[0] as OrtValueTensor);
      for (final o in outs) {
        try { (o as OrtValueTensor).release(); } catch (_) {}
      }
      idsT.release();
      runOpts.release();
      nextToken = _argmax(logits.sublist((generated.length - 1) * vocabSize, generated.length * vocabSize));
      if (nextToken == _eosId) break;
      generated.add(nextToken);
    }
  }

  encTensor.release();
  return tokenizer.decodeWhisper(generated);
}

int _argmax(Float32List logits) {
  var bestIdx = 0;
  var bestVal = -1e30;
  for (int i = 0; i < logits.length; i++) {
    if (logits[i] > bestVal) {
      bestVal = logits[i];
      bestIdx = i;
    }
  }
  return bestIdx;
}

String _ctcGreedyDecode(
  Float32List logits,
  int timeSteps,
  int numClasses,
  List<String> vocab,
) {
  final sb = StringBuffer();
  var prevIdx = 0;
  var blankStreak = 0;
  for (int t = 0; t < timeSteps; t++) {
    var bestIdx = 0;
    var bestVal = -1e30;
    final offset = t * numClasses;
    for (int c = 0; c < numClasses; c++) {
      if (logits[offset + c] > bestVal) {
        bestVal = logits[offset + c];
        bestIdx = c;
      }
    }
    if (bestIdx == 0 || bestIdx == prevIdx) {
      blankStreak++;
      if (blankStreak > 30 && sb.isNotEmpty) break;
    } else {
      blankStreak = 0;
      if (bestIdx < vocab.length) {
        sb.write(vocab[bestIdx]);
      }
    }
    prevIdx = bestIdx;
  }
  return sb.toString();
}

Float32List _extractFloat32List(OrtValueTensor tensor) {
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
    void flatten(dynamic e) {
      if (e is List) {
        for (final item in e) flatten(item);
      } else if (e is num) {
        flat.add(e.toDouble());
      }
    }
    for (final e in v) flatten(e);
    if (flat.isNotEmpty) return Float32List.fromList(flat);
  }
  throw Exception('unexpected tensor value type: ${v.runtimeType}');
}
