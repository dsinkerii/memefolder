import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:onnxruntime_v2/onnxruntime_v2.dart';
import 'package:path/path.dart' as p;

import 'mel_ffi.dart';

// isolate entry point. [mainSendPort] receives the isolate's SendPort
// for bidirectional communication.
void embeddingIsolateMain(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  OrtSession? clipVision;
  OrtSession? clipText;
  OrtSession? clapAudio;
  OrtSession? clapText;
  MelFFI? mel;
  int clipDim = 512;
  int _clipVisionOutputIdx = 0;
  int _clipTextOutputIdx = 0;
  String? gpuInitError;

  receivePort.listen((dynamic message) {
    final msg = message as List;
    final method = msg[0] as int;
    final replyPort = msg[1] as SendPort;

    try {
      switch (method) {
        case 0:
          final modelsPath = msg[2] as String;
          final gpuProvider = msg[3] as String?;
          final tier = msg.length > 4 ? msg[4] as String? : null;
          final isFull = tier == 'full';

          mel = MelFFI();

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
            } catch (e) {
              gpuInitError = '$e';
            }
          }
          options.setIntraOpNumThreads(4);
          options.setSessionGraphOptimizationLevel(
            GraphOptimizationLevel.ortEnableAll,
          );

          // always load SigLIP vision + text
          clipVision = OrtSession.fromBuffer(
            File(
              p.join(modelsPath, 'clip', 'vision_model.onnx'),
            ).readAsBytesSync(),
            options,
          );
          clipText = OrtSession.fromBuffer(
            File(
              p.join(modelsPath, 'clip', 'text_model.onnx'),
            ).readAsBytesSync(),
            options,
          );

          // CLAP audio + text only for Full tier
          if (isFull) {
            // CLAP FP16 requires disabled graph optimizations (ORT 1.26.0
            // simplifiedLayerNormFusion bug inserts cast node with missing ref)
            final clapOpts = OrtSessionOptions();
            if (gpuProvider != null && gpuProvider != 'CPU') {
              try {
                switch (gpuProvider) {
                  case 'CUDA':
                    clapOpts.appendCudaProvider(CUDAFlags.useNone);
                    break;
                  case 'ROCm':
                    clapOpts.appendRocmProvider(ROCmFlags.useNone);
                    break;
                  case 'DirectML':
                    clapOpts.appendDirectMLProvider();
                    break;
                  case 'CoreML':
                    clapOpts.appendCoreMLProvider(CoreMLFlags.useNone);
                    break;
                  case 'OpenVINO':
                    clapOpts.appendOpenVINOProvider();
                    break;
                  case 'TensorRT':
                    clapOpts.appendTensorRTProvider();
                    break;
                }
              } catch (e) {
                gpuInitError = '$e';
              }
            }
            clapOpts.setIntraOpNumThreads(4);
            clapOpts.setSessionGraphOptimizationLevel(
              GraphOptimizationLevel.ortDisableAll,
            );
            clapAudio = OrtSession.fromBuffer(
              File(
                p.join(modelsPath, 'clap', 'audio_model_fp16.onnx'),
              ).readAsBytesSync(),
              clapOpts,
            );
            clapText = OrtSession.fromBuffer(
              File(
                p.join(modelsPath, 'clap', 'text_model_quantized.onnx'),
              ).readAsBytesSync(),
              options,
            );
          }

          try {
            final dummyIds = Int64List.fromList([0]);
            final dummyInput = OrtValueTensor.createTensorWithDataList(
              [dummyIds],
              [1, 1],
            );
            final dummyOutputs = clipText!.run(OrtRunOptions(), {
              'input_ids': dummyInput,
            });
            clipDim = _extractFloat32List(
              dummyOutputs[0] as OrtValueTensor,
            ).length;

            if (dummyOutputs.length > 1) {
              _clipTextOutputIdx = 1;
            }
          } catch (_) {}

          try {
            final dummyPixels = Float32List(3 * 224 * 224);
            final dummyInput = OrtValueTensor.createTensorWithDataList(
              [dummyPixels],
              [1, 3, 224, 224],
            );
            final dummyOutputs = clipVision!.run(OrtRunOptions(), {
              'pixel_values': dummyInput,
            });
            if (dummyOutputs.length > 1) {
              _clipVisionOutputIdx = 1;
            }
          } catch (_) {}

          replyPort.send([
            2,
            [clipDim, gpuInitError],
          ]);
          break;

        case 1:
          if (clapAudio == null) {
            replyPort.send([1, 'CLAP audio not available on this tier']);
            break;
          }
          final pcm = msg[2] as Float32List;
          var processed = pcm;
          if (pcm.length > MelFFI.clapMaxSamples) {
            processed = Float32List.sublistView(pcm, 0, MelFFI.clapMaxSamples);
          }
          final melData = mel!.computeClapMel(processed);
          final input = OrtValueTensor.createTensorWithDataList(
            [melData],
            [1, 1, MelFFI.clapNFrames, MelFFI.clapNMels],
          );
          final outputs = clapAudio!.run(OrtRunOptions(), {
            'input_features': input,
          });
          replyPort.send([
            0,
            _extractFloat32List(outputs[0] as OrtValueTensor),
          ]);
          break;

        case 2:
          final floatData = msg[2] as Float32List;
          final input = OrtValueTensor.createTensorWithDataList(
            [floatData],
            [1, 3, 224, 224],
          );
          final outputs = clipVision!.run(OrtRunOptions(), {
            'pixel_values': input,
          });
          replyPort.send([
            0,
            _extractFloat32List(
              outputs[_clipVisionOutputIdx] as OrtValueTensor,
            ),
          ]);
          break;

        case 3:
          final tokenIds = msg[2] as Int64List;
          final input = OrtValueTensor.createTensorWithDataList(
            [tokenIds],
            [1, tokenIds.length],
          );
          final outputs = clipText!.run(OrtRunOptions(), {'input_ids': input});
          replyPort.send([
            0,
            _extractFloat32List(outputs[_clipTextOutputIdx] as OrtValueTensor),
          ]);
          break;

        case 4:
          if (clapText == null) {
            replyPort.send([1, 'CLAP text not available on this tier']);
            break;
          }
          final tokenIds = msg[2] as Int64List;
          final input = OrtValueTensor.createTensorWithDataList(
            [tokenIds],
            [1, tokenIds.length],
          );
          final outputs = clapText!.run(OrtRunOptions(), {'input_ids': input});
          replyPort.send([
            0,
            _extractFloat32List(outputs[0] as OrtValueTensor),
          ]);
          break;

        case 5:
          replyPort.send([3, clipDim]);
          break;

        case 6:
          clapAudio?.release();
          clapText?.release();
          clipVision?.release();
          clipText?.release();
          mel?.dispose();
          clapAudio = null;
          clapText = null;
          clipVision = null;
          clipText = null;
          mel = null;
          break;
      }
    } catch (e) {
      replyPort.send([1, '$e']);
    }
  });
}

Float32List _extractFloat32List(OrtValueTensor tensor) {
  final v = tensor.value;
  if (v is Float32List) return v;
  final flat = <double>[];
  _flatten(v, flat);
  if (flat.isNotEmpty) return Float32List.fromList(flat);
  throw Exception('Unexpected tensor value type: ${v.runtimeType}');
}

void _flatten(dynamic v, List<double> out) {
  if (v is Float64List || v is Float32List) {
    for (final e in v) out.add(e);
  } else if (v is List<num>) {
    for (final e in v) out.add(e.toDouble());
  } else if (v is List<double>) {
    for (final e in v) out.add(e);
  } else if (v is List) {
    for (final e in v) _flatten(e, out);
  } else if (v is double) {
    out.add(v);
  } else if (v is num) {
    out.add(v.toDouble());
  }
}
