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

          final options = OrtSessionOptions();
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
            } catch (_) {}
          }
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

          replyPort.send([0, null]);
          break;

        case 1: // ocr recognition
          final floatData = msg[2] as Float32List;
          final width = msg[3] as int;
          final input = OrtValueTensor.createTensorWithDataList(
            [floatData],
            [1, 3, 48, width],
          );
          final outputs = ocrRec!.run(OrtRunOptions(), {'x': input});
          final logits = _extractFloat32List(outputs[0] as OrtValueTensor);
          final t = logits.length ~/ 18385;
          final text = _ctcGreedyDecode(logits, t, 18385, ocrVocab!);
          replyPort.send([0, text]);
          break;

        case 4: // ocr detection
          final floatData = msg[2] as Float32List;
          final height = msg[3] as int;
          final width = msg[4] as int;
          final input = OrtValueTensor.createTensorWithDataList(
            [floatData],
            [1, 3, height, width],
          );
          final outputs = ocrDet!.run(OrtRunOptions(), {'x': input});
          final prob = _extractFloat32List(outputs[0] as OrtValueTensor);
          replyPort.send([0, prob]);
          break;

        case 2: // whisper
          final pcm = msg[2] as Float32List;
          stderr.writeln('[caption-iso] whisper: pcmLen=${pcm.length} start mel');
          final text = _runWhisper(whisperEnc!, whisperDec!, mel!, pcm, whisperTokenizer!);
          stderr.writeln('[caption-iso] whisper: done len=${text.length}');
          replyPort.send([0, text]);
          break;

        case 3: // dispose
          ocrDet?.release();
          ocrRec?.release();
          whisperEnc?.release();
          whisperDec?.release();
          mel?.dispose();
          ocrDet = null;
          ocrRec = null;
          whisperEnc = null;
          whisperDec = null;
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

  final encOuts = enc.run(OrtRunOptions(), {'input_features': melInput});
  final encState = _extractFloat32List(encOuts[0] as OrtValueTensor);

  final generated = <int>[_sotId, _enId, _transcribeId, _notimestampsId];

  while (generated.length < _maxDecodeTokens) {
    final inputIds = Int64List.fromList(generated);
    final idsTensor = OrtValueTensor.createTensorWithDataList(
      [inputIds],
      [1, generated.length],
    );
    final encTensor = OrtValueTensor.createTensorWithDataList(
      [encState],
      [1, 1500, 384],
    );
    final decOuts = dec.run(
      OrtRunOptions(),
      {'input_ids': idsTensor, 'encoder_hidden_states': encTensor},
    );
    final logits = _extractFloat32List(decOuts[0] as OrtValueTensor);
    final vocabSize = 51865;
    final seqLen = generated.length;
    final lastLogits = logits.sublist((seqLen - 1) * vocabSize, seqLen * vocabSize);
    var nextToken = 0;
    var bestVal = -1e30;
    for (int i = 0; i < lastLogits.length; i++) {
      if (lastLogits[i] > bestVal) {
        bestVal = lastLogits[i];
        nextToken = i;
      }
    }
    if (nextToken == _eosId) break;
    generated.add(nextToken);
  }

  return tokenizer.decodeWhisper(generated);
}

String _ctcGreedyDecode(
  Float32List logits,
  int timeSteps,
  int numClasses,
  List<String> vocab,
) {
  final sb = StringBuffer();
  var prevIdx = 0;
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
    if (bestIdx != prevIdx && bestIdx != 0) {
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
