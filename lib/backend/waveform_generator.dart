import 'dart:io';
import 'dart:math';

import 'package:memefolder/utils/binary_paths.dart';

class WaveformGenerator {
  static const int segments = 20;

  static Future<List<double>> generate(String audioPath) async {
    if (audioPath.isEmpty) return List.filled(segments, 0.5);

    try {
      final result = await Process.run(ffprobePath, [
        '-v', 'error',
        '-f', 'lavfi',
        '-i', 'amovie=$audioPath,astats=metadata=1:reset=1',
        '-show_entries', 'frame_tags=lavfi.astats.Overall.Peak_level',
        '-of', 'csv=p=0',
      ]);

      if (result.exitCode != 0) {
        return List.filled(segments, 0.5);
      }

      final output = result.stdout as String;
      if (output.trim().isEmpty) return List.filled(segments, 0.5);

      final peaks = output
          .split('\n')
          .map((l) => double.tryParse(l.trim()))
          .whereType<double>()
          .toList();

      if (peaks.isEmpty) return List.filled(segments, 0.5);

      final chunkSize = max(1, (peaks.length / segments).ceil());

      return List.generate(segments, (i) {
        final start = i * chunkSize;
        final end = min(start + chunkSize, peaks.length);
        if (start >= peaks.length) return 0.05;

        var maxDb = -100.0;
        for (var j = start; j < end; j++) {
          if (peaks[j] > maxDb) maxDb = peaks[j];
        }

        final linear = maxDb > -100 ? pow(10, maxDb / 20).toDouble() : 0.0;
        return linear.clamp(0.05, 1.0);
      });
    } catch (_) {
      return List.filled(segments, 0.5);
    }
  }
}
