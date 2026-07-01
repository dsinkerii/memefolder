import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
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
  int clipVisionOutputIdx = 0;
  int clipTextOutputIdx = 0;
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

          debugPrint('[embedding] ═══════════════════════════════════════');
          debugPrint('[embedding] INIT START  tier=$tier gpuProvider=$gpuProvider');
          debugPrint('[embedding] modelsPath=$modelsPath');

          debugPrint('[embedding] step 1/7: creating MelFFI...');
          mel = MelFFI();
          debugPrint('[embedding] step 1/7: MelFFI OK');

          debugPrint('[embedding] step 2/7: creating OrtSessionOptions...');
          final options = OrtSessionOptions();

          debugPrint('[embedding] step 2/7: listing available providers (before append):');
          final availableProviders = OrtEnv.instance.availableProviders();
          for (final prov in availableProviders) {
            debugPrint('[embedding]   available: $prov');
          }
          debugPrint('[embedding] total providers available: ${availableProviders.length}');

          debugPrint('[embedding] step 2/7: calling OrtEnv.init()...');
          OrtEnv.instance.init();
          debugPrint('[embedding] step 2/7: OrtEnv.init() OK');

          debugPrint('[embedding] step 2/7: manually appending safe providers...');
          String? activeProvider;
          final forceCPU = gpuProvider?.toUpperCase() == 'CPU';
          final wantCuda = gpuProvider == null || gpuProvider.toUpperCase() == 'CUDA';
          final wantTensorrt = gpuProvider == null || gpuProvider.toUpperCase() == 'TENSORRT';
          final wantXnnpack = gpuProvider == null || gpuProvider.toUpperCase() == 'XNNPACK';
          final wantDnnl = gpuProvider == null || gpuProvider.toUpperCase() == 'DNNL';
          if (!forceCPU) {
            try {
              if (wantCuda && availableProviders.contains(OrtProvider.cuda)) {
                debugPrint('[embedding]   appending CUDA...');
                options.appendCudaProvider(CUDAFlags.useNone);
                activeProvider ??= 'CUDA';
                debugPrint('[embedding]   CUDA appended OK');
              }
            } catch (e) {
              debugPrint('[embedding]   CUDA append failed: $e');
            }
            try {
              if (wantTensorrt) {
                if (availableProviders.contains(OrtProvider.tensorrt)) {
                  debugPrint('[embedding]   appending TensorRT...');
                  options.appendTensorRTProvider();
                  activeProvider ??= 'TensorRT';
                  debugPrint('[embedding]   TensorRT appended OK');
                }
              }
            } catch (e) {
              debugPrint('[embedding]   TensorRT append failed: $e');
            }
            try {
              if (wantXnnpack && availableProviders.contains(OrtProvider.xnnpack)) {
                debugPrint('[embedding]   appending XNNPACK...');
                options.appendXnnpackProvider();
                activeProvider ??= 'XNNPACK';
                debugPrint('[embedding]   XNNPACK appended OK');
              }
            } catch (e) {
              debugPrint('[embedding]   XNNPACK append failed: $e');
            }
            try {
              if (wantDnnl && availableProviders.contains(OrtProvider.dnnl)) {
                debugPrint('[embedding]   appending DNNL...');
                options.appendDNNLProvider(DNNLFlags.useArena);
                activeProvider ??= 'DNNL';
                debugPrint('[embedding]   DNNL appended OK');
              }
            } catch (e) {
              debugPrint('[embedding]   DNNL append failed: $e');
            }
          }
          try {
            debugPrint('[embedding]   appending CPU...');
            options.appendCPUProvider(CPUFlags.useArena);
            activeProvider ??= 'CPU';
            debugPrint('[embedding]   CPU appended OK');
          } catch (e) {
            debugPrint('[embedding]   CPU append failed: $e');
          }
          debugPrint('[embedding] step 2/7: provider setup done  activeProvider=$activeProvider');

          options.setIntraOpNumThreads(4);
          options.setSessionGraphOptimizationLevel(
            GraphOptimizationLevel.ortEnableAll,
          );
          debugPrint('[embedding] step 2/7: OrtSessionOptions configured');

          // always load SigLIP vision + text
          final visionPath = p.join(modelsPath, 'clip', 'vision_model.onnx');
          final textPath = p.join(modelsPath, 'clip', 'text_model.onnx');
          debugPrint('[embedding] step 3/7: loading vision_model.onnx from $visionPath');
          debugPrint('[embedding]   file exists: ${File(visionPath).existsSync()}');
          debugPrint('[embedding]   file size: ${File(visionPath).lengthSync()} bytes');
          clipVision = OrtSession.fromBuffer(
            File(visionPath).readAsBytesSync(),
            options,
          );
          debugPrint('[embedding] step 3/7: vision_model loaded OK');

          debugPrint('[embedding] step 4/7: loading text_model.onnx from $textPath');
          debugPrint('[embedding]   file exists: ${File(textPath).existsSync()}');
          debugPrint('[embedding]   file size: ${File(textPath).lengthSync()} bytes');
          clipText = OrtSession.fromBuffer(
            File(textPath).readAsBytesSync(),
            options,
          );
          debugPrint('[embedding] step 4/7: text_model loaded OK');

          // CLAP audio + text only for Full tier
          if (isFull) {
            debugPrint('[embedding] step 5/7: loading CLAP models (full tier)...');
            // CLAP FP16 requires disabled graph optimizations (ORT 1.26.0
            // simplifiedLayerNormFusion bug inserts cast node with missing ref)
            final clapOpts = OrtSessionOptions();
            if (!forceCPU) {
              try {
                if (wantCuda && availableProviders.contains(OrtProvider.cuda)) {
                  clapOpts.appendCudaProvider(CUDAFlags.useNone);
                }
              } catch (_) {}
              try {
                if (wantTensorrt && availableProviders.contains(OrtProvider.tensorrt)) {
                  clapOpts.appendTensorRTProvider();
                }
              } catch (_) {}
              try {
                if (wantXnnpack && availableProviders.contains(OrtProvider.xnnpack)) {
                  clapOpts.appendXnnpackProvider();
                }
              } catch (_) {}
              try {
                if (wantDnnl && availableProviders.contains(OrtProvider.dnnl)) {
                  clapOpts.appendDNNLProvider(DNNLFlags.useArena);
                }
              } catch (_) {}
            }
            try {
              clapOpts.appendCPUProvider(CPUFlags.useArena);
            } catch (_) {}
            clapOpts.setIntraOpNumThreads(4);
            clapOpts.setSessionGraphOptimizationLevel(
              GraphOptimizationLevel.ortDisableAll,
            );
            final clapAudioPath = p.join(modelsPath, 'clap', 'audio_model_fp16.onnx');
            final clapTextPath = p.join(modelsPath, 'clap', 'text_model_quantized.onnx');
            debugPrint('[embedding]   audio_model_fp16.onnx exists: ${File(clapAudioPath).existsSync()} size: ${File(clapAudioPath).existsSync() ? File(clapAudioPath).lengthSync() : 0}');
            debugPrint('[embedding]   text_model_quantized.onnx exists: ${File(clapTextPath).existsSync()} size: ${File(clapTextPath).existsSync() ? File(clapTextPath).lengthSync() : 0}');
            debugPrint('[embedding] step 5a: loading clap audio_model_fp16.onnx...');
            clapAudio = OrtSession.fromBuffer(
              File(clapAudioPath).readAsBytesSync(),
              clapOpts,
            );
            debugPrint('[embedding] step 5a: clap audio loaded OK');
            debugPrint('[embedding] step 5b: loading clap text_model_quantized.onnx...');
            clapText = OrtSession.fromBuffer(
              File(clapTextPath).readAsBytesSync(),
              options,
            );
            debugPrint('[embedding] step 5b: clap text loaded OK');
          } else {
            debugPrint('[embedding] step 5/7: skipping CLAP (tier=$tier)');
          }

          debugPrint('[embedding] step 6/7: running dummy text inference to detect clipDim...');
          try {
            final dummyIds = Int64List.fromList([0]);
            final dummyInput = OrtValueTensor.createTensorWithDataList(
              [dummyIds],
              [1, 1],
            );
            final dummyRunOpts = OrtRunOptions();
            final dummyOutputs = clipText!.run(dummyRunOpts, {
              'input_ids': dummyInput,
            });
            clipDim = _extractFloat32List(
              dummyOutputs[0] as OrtValueTensor,
            ).length;

            if (dummyOutputs.length > 1) {
              clipTextOutputIdx = 1;
            }
            for (final o in dummyOutputs) {
              try { (o as OrtValueTensor).release(); } catch (_) {}
            }
            dummyInput.release();
            dummyRunOpts.release();
            debugPrint('[embedding] step 6/7: text inference OK clipDim=$clipDim');
          } catch (e) {
            debugPrint('[embedding] step 6/7: text inference FAILED: $e');
          }

          debugPrint('[embedding] step 7/7: running dummy vision inference...');
          try {
            final dummyPixels = Float32List(3 * 224 * 224);
            final dummyInput = OrtValueTensor.createTensorWithDataList(
              [dummyPixels],
              [1, 3, 224, 224],
            );
            final dummyRunOpts = OrtRunOptions();
            final dummyOutputs = clipVision!.run(dummyRunOpts, {
              'pixel_values': dummyInput,
            });
            if (dummyOutputs.length > 1) {
              clipVisionOutputIdx = 1;
            }
            for (final o in dummyOutputs) {
              try { (o as OrtValueTensor).release(); } catch (_) {}
            }
            dummyInput.release();
            dummyRunOpts.release();
            debugPrint('[embedding] step 7/7: vision inference OK');
          } catch (e) {
            debugPrint('[embedding] step 7/7: vision inference FAILED: $e');
          }

          debugPrint('[embedding] ═══════════════════════════════════════');
          debugPrint('[embedding] INIT DONE  clipDim=$clipDim activeProvider=$activeProvider gpuInitError=$gpuInitError');
          replyPort.send([
            2,
            [clipDim, gpuInitError, activeProvider],
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
          final runOpts = OrtRunOptions();
          final outputs = clapAudio!.run(runOpts, {
            'input_features': input,
          });
          final result = _extractFloat32List(outputs[0] as OrtValueTensor);
          for (final o in outputs) {
            try { (o as OrtValueTensor).release(); } catch (_) {}
          }
          input.release();
          runOpts.release();
          replyPort.send([0, result]);
          break;

        case 2:
          final floatData = msg[2] as Float32List;
          final input = OrtValueTensor.createTensorWithDataList(
            [floatData],
            [1, 3, 224, 224],
          );
          final runOpts = OrtRunOptions();
          final outputs = clipVision!.run(runOpts, {
            'pixel_values': input,
          });
          final result = _extractFloat32List(outputs[clipVisionOutputIdx] as OrtValueTensor);
          for (final o in outputs) {
            try { (o as OrtValueTensor).release(); } catch (_) {}
          }
          input.release();
          runOpts.release();
          replyPort.send([0, result]);
          break;

        case 3:
          final tokenIds = msg[2] as Int64List;
          final input = OrtValueTensor.createTensorWithDataList(
            [tokenIds],
            [1, tokenIds.length],
          );
          final runOpts = OrtRunOptions();
          final outputs = clipText!.run(runOpts, {'input_ids': input});
          final result = _extractFloat32List(outputs[clipTextOutputIdx] as OrtValueTensor);
          for (final o in outputs) {
            try { (o as OrtValueTensor).release(); } catch (_) {}
          }
          input.release();
          runOpts.release();
          replyPort.send([0, result]);
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
          final runOpts = OrtRunOptions();
          final outputs = clapText!.run(runOpts, {'input_ids': input});
          final result = _extractFloat32List(outputs[0] as OrtValueTensor);
          for (final o in outputs) {
            try { (o as OrtValueTensor).release(); } catch (_) {}
          }
          input.release();
          runOpts.release();
          replyPort.send([0, result]);
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
