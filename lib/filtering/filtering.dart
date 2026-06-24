import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:memefolder/backend/embedding_service.dart';
import 'package:memefolder/backend/tokenizer.dart';
import 'package:memefolder/widgets/smart_context_bar.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

sealed class FilterExpr {}

class TagFilter extends FilterExpr {
  final String column;
  final String op;
  final String value;
  TagFilter(this.column, this.op, this.value);

  @override
  String toString() => '$column $op $value';
}

class AndFilter extends FilterExpr {
  final FilterExpr left;
  final FilterExpr right;
  AndFilter(this.left, this.right);

  @override
  String toString() => '($left AND $right)';
}

class OrFilter extends FilterExpr {
  final FilterExpr left;
  final FilterExpr right;
  OrFilter(this.left, this.right);

  @override
  String toString() => '($left OR $right)';
}

class NotFilter extends FilterExpr {
  final FilterExpr child;
  NotFilter(this.child);

  @override
  String toString() => 'NOT ($child)';
}

const _typeAliasMap = <String, String>{
  'image': 'image',
  'picture': 'image',
  'photo': 'image',
  'video': 'video',
  'audio': 'audio',
  'sound': 'audio',
  'text': 'text',
};

TagFilter? _tokenToFilter(Token token) {
  final raw = token.value;

  if (token.type is TokTagFiletype) {
    final tag = raw.substring(1).toLowerCase();
    if (tag == 'gif') return TagFilter('ext', '=', 'gif');
    final mediaType = _typeAliasMap[tag];
    if (mediaType != null) return TagFilter('media_type', '=', mediaType);
    return null;
  }

  if (token.type is TokTagFileext) {
    final ext = raw.substring(2).toLowerCase();
    if (ext.isEmpty) return null;
    return TagFilter('ext', '=', ext);
  }

  if (token.type is TokTagFolder) {
    final path = raw.substring(8);
    if (path.isEmpty) return null;
    return TagFilter('rel_path', 'LIKE', '$path/%');
  }

  return null;
}

class _Parser {
  final List<Token> _toks;
  int _pos = 0;

  _Parser(this._toks);

  FilterExpr? parse() {
    if (_toks.isEmpty) return null;
    return _parseOr();
  }

  FilterExpr? _parseOr() {
    var left = _parseAnd();
    while (_pos < _toks.length && _toks[_pos].type is TokOpOr) {
      _pos++;
      final right = _parseAnd();
      if (right != null) {
        left = left != null ? OrFilter(left, right) : right;
      }
    }
    return left;
  }

  FilterExpr? _parseAnd() {
    var left = _parseUnary();
    while (_pos < _toks.length && _toks[_pos].type is TokOpAnd) {
      _pos++;
      final right = _parseUnary();
      if (right != null) {
        left = left != null ? AndFilter(left, right) : right;
      }
    }
    return left;
  }

  FilterExpr? _parseUnary() {
    if (_pos < _toks.length && _toks[_pos].type is TokOpNot) {
      _pos++;
      final child = _parseUnary();
      return child != null ? NotFilter(child) : null;
    }
    return _parsePrimary();
  }

  FilterExpr? _parsePrimary() {
    if (_pos >= _toks.length) return null;

    final tok = _toks[_pos];

    if (tok.type is TokOpBracket && tok.value == '(') {
      _pos++;
      final expr = _parseOr();
      if (_pos < _toks.length &&
          _toks[_pos].type is TokOpBracket &&
          _toks[_pos].value == ')') {
        _pos++;
      }
      return expr;
    }

    if (tok.type is TokTagFiletype ||
        tok.type is TokTagFileext ||
        tok.type is TokTagFolder ||
        tok.type is TokTagLogical) {
      _pos++;
      return _tokenToFilter(tok);
    }

    _pos++;
    return _parsePrimary();
  }
}

FilterExpr? parseFilterExpression(String query) {
  final tokens = tokenize(query);

  final toks = tokens.where((t) {
    final ty = t.type;
    return ty is TokTagFiletype ||
        ty is TokTagFileext ||
        ty is TokTagFolder ||
        ty is TokTagLogical ||
        ty is TokOpAnd ||
        ty is TokOpOr ||
        ty is TokOpNot ||
        ty is TokOpBracket;
  }).toList();

  return _Parser(toks).parse();
}

(String where, List<Object> args) _generateWhere(FilterExpr expr) {
  switch (expr) {
    case TagFilter(:final column, :final op, :final value):
      return ('$column $op ?', [value]);
    case AndFilter(:final left, :final right):
      final (lw, la) = _generateWhere(left);
      final (rw, ra) = _generateWhere(right);
      return ('($lw) AND ($rw)', [...la, ...ra]);
    case OrFilter(:final left, :final right):
      final (lw, la) = _generateWhere(left);
      final (rw, ra) = _generateWhere(right);
      return ('($lw) OR ($rw)', [...la, ...ra]);
    case NotFilter(:final child):
      final (cw, ca) = _generateWhere(child);
      return ('NOT ($cw)', ca);
  }
}

Future<Set<String>> executeFilter(String rootPath, FilterExpr expr) async {
  final dbPath = p.join(rootPath, '.memefolder.db');
  if (!File(dbPath).existsSync()) return {};

  try {
    final db = await openDatabase(dbPath, readOnly: true);
    final (where, args) = _generateWhere(expr);
    final rows = await db.rawQuery(
      'SELECT rel_path FROM files WHERE $where AND media_type IN (\'image\',\'video\',\'audio\')',
      args,
    );
    await db.close();
    return rows.map((r) => p.join(rootPath, r['rel_path'] as String)).toSet();
  } catch (_) {
    return {};
  }
}

class FilterService extends ChangeNotifier {
  static final instance = FilterService._();
  FilterService._();

  String _query = '';
  FilterExpr? _expression;
  String _semanticText = '';
  Map<String, double> _scores = {};
  Map<String, double?> _clipScores = {};
  Map<String, double?> _clapScores = {};
  double? _minScore;
  double? _maxScore;
  bool _clipMode = true;
  bool _clapMode = false;

  String get query => _query;
  FilterExpr? get expression => _expression;
  bool get hasTags => _expression != null;
  bool get isActive => _query.trim().isNotEmpty;
  bool get hasSemantic => _semanticText.isNotEmpty;
  Map<String, double> get scores => _scores;
  Map<String, double?> get clipScores => _clipScores;
  Map<String, double?> get clapScores => _clapScores;
  bool get clipMode => _clipMode;
  bool get clapMode => _clapMode;

  void setQuery(String query) {
    if (_query == query) return;
    _query = query;
    _expression = query.trim().isEmpty ? null : parseFilterExpression(query);
    _extractSemanticText();
    _extractScoreConstraints();
    notifyListeners();
  }

  void clear() {
    setQuery('');
    _scores = {};
    _clipScores = {};
    _clapScores = {};
  }

  /// Parse @score>N or @score<N or @score=N from query
  void _extractScoreConstraints() {
    _minScore = null;
    _maxScore = null;
    final scoreMatch = RegExp(r'@score([<>=]=?)(\d+(?:\.\d+)?)').firstMatch(_query);
    if (scoreMatch == null) return;
    final op = scoreMatch.group(1)!;
    final val = double.tryParse(scoreMatch.group(2)!);
    if (val == null) return;
    if (op == '>' || op == '>=') _minScore = val;
    if (op == '<' || op == '<=') _maxScore = val;
    if (op == '=') { _minScore = val; _maxScore = val; }
  }

  /// Extract plain text (non-tag) tokens for semantic search.
  /// Also parses @audiocontent / @imagecontent mode toggles.
  void _extractSemanticText() {
    _clipMode = true;
    _clapMode = false;
    final q = _query.toLowerCase();
    if (q.contains('@audiocontent')) _clapMode = true;
    if (q.contains('@imagecontent')) _clipMode = true;
    if (!_clipMode && !_clapMode) _clipMode = true; // fallback

    final tokens = tokenize(_query);
    final parts = <String>[];
    for (final t in tokens) {
      if (t.type is TokText) {
        final trimmed = t.value.trim();
        if (trimmed.isNotEmpty) parts.add(trimmed);
      }
    }
    _semanticText = parts.join(' ').trim();
  }

  Future<List<String>> execute(String rootPath) async {
    Set<String> tagPaths = {};
    List<String> semanticPaths = [];

    if (_expression != null) {
      tagPaths = await executeFilter(rootPath, _expression!);
    }

    if (_semanticText.isNotEmpty && EmbeddingService.instance.isInitialized) {
      semanticPaths = await _executeSemantic(rootPath);
    }

    // Apply @score> / @score< constraints
    if (_minScore != null || _maxScore != null) {
      _scores.removeWhere((_, score) {
        if (_minScore != null && score < _minScore!) return true;
        if (_maxScore != null && score > _maxScore!) return true;
        return false;
      });
      final allowed = _scores.keys.toSet();
      semanticPaths = semanticPaths.where((p) => allowed.contains(p)).toList();
      tagPaths = tagPaths.where((p) => allowed.contains(p)).toSet();
    }

    // Intersect: if both tag and semantic, return intersection
    if (_expression != null && _semanticText.isNotEmpty) {
      final semanticSet = semanticPaths.toSet();
      _scores.removeWhere((k, _) => !semanticSet.contains(k));
      return tagPaths.where((p) => semanticSet.contains(p)).toList();
    }

    if (_semanticText.isNotEmpty) {
      return semanticPaths;
    }

    return tagPaths.toList();
  }

  Future<List<String>> _executeSemantic(String rootPath) async {
    _scores = {};
    _clipScores = {};
    _clapScores = {};

    final svc = EmbeddingService.instance;
    Float32List? queryClip;
    if (_clipMode) {
      final clipTok = HuggingFaceTokenizer.fromFile(
        '${svc.modelsPath}/clip/tokenizer.json',
      );
      final clipIds = clipTok.encodeClip(_semanticText);
      queryClip = await svc.embedClipText(clipIds);
    }
    Float32List? queryClap;
    if (_clapMode) {
      final clapTok = HuggingFaceTokenizer.fromFile(
        '${svc.modelsPath}/clap/tokenizer.json',
      );
      final clapIds = clapTok.encodeClap(_semanticText);
      queryClap = await svc.embedClapText(clapIds);
    }

    // Scan DB for files with embeddings
    final dbPath = p.join(rootPath, '.memefolder.db');
    if (!File(dbPath).existsSync()) return [];

    final db = await openDatabase(dbPath, readOnly: true);

    try {
      final mediaWhere = <String>[];
      if (_clipMode) { mediaWhere.addAll(['image', 'video']); }
      if (_clapMode) { mediaWhere.addAll(['audio', 'video']); }
      final mediaList = mediaWhere.toSet().toList();
      final placeholders = mediaList.map((_) => '?').join(',');
      final rows = await db.rawQuery('''
        SELECT id, rel_path, clip_emb, clap_emb, metadata_emb, status
        FROM files
        WHERE media_type IN ($placeholders)
      ''', mediaList);

      final cd = EmbeddingService.instance.clipDim;
      final cd4 = cd * 4;
      final ad = EmbeddingService.instance.clapDim;
      final ad4 = ad * 4;

      for (final row in rows) {
        final relPath = row['rel_path'] as String;
        final absPath = p.join(rootPath, relPath);
        final status = row['status'] as String? ?? '';

        double? clipScore;
        double? clapScore;
        double bestScore = 0.0;

        if (queryClip != null && row['clip_emb'] is Uint8List) {
          final blob = row['clip_emb'] as Uint8List;
          if (blob.length == cd4) {
            final fileEmb = Float32List.view(blob.buffer, 0, cd);
            clipScore = _cosineSimilarity(queryClip!, fileEmb);
            if (clipScore! > bestScore) bestScore = clipScore!;
          }
        }

        if (clipScore == null && queryClip != null && row['metadata_emb'] is Uint8List) {
          final blob = row['metadata_emb'] as Uint8List;
          if (blob.length == cd4) {
            final fileEmb = Float32List.view(blob.buffer, 0, cd);
            clipScore = _cosineSimilarity(queryClip!, fileEmb);
            if (clipScore! > bestScore) bestScore = clipScore!;
          }
        }

        if (queryClap != null && row['clap_emb'] is Uint8List) {
          final blob = row['clap_emb'] as Uint8List;
          if (blob.length == ad4) {
            final fileEmb = Float32List.view(blob.buffer, 0, ad);
            clapScore = _cosineSimilarity(queryClap!, fileEmb);
            if (clapScore! > bestScore) bestScore = clapScore!;
          }
        }

        _clipScores[absPath] = clipScore;
        _clapScores[absPath] = clapScore;
        if (status == 'embed_failed') {
          bestScore = -1;
        }
        _scores[absPath] = bestScore;
      }
    } finally {
      await db.close();
    }

    if (_scores.isEmpty) return [];

    void normalizeMap(Map<String, double?> map) {
      final keys = map.keys.where((k) => map[k] != null && _scores[k]! >= 0).toList();
      if (keys.length > 1) {
        double minV = map[keys[0]]!, maxV = map[keys[0]]!;
        for (final k in keys) {
          final v = map[k]!;
          if (v < minV) minV = v;
          if (v > maxV) maxV = v;
        }
        final range = maxV - minV;
        for (final k in keys) {
          map[k] = range > 0 ? ((map[k]! - minV) / range) * 100.0 : 100.0;
        }
      } else if (keys.length == 1) {
        map[keys[0]] = 100.0;
      }
    }

    // Normalize combined, clip, and clap scores independently
    normalizeMap(_scores.cast<String, double?>());
    normalizeMap(_clipScores);
    normalizeMap(_clapScores);

    // Sort descending by best score, put failed at end
    final sorted = _scores.entries.toList()
      ..sort((a, b) {
        if (a.value < 0 && b.value < 0) return 0;
        if (a.value < 0) return 1;
        if (b.value < 0) return -1;
        return b.value.compareTo(a.value);
      });

    debugPrint('[filter] semantic: ${sorted.length} results');
    return sorted.map((e) => e.key).toList();
  }

  static double _cosineSimilarity(Float32List a, Float32List b) {
    double dot = 0, na = 0, nb = 0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    if (na == 0 || nb == 0) return 0;
    return dot / (sqrt(na) * sqrt(nb));
  }
}
