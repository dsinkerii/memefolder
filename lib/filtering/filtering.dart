import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:memefolder/backend/embedding_service.dart';
import 'package:memefolder/backend/tokenizer.dart';
import 'package:memefolder/widgets/bubble_snackbar.dart';
import 'package:memefolder/widgets/smart_context_bar.dart';
import 'package:path/path.dart' as p;
import 'package:memefolder/prefs.dart';
import 'package:sqflite/sqflite.dart';

double _cosineSimilarity(Float32List a, Float32List b) {
  double dot = 0, na = 0, nb = 0;
  for (int i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  if (na == 0 || nb == 0) return 0;
  return dot / (sqrt(na) * sqrt(nb));
}

enum SearchSpace { ultimate, siglip, ocr, transcript, clap }

extension SearchSpaceExt on SearchSpace {
  String get label => switch (this) {
    SearchSpace.ultimate => '',
    SearchSpace.siglip => 'img',
    SearchSpace.ocr => 'txt',
    SearchSpace.transcript => 'cc',
    SearchSpace.clap => 'aud',
  };
}

List<Map<String, Object?>> _computeScoresInIsolate(
  Map<String, Object?> params,
) {
  final filePaths = params['filePaths'] as List<String>;
  final statuses = params['statuses'] as List<String>;
  final isClapMode = params['isClapMode'] as bool;
  final rawTexts = params['rawTexts'] as List<String?>?;
  final queryWords = params['queryWords'] as List<String>?;

  // Fuzzy text matching mode: used for @ocr / @transcript search
  if (rawTexts != null && queryWords != null && queryWords.isNotEmpty) {
    return _computeFuzzyScores(filePaths, statuses, rawTexts, queryWords);
  }

  // Cosine similarity mode: used for all other semantic search
  final queryEmb = params['queryEmb'] as Float32List?;
  final queryClap = params['queryClap'] as Float32List?;
  final clipDim = params['clipDim'] as int;
  final clapDim = params['clapDim'] as int;
  final cd4 = clipDim * 4;
  final ad4 = clapDim * 4;
  final searchBlobs = params['searchBlobs'] as List<Uint8List?>;
  final clapBlobs = params['clapBlobs'] as List<Uint8List?>;

  final results = <Map<String, Object?>>[];
  for (int i = 0; i < filePaths.length; i++) {
    double? score;

    if (!isClapMode && queryEmb != null && searchBlobs[i] != null) {
      final blob = searchBlobs[i]!;
      if (blob.length == cd4) {
        final emb = Float32List.view(blob.buffer, 0, clipDim);
        score = _cosineSimilarity(queryEmb, emb);
      }
    }

    if (isClapMode && queryClap != null && clapBlobs[i] != null) {
      final blob = clapBlobs[i]!;
      if (blob.length == ad4) {
        final emb = Float32List.view(blob.buffer, 0, clapDim);
        score = _cosineSimilarity(queryClap, emb);
      }
    }

    if (statuses[i] == 'embed_failed') score = -1;

    results.add({'path': filePaths[i], 'score': score});
  }
  return results;
}

List<Map<String, Object?>> _computeFuzzyScores(
  List<String> filePaths,
  List<String> statuses,
  List<String?> rawTexts,
  List<String> queryWords,
) {
  // Rejoin query words — OCR text has no spaces, so word-level matching is
  // unreliable.  Use character-level scoring for continuous results.
  final query = queryWords.join(' ').toLowerCase();

  final results = <Map<String, Object?>>[];
  for (int i = 0; i < filePaths.length; i++) {
    final text = rawTexts[i]?.toLowerCase() ?? '';
    if (text.isEmpty || statuses[i] == 'embed_failed') {
      results.add({'path': filePaths[i], 'score': -1.0});
      continue;
    }

    // Take the best score across the full text and a sliding window.
    // Full-text LCS handles substring matches; the window handles
    // near-matches where the query is close to but not exactly in the text.
    var best = _lcsRatio(query, text);
    final qLen = query.length;
    final winSize = qLen + (qLen ~/ 2) + 2; // ~1.5x query length + tolerance
    if (text.length > winSize) {
      for (int start = 0; start <= text.length - qLen; start++) {
        final end = (start + winSize).clamp(0, text.length);
        final w = _lcsRatio(query, text.substring(start, end));
        if (w > best) best = w;
      }
    }
    results.add({'path': filePaths[i], 'score': best});
  }
  return results;
}

/// Longest Common Subsequence ratio: LCS(query, text) / len(query).
/// Returns value in [0, 1]. Handles insertions, deletions, and swaps.
double _lcsRatio(String query, String text) {
  if (query.isEmpty || text.isEmpty) return 0;
  final m = query.length, n = text.length;
  // Optimized: only keep two rows at a time (O(min(m,n)) space)
  if (m > n) {
    // Swap to use less memory — LCS is symmetric
    return _lcsRatio(text, query);
  }
  var prev = List<int>.filled(m + 1, 0);
  var curr = List<int>.filled(m + 1, 0);
  for (int j = 1; j <= n; j++) {
    for (int i = 1; i <= m; i++) {
      if (query[i - 1] == text[j - 1]) {
        curr[i] = prev[i - 1] + 1;
      } else {
        curr[i] = prev[i] > curr[i - 1] ? prev[i] : curr[i - 1];
      }
    }
    final tmp = prev;
    prev = curr;
    curr = tmp;
    curr.fillRange(0, m + 1, 0);
  }
  return prev[m] / m;
}

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

int? _parseDateToMs(String raw) {
  raw = raw.trim();
  if (raw == 'today') {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
  }
  if (raw == 'yesterday') {
    final now = DateTime.now().subtract(const Duration(days: 1));
    return DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
  }
  final ts = int.tryParse(raw);
  if (ts != null) return ts < 1e12 ? ts * 1000 : ts;
  try {
    final d = DateTime.parse(raw);
    return d.millisecondsSinceEpoch;
  } catch (_) {}
  return null;
}

final _logicalTagMap = <String, String>{
  'size': 'size_bytes',
  'length': 'duration_ms',
  'duration': 'duration_ms',
  'width': 'width',
  'height': 'height',
  'fps': 'fps',
  'date': 'mtime',
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

  if (token.type is TokTagLogical) {
    // parse @tag>value, @tag<value, @tag=value, @tag>=value, @tag<=value
    final match = RegExp(r'^@(\w+)([<>=]=?)(.+)$').firstMatch(raw);
    if (match == null) return null;
    final tag = match.group(1)!.toLowerCase();
    final op = match.group(2)!;
    final val = match.group(3)!.trim();

    final column = _logicalTagMap[tag];
    if (column == null) return null;

    if (tag == 'date') {
      final ms = _parseDateToMs(val);
      if (ms == null) return null;
      return TagFilter(column, op, ms.toString());
    }

    // fp → SQL operator (replace = with == for SQLite compatibility)
    final sqlOp = op == '=' ? '=' : op;
    return TagFilter(column, sqlOp, val);
  }

  if (token.type is TokTagModality) {
    final tag = raw.substring(1); // remove '@'
    // tag is like 'has:audio', 'has:speech', 'has:text', 'has:motion'
    final col = tag.replaceAll(':', '_');
    return TagFilter(col, '=', '1');
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
        tok.type is TokTagLogical ||
        tok.type is TokTagModality ||
        tok.type is TokTagMode) {
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
        ty is TokTagModality ||
        ty is TokTagMode ||
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
  double? _minScore;
  double? _maxScore;
  SearchSpace _searchSpace = SearchSpace.ultimate;

  String get query => _query;
  FilterExpr? get expression => _expression;
  bool get hasTags => _expression != null;
  bool get isActive => _query.trim().isNotEmpty;
  bool get hasSemantic => _semanticText.isNotEmpty;
  Map<String, double> get scores => _scores;
  SearchSpace get searchSpace => _searchSpace;

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
  }

  void _extractScoreConstraints() {
    _minScore = null;
    _maxScore = null;
    final scoreMatch = RegExp(
      r'@score([<>=]=?)(\d+(?:\.\d+)?)',
    ).firstMatch(_query);
    if (scoreMatch == null) return;
    final op = scoreMatch.group(1)!;
    final val = double.tryParse(scoreMatch.group(2)!);
    if (val == null) return;
    if (op == '>' || op == '>=') _minScore = val;
    if (op == '<' || op == '<=') _maxScore = val;
    if (op == '=') {
      _minScore = val;
      _maxScore = val;
    }
  }

  /// Extract plain text tokens for semantic search.
  /// Detects search space: @imagecontent, @ocr, @transcript, @audiocontent.
  /// Default is ultimate (search_emb).
  void _extractSemanticText() {
    _searchSpace = SearchSpace.ultimate;
    final q = _query.toLowerCase();
    if (q.contains('@audiocontent')) {
      _searchSpace = SearchSpace.clap;
    } else if (q.contains('@imagecontent')) {
      _searchSpace = SearchSpace.siglip;
    } else if (q.contains('@ocr')) {
      _searchSpace = SearchSpace.ocr;
    } else if (q.contains('@transcript')) {
      _searchSpace = SearchSpace.transcript;
    }

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

  Future<void> _autoInitEmbedding() async {
    try {
      final modelsPath = await EmbeddingService.resolveModelsPath();
      final tier = PlayerPrefs.getString('model_tier', 'lite');
      await EmbeddingService.instance.initialize(
        modelsPath: modelsPath,
        tier: tier,
      );
    } catch (e) {
      debugPrint('[filter] auto-init embedding failed: $e');
    }
  }

  Future<List<String>> execute(String rootPath) async {
    Set<String> tagPaths = {};
    List<String> semanticPaths = [];

    if (_expression != null) {
      tagPaths = await executeFilter(rootPath, _expression!);
    }

    if (_semanticText.isNotEmpty) {
      if (!EmbeddingService.instance.isInitialized) {
        await _autoInitEmbedding();
      }
      if (EmbeddingService.instance.isInitialized) {
        semanticPaths = await _executeSemantic(rootPath);
      } else {
        showBubble(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, color: Color(0xFFFF6B6B)),
              const SizedBox(width: 12),
              const Flexible(
                child: Text(
                  'No embedding models loaded - download first',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    decoration: TextDecoration.none,
                  ),
                  softWrap: true,
                ),
              ),
            ],
          ),
        );
      }
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

    // Intersect: if both tag and semantic, return score-sorted intersection
    if (_expression != null && _semanticText.isNotEmpty) {
      final semanticSet = semanticPaths.toSet();
      _scores.removeWhere((k, _) => !semanticSet.contains(k));
      final intersection = tagPaths
          .where((p) => semanticSet.contains(p))
          .toSet();
      final sorted = intersection.toList()
        ..sort((a, b) => (_scores[b] ?? 0).compareTo(_scores[a] ?? 0));
      return sorted;
    }

    if (_semanticText.isNotEmpty) {
      return semanticPaths;
    }

    return tagPaths.toList();
  }

  Future<List<String>> _executeSemantic(String rootPath) async {
    _scores = {};

    final svc = EmbeddingService.instance;
    final isClapMode = _searchSpace == SearchSpace.clap;
    final useFuzzy = _searchSpace == SearchSpace.ocr;

    // Embed query text (skip for fuzzy mode — not needed)
    Float32List? queryEmb;
    Float32List? queryClap;
    if (!useFuzzy) {
      if (isClapMode) {
        final clapTokPath = p.join(svc.modelsPath!, 'clap', 'tokenizer.json');
        if (!File(clapTokPath).existsSync()) {
          stderr.writeln('[filter] CLAP models not available, falling back to ultimate');
          _searchSpace = SearchSpace.ultimate;
        } else {
          final clapTok = HuggingFaceTokenizer.fromFile(clapTokPath);
          final clapIds = clapTok.encodeClap(_semanticText);
          queryClap = await svc.embedClapText(clapIds);
        }
      }
      if (!isClapMode || _searchSpace == SearchSpace.ultimate) {
        final clipTok = HuggingFaceTokenizer.fromFile(
          p.join(svc.modelsPath!, 'clip', 'tokenizer.json'),
        );
        final clipIds = clipTok.encodeClip(_semanticText);
        queryEmb = await svc.embedClipText(clipIds);
      }
    }

    // Determine which column to fetch based on search space
    final String embColumn;
    switch (_searchSpace) {
      case SearchSpace.ultimate:
        embColumn = 'search_emb';
      case SearchSpace.siglip:
        embColumn = 'clip_emb';
      case SearchSpace.ocr:
        embColumn = 'ocr_emb';
      case SearchSpace.transcript:
        embColumn = 'transcript_emb';
      case SearchSpace.clap:
        embColumn = 'clap_emb';
    }

    final dbPath = p.join(rootPath, '.memefolder.db');
    if (!File(dbPath).existsSync()) return [];

    final db = await openDatabase(dbPath, readOnly: true);

    try {
      // Determine media types to query
      final mediaWhere = <String>[];
      if (isClapMode) {
        mediaWhere.addAll(['audio', 'video']);
      } else {
        mediaWhere.addAll(['image', 'video', 'audio']);
      }
      final mediaList = mediaWhere.toSet().toList();
      final placeholders = mediaList.map((_) => '?').join(',');

      // When fuzzy matching, JOIN file_text to get raw OCR text
      final join = useFuzzy ? 'LEFT JOIN file_text ft ON f.id = ft.file_id' : '';
      final textSelect = useFuzzy ? ', ft.ocr_text AS raw_text' : '';

      final rows = await db.rawQuery('''
        SELECT f.id, f.rel_path, f.status$textSelect
        FROM files f
        $join
        WHERE f.media_type IN ($placeholders)
      ''', mediaList);

      final cd = svc.clipDim;
      final ad = svc.clapDim;

      final filePaths = <String>[];
      final statuses = <String>[];
      final embBlobs = <Uint8List?>[];
      final clapBlobs = <Uint8List?>[];
      final rawTexts = <String?>[];
      final seen = <String>{};
      final rowIds = <int>[];

      for (final row in rows) {
        final path = p.join(rootPath, row['rel_path'] as String);
        if (!seen.add(path)) continue;
        filePaths.add(path);
        statuses.add(row['status'] as String? ?? '');
        rowIds.add(row['id'] as int);
        embBlobs.add(null);
        clapBlobs.add(null);
        if (useFuzzy) rawTexts.add(row['raw_text'] as String?);
      }

      const batchSize = 500;
      for (var offset = 0; offset < rowIds.length; offset += batchSize) {
        final end = (offset + batchSize).clamp(0, rowIds.length);
        final batchIds = rowIds.sublist(offset, end);
        final placeholders2 = batchIds.map((_) => '?').join(',');
        final embRows = await db.rawQuery(
          'SELECT id, $embColumn, clap_emb FROM files WHERE id IN ($placeholders2)',
          batchIds,
        );
        final byId = <int, Map<String, Object?>>{};
        for (final r in embRows) {
          byId[r['id'] as int] = r;
        }
        for (var i = offset; i < end; i++) {
          final r = byId[rowIds[i]];
          if (r != null) {
            embBlobs[i] = r[embColumn] as Uint8List?;
            clapBlobs[i] = r['clap_emb'] as Uint8List?;
          }
        }
      }

      // Split query into lowercase words for fuzzy matching
      final queryWords = useFuzzy
          ? _semanticText.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList()
          : null;

      final params = <String, Object?>{
        'queryEmb': queryEmb,
        'queryClap': queryClap,
        'clipDim': cd,
        'clapDim': ad,
        'filePaths': filePaths,
        'statuses': statuses,
        'searchBlobs': embBlobs,
        'clapBlobs': clapBlobs,
        'isClapMode': isClapMode,
        'rawTexts': useFuzzy ? rawTexts : null,
        'queryWords': queryWords,
      };

      final results = await compute(_computeScoresInIsolate, params);

      for (final r in results) {
        final absPath = r['path'] as String;
        final score = r['score'] as double?;
        if (score != null) _scores[absPath] = score;
      }
    } finally {
      await db.close();
    }

    if (_scores.isEmpty) return [];

    // min-max normalize _scores to [0, 100]
    final keys = _scores.keys.where((k) => _scores[k]! >= 0).toList();
    if (keys.length > 1) {
      double minV = _scores[keys[0]]!, maxV = _scores[keys[0]]!;
      for (final k in keys) {
        final v = _scores[k]!;
        if (v < minV) minV = v;
        if (v > maxV) maxV = v;
      }
      final range = maxV - minV;
      for (final k in keys) {
        _scores[k] = range > 0 ? ((_scores[k]! - minV) / range) * 100.0 : 100.0;
      }
    } else if (keys.length == 1) {
      _scores[keys[0]] = 100.0;
    }

    // sort descending by score, put failed at end
    final sorted = _scores.entries.toList()
      ..sort((a, b) {
        if (a.value < 0 && b.value < 0) return 0;
        if (a.value < 0) return 1;
        if (b.value < 0) return -1;
        return b.value.compareTo(a.value);
      });

    return sorted.map((e) => e.key).toList();
  }
}
