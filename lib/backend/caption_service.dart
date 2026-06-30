import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'caption_isolate.dart';

class CaptionService {
  static final CaptionService instance = CaptionService._();

  CaptionService._();

  bool _initialized = false;
  bool get isInitialized => _initialized;

  Isolate? _isolate;
  SendPort? _isolateSendPort;

  String? _modelsPath;

  Future<SendPort> _spawnIsolate() async {
    final receivePort = ReceivePort();
    _isolate = await Isolate.spawn(captionIsolateMain, receivePort.sendPort);
    final sendPort = await receivePort.first as SendPort;
    _isolateSendPort = sendPort;
    return sendPort;
  }

  Future<T> _sendToIsolate<T>(List<dynamic> msg, {Duration? timeout}) async {
    if (_isolateSendPort == null) {
      throw StateError('Caption isolate not initialized');
    }
    final rp = ReceivePort();
    _isolateSendPort!.send([msg[0], rp.sendPort, ...msg.sublist(1)]);
    final result = timeout != null
        ? await rp.first.timeout(timeout, onTimeout: () {
            rp.close();
            throw TimeoutException('Caption isolate timed out after ${timeout.inSeconds}s');
          })
        : await rp.first;
    rp.close();
    final list = result as List;
    final code = list[0] as int;
    if (code == 1) throw Exception('${list[1]}');
    return list.length > 1 ? list[1] as T : (null as T);
  }

  Future<void> initialize({
    required String modelsPath,
    String? gpuProvider,
  }) async {
    if (_initialized) return;
    _modelsPath = modelsPath;
    debugPrint('[caption] models path: $_modelsPath');

    await _spawnIsolate();
    await _sendToIsolate<dynamic>([0, _modelsPath, gpuProvider]);
    _initialized = true;
  }

  Future<String> runOcr(Uint8List imageBytes) async {
    if (!_initialized) throw StateError('CaptionService not initialized');
    if (imageBytes.isEmpty) return '';

    // decode at full resolution
    final codec = await ui.instantiateImageCodec(imageBytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final origW = image.width;
    final origH = image.height;
    final bitmap = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    codec.dispose();
    if (bitmap == null) return '';
    final origPixels = bitmap.buffer.asUint8List();

    // resize for detection: long side to 960, round to 32
    const maxSide = 960;
    final maxDim = origW > origH ? origW : origH;
    final scale = maxDim > maxSide ? maxSide / maxDim : 1.0;
    var detW = ((origW * scale).ceil() + 31) ~/ 32 * 32;
    var detH = ((origH * scale).ceil() + 31) ~/ 32 * 32;
    if (detW < 32) detW = 32;
    if (detH < 32) detH = 32;

    final detCodec = await ui.instantiateImageCodec(
      imageBytes,
      targetWidth: detW,
      targetHeight: detH,
    );
    final detFrame = await detCodec.getNextFrame();
    final detBitmap = await detFrame.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    detCodec.dispose();
    if (detBitmap == null) return '';
    final detPixels = detBitmap.buffer.asUint8List();

    // normalize to nchw float
    final detFloat = Float32List(3 * detH * detW);
    for (int y = 0; y < detH; y++) {
      for (int x = 0; x < detW; x++) {
        final srcIdx = (y * detW + x) * 4;
        for (int c = 0; c < 3; c++) {
          detFloat[c * detH * detW + y * detW + x] =
              (detPixels[srcIdx + c] / 255.0 - 0.5) / 0.5;
        }
      }
    }

    // run detection
    final prob = await _sendToIsolate<Float32List>([4, detFloat, detH, detW]);
    final boxes = extractOcrBoxes(prob, detH, detW, origW, origH, scale);
    if (boxes.isEmpty) return '';

    // crop and recognize each region
    final results = <String>[];
    for (final box in boxes) {
      final cropX1 = box[0].clamp(0, origW - 1);
      final cropY1 = box[1].clamp(0, origH - 1);
      final cropX2 = box[2].clamp(0, origW);
      final cropY2 = box[3].clamp(0, origH);
      final cropW = cropX2 - cropX1;
      final cropH = cropY2 - cropY1;
      if (cropW < 5 || cropH < 5) continue;

      // resize to h=48, maintaining aspect ratio
      final targetH = 48;
      final targetW = ((cropW * targetH) / cropH).ceil().clamp(1, 2048);

      // bilinear resize from original rgba
      final recFloat = Float32List(3 * targetH * targetW);
      for (int ty = 0; ty < targetH; ty++) {
        for (int tx = 0; tx < targetW; tx++) {
          final sx = cropX1 + (tx * cropW) / targetW;
          final sy = cropY1 + (ty * cropH) / targetH;
          final x0 = sx.floor().clamp(0, origW - 1);
          final y0 = sy.floor().clamp(0, origH - 1);
          final x1 = (x0 + 1).clamp(0, origW - 1);
          final y1 = (y0 + 1).clamp(0, origH - 1);
          final fx = sx - x0;
          final fy = sy - y0;

          for (int c = 0; c < 3; c++) {
            final v00 = origPixels[(y0 * origW + x0) * 4 + c].toDouble();
            final v10 = origPixels[(y0 * origW + x1) * 4 + c].toDouble();
            final v01 = origPixels[(y1 * origW + x0) * 4 + c].toDouble();
            final v11 = origPixels[(y1 * origW + x1) * 4 + c].toDouble();
            final val = v00 * (1 - fx) * (1 - fy) +
                v10 * fx * (1 - fy) +
                v01 * (1 - fx) * fy +
                v11 * fx * fy;
            recFloat[c * targetH * targetW + ty * targetW + tx] =
                (val / 255.0 - 0.5) / 0.5;
          }
        }
      }

      final text = await _sendToIsolate<String>([1, recFloat, targetW]);
      if (text.isNotEmpty) results.add(text);
    }

    return results.join('\n');
  }

  @visibleForTesting
  static List<List<int>> extractOcrBoxes(
    Float32List prob,
    int h,
    int w,
    int origW,
    int origH,
    double scale,
  ) {
    final threshold = 0.3;
    final boxes = <List<int>>[];
    var regions = <_OcrRegion>[];

    for (int y = 0; y < h; y++) {
      var runStart = -1;
      for (int x = 0; x <= w; x++) {
        final val = x < w ? prob[y * w + x] : 0;
        if (val > threshold) {
          if (runStart < 0) runStart = x;
        } else {
          if (runStart >= 0) {
            final run = _OcrRun(runStart, x);
            var merged = false;
            for (final r in regions) {
              if (r.y2 >= y - 2 && r.runs.any((r2) =>
                  r2.start < run.end + 2 && r2.end > run.start - 2)) {
                r.addRun(run, y);
                merged = true;
                break;
              }
            }
            if (!merged) {
              regions.add(_OcrRegion()..addRun(run, y));
            }
            runStart = -1;
          }
        }
      }
    }

    for (final r in regions) {
      final bw = r.x2 - r.x1;
      final bh = r.y2 - r.y1;
      if (bw < 5 || bh < 5) continue;
      final pad = 5;
      final ox1 = ((r.x1 / scale) - pad).floor().clamp(0, origW - 1);
      final oy1 = ((r.y1 / scale) - pad).floor().clamp(0, origH - 1);
      final ox2 = ((r.x2 / scale) + pad).ceil().clamp(0, origW);
      final oy2 = ((r.y2 / scale) + pad).ceil().clamp(0, origH);
      if (ox2 - ox1 > 3 && oy2 - oy1 > 3) {
        boxes.add([ox1, oy1, ox2, oy2]);
      }
    }

    return boxes;
  }

  Future<String> runWhisper(Float32List pcm, {Duration timeout = const Duration(seconds: 30)}) async {
    if (!_initialized) throw StateError('CaptionService not initialized');
    return _sendToIsolate<String>([2, pcm], timeout: timeout);
  }

  Future<void> unload() async {
    if (!_initialized) return;
    debugPrint('[caption] unloading models');
    if (_isolateSendPort != null) {
      final rp = ReceivePort();
      _isolateSendPort!.send([3, rp.sendPort]);
      rp.close();
    }
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _isolateSendPort = null;
    _initialized = false;
  }
}

class _OcrRun {
  final int start;
  final int end;
  _OcrRun(this.start, this.end);
}

class _OcrRegion {
  int x1 = 99999, y1 = 99999, x2 = 0, y2 = 0;
  final runs = <_OcrRun>[];

  void addRun(_OcrRun run, int y) {
    runs.add(run);
    if (run.start < x1) x1 = run.start;
    if (run.end > x2) x2 = run.end;
    if (y < y1) y1 = y;
    if (y > y2) y2 = y;
  }
}
