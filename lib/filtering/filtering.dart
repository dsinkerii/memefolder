import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
      'SELECT rel_path FROM files WHERE $where',
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

  String get query => _query;
  FilterExpr? get expression => _expression;
  bool get hasTags => _expression != null;
  bool get isActive => _expression != null;

  void setQuery(String query) {
    if (_query == query) return;
    debugPrint('[filter] setQuery: "$query"');
    _query = query;
    _expression = query.trim().isEmpty ? null : parseFilterExpression(query);
    debugPrint('[filter] expression=${_expression?.toString()} hasTags=$hasTags isActive=$isActive');
    notifyListeners();
  }

  void clear() => setQuery('');

  Future<List<String>> execute(String rootPath) async {
    if (_expression != null) {
      debugPrint('[filter] executing tag filter: ${_expression}');
      final tagResults = await executeFilter(rootPath, _expression!);
      debugPrint('[filter] tag filter returned ${tagResults.length} paths');
      return tagResults.toList();
    }
    return [];
  }
}
