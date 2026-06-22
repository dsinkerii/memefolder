import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class CosineResult {
  final int fileId;
  final String filePath;
  final double score;
  final String modality;

  const CosineResult({
    required this.fileId,
    required this.filePath,
    required this.score,
    required this.modality,
  });
}

/// In-memory cosine similarity search against stored embeddings.
///
/// Embeddings are L2-normalized, so cosine(a,b) = dot(a,b).
Future<List<CosineResult>> cosineSearch(
  String rootPath,
  Float32List queryEmbedding, {
  int topK = 50,
  double minScore = 0.65,
  String? filterMediaType,
  Set<String>? restrictFileIds,
  double scoreScale = 1.0,
  double scoreBias = 0.0,
}) async {
  final dbPath = p.join(rootPath, '.memefolder.db');
  if (!File(dbPath).existsSync()) return [];

  try {
    final db = await openDatabase(dbPath, singleInstance: false);

    // fetch all stored embeddings
    final rows = await db.rawQuery('''
      SELECT fe.file_id, fe.modality, fe.dims, fe.embedding,
             f.rel_path, f.media_type
      FROM file_embeddings fe
      JOIN files f ON f.id = fe.file_id
    ''');

    await db.close();

    debugPrint('[cosine] loaded ${rows.length} embeddings from DB');
    debugPrint(
      '[cosine] query dims=${queryEmbedding.length}, minScore=$minScore, scale=$scoreScale, bias=$scoreBias',
    );

    final results = <CosineResult>[];

    for (final row in rows) {
      // optional media type filter
      if (filterMediaType != null && row['media_type'] != filterMediaType) {
        continue;
      }

      // optional file restriction (from tag filter)
      final relPath = row['rel_path'] as String;

      // skip DB internal files that got indexed by mistake
      if (p.basename(relPath).startsWith('.memefolder.db')) continue;

      final fileIdInt = row['file_id'] as int;
      if (restrictFileIds != null &&
          !restrictFileIds.contains(fileIdInt.toString())) {
        continue;
      }

      final blob = row['embedding'] as Uint8List;
      final dims = row['dims'] as int;

      // deserialize BLOB -> Float32List
      final byteData = ByteData.view(blob.buffer);
      final stored = Float32List(dims);
      for (var i = 0; i < dims; i++) {
        stored[i] = byteData.getFloat32(i * 4, Endian.little);
      }

      // cosine = dot product (both L2-normalized)
      var dot = 0.0;
      for (var i = 0; i < dims; i++) {
        dot += queryEmbedding[i] * stored[i];
      }

      // apply model-specific score calibration: kx + b
      final score = (dot * scoreScale + scoreBias).clamp(0.0, 1.0);

      if (score >= minScore) {
        results.add(
          CosineResult(
            fileId: fileIdInt,
            filePath: p.join(rootPath, relPath),
            score: score,
            modality: row['modality'] as String,
          ),
        );
      }
    }

    // sort by score descending
    results.sort((a, b) => b.score.compareTo(a.score));

    debugPrint('[cosine] ${results.length} results above minScore=$minScore');
    for (final r in results.take(3)) {
      debugPrint(
        '[cosine]   ${r.score.toStringAsFixed(4)} ${r.modality} ${p.basename(r.filePath)}',
      );
    }

    return results.take(topK).toList();
  } catch (e) {
    debugPrint('[cosine] ERROR: $e');
    return [];
  }
}
