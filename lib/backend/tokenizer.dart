import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class HuggingFaceTokenizer {
  final Map<String, int> vocab;
  final Map<int, String> revVocab;
  final Map<int, Map<int, (int, int)>> mergeMap;
  final List<int>? startTokenId;
  final List<int>? endTokenId;
  final String? endOfWordSuffix;
  final bool doLowercase;
  final bool isByteLevel;

  final Map<String, List<int>> _bpeCache = {};
  final Map<int, String> _bytesToUnicode = {};
  final Map<String, int> _unicodeToBytes = {};
  final bool _isSiglip;

  HuggingFaceTokenizer._({
    required this.vocab,
    required this.revVocab,
    required this.mergeMap,
    this.startTokenId,
    this.endTokenId,
    this.endOfWordSuffix,
    this.doLowercase = false,
    this.isByteLevel = true,
    bool isSiglip = false,
  }) : _isSiglip = isSiglip {
    _initByteEncoding();
  }

  factory HuggingFaceTokenizer.fromFile(String path) {
    final json = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    final model = json['model'] as Map<String, dynamic>;
    final rawVocab = model['vocab'] as Map<String, dynamic>;
    final rawMerges = model['merges'] as List<dynamic>;
    final isListMerges = rawMerges.isNotEmpty && rawMerges[0] is List;

    final vocab = rawVocab.map((k, v) => MapEntry(k, (v as num).toInt()));
    final revVocab = vocab.map((k, v) => MapEntry(v, k));
    final eowSuffix = model['end_of_word_suffix'] as String?;
    final hasSequencePreTokenizer = json['pre_tokenizer']?['type'] == 'Sequence';

    // Build merge map: (left_id, right_id) -> (rank, new_id)
    // merges are ordered by priority (lower index = higher priority)
    final mergeMap = <int, Map<int, (int, int)>>{};
    for (int rank = 0; rank < rawMerges.length; rank++) {
      final parts = isListMerges
          ? (rawMerges[rank] as List<dynamic>).cast<String>()
          : (rawMerges[rank] as String).split(' ');
      final left = parts[0];
      final right = parts[1];
      final leftId = vocab[left];
      final rightId = vocab[right];
      final merged = left + right;
      final newId = vocab[merged];
      if (leftId != null && rightId != null && newId != null) {
        mergeMap.putIfAbsent(leftId, () => {});
        mergeMap[leftId]![rightId] = (rank, newId);
      }
    }

    bool doLower = false;
    final normalizer = json['normalizer'];
    if (normalizer is Map) {
      final normalizers = normalizer['type'] == 'Sequence'
          ? (normalizer['normalizers'] as List)
          : [normalizer];
      for (final n in normalizers) {
        if (n is Map && n['type'] == 'Lowercase') doLower = true;
      }
    }

    List<int>? startId, endId;
    bool isSiglip = false;
    final pp = json['post_processor'] as Map<String, dynamic>?;
    if (pp != null && pp['type'] == 'RobertaProcessing') {
      final cls = pp['cls'] as List;
      final sep = pp['sep'] as List;
      if (cls.length >= 2) startId = [(cls[1] as num).toInt()];
      if (sep.length >= 2) endId = [(sep[1] as num).toInt()];
    } else if (pp != null && pp['type'] == 'TemplateProcessing' &&
               json['pre_tokenizer']?['type'] == 'Split') {
      isSiglip = true;
      final special = pp['special_tokens'] as Map<String, dynamic>?;
      if (special != null) {
        for (final entry in special.entries) {
          final tokenName = entry.value['id'] as String?;
          final ids = entry.value['ids'] as List?;
          if (tokenName != null && ids != null && ids.isNotEmpty) {
            if (tokenName == '<eos>') {
              endId = [(ids[0] as num).toInt()];
            }
            if (tokenName == '<bos>') {
              startId = [(ids[0] as num).toInt()];
            }
          }
        }
      }
    }
    if (startId == null && vocab.containsKey('<|startoftext|>')) {
      startId = [vocab['<|startoftext|>']!];
      endId ??= [vocab['<|endoftext|>']!];
    }
    if (startId == null && vocab.containsKey('<s>')) {
      startId = [vocab['<s>']!];
      endId ??= [vocab['</s>']!];
    }

    return HuggingFaceTokenizer._(
      vocab: vocab,
      revVocab: revVocab,
      mergeMap: mergeMap,
      startTokenId: startId,
      endTokenId: endId,
      endOfWordSuffix: (eowSuffix != null && eowSuffix.isNotEmpty) ? eowSuffix : null,
      doLowercase: doLower,
      isByteLevel: hasSequencePreTokenizer,
      isSiglip: isSiglip,
    );
  }

  void _initByteEncoding() {
    final List<int> bs = [];
    for (int i = '!'.codeUnitAt(0); i <= '~'.codeUnitAt(0); i++) bs.add(i);
    for (int i = 161; i <= 172; i++) bs.add(i);
    for (int i = 174; i <= 255; i++) bs.add(i);

    int n = 0;
    final List<int> cs = List.generate(bs.length, (i) => bs[i]);
    for (int b = 0; b < 256; b++) {
      if (!bs.contains(b)) {
        bs.add(b);
        cs.add(256 + n);
        n++;
      }
    }

    for (int i = 0; i < bs.length; i++) {
      _bytesToUnicode[bs[i]] = String.fromCharCode(cs[i]);
    }
    for (int i = 0; i < bs.length; i++) {
      _unicodeToBytes[String.fromCharCode(cs[i])] = bs[i];
    }
  }

  /// Encode bytes to unicode string using GPT-2 mapping
  String _encodeBytes(String text) {
    final bytes = utf8.encode(text);
    return bytes.map((b) => _bytesToUnicode[b] ?? '').join();
  }

  /// GPT-2 regex pre-tokenization split (matches words, not spaces)
  static final RegExp _gpt2Split = RegExp(
    r"""'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+""",
    unicode: true,
  );

  String _normalize(String text) {
    text = text.replaceAll(RegExp(r'\s+'), ' ');
    if (doLowercase) text = text.toLowerCase();
    return text;
  }

  /// BPE merge on token IDs.
  /// [ids] is the initial list of token IDs (from vocab lookup).
  /// Returns merged list of token IDs.
  List<int> _bpe(List<int> ids) {
    if (ids.length <= 1) return ids;

    final cacheKey = ids.join(',');
    if (_bpeCache.containsKey(cacheKey)) return _bpeCache[cacheKey]!;

    var syms = [...ids];

    while (syms.length > 1) {
      int? bestRank;
      int bestPos = -1;

      for (int i = 0; i < syms.length - 1; i++) {
        final left = syms[i];
        final right = syms[i + 1];
        final inner = mergeMap[left];
        if (inner != null) {
          final entry = inner[right];
          if (entry != null) {
            final rank = entry.$1;
            if (bestRank == null || rank < bestRank) {
              bestRank = rank;
              bestPos = i;
            }
          }
        }
      }

      if (bestPos < 0) break;

      final inner = mergeMap[syms[bestPos]];
      if (inner == null) break;
      final entry = inner[syms[bestPos + 1]];
      if (entry == null) break;
      final newId = entry.$2;

      final newSyms = <int>[];
      for (int i = 0; i < syms.length; i++) {
        if (i == bestPos) {
          newSyms.add(newId);
          i++;
        } else {
          newSyms.add(syms[i]);
        }
      }
      syms = newSyms;
    }

    _bpeCache[cacheKey] = syms;
    return syms;
  }

  /// Build initial token IDs from a byte-encoded word.
  /// For CLIP (has suffix): last char gets suffix before vocab lookup.
  /// For CLAP (no suffix): each char looked up directly.
  List<int> _wordToIds(String word) {
    final chars = word.split('');
    final ids = <int>[];
    for (int i = 0; i < chars.length; i++) {
      final c = chars[i];
      final isLast = i == chars.length - 1;
      String key;
      if (isLast && endOfWordSuffix != null) {
        key = c + endOfWordSuffix!;
      } else {
        key = c;
      }
      final id = vocab[key];
      if (id != null) {
        ids.add(id);
      }
    }
    return ids;
  }

  /// Encode text to token IDs.
  List<int> encode(String text, {int? maxLength, bool addSpecialTokens = true}) {
    if (_isSiglip) {
      // SigLIP/Gemma tokenizer: replace spaces with ▁, single-word BPE
      String normalized = text.replaceAll(' ', '\u2581');
      if (normalized.isEmpty) normalized = '\u2581';
      final ids = <int>[];

      if (addSpecialTokens && startTokenId != null) {
        ids.addAll(startTokenId!);
      }

      final wordIds = _wordToIds(normalized);
      ids.addAll(_bpe(wordIds));

      if (addSpecialTokens && endTokenId != null) {
        ids.addAll(endTokenId!);
      }

      if (maxLength != null && ids.length > maxLength) {
        if (startTokenId != null && endTokenId != null &&
            startTokenId!.length + endTokenId!.length < maxLength) {
          final keep = maxLength - startTokenId!.length - endTokenId!.length;
          return [...startTokenId!, ...ids.skip(startTokenId!.length).take(keep), ...endTokenId!];
        }
        return ids.sublist(0, maxLength);
      }

      return ids;
    }

    text = _normalize(text);
    final ids = <int>[];

    if (addSpecialTokens && startTokenId != null) {
      ids.addAll(startTokenId!);
    }

    // Pre-tokenize: split into words, byte-encode each
    final byteWords = <String>[];
    if (isByteLevel) {
      // For byte-level models (CLIP), use regex split then byte-encode each word
      // This matches the GPT-2 pre-tokenizer behavior: words without spaces
      final matches = _gpt2Split.allMatches(text);
      for (final m in matches) {
        byteWords.add(_encodeBytes(m.group(0)!));
      }
    } else {
      // For direct byte-level encoding (simple RoBERTa)
      // Split on whitespace, byte-encode each, handle spaces
      final words = text.split(' ').where((w) => w.isNotEmpty).toList();
      for (int i = 0; i < words.length; i++) {
        final w = i == 0 ? words[i] : ' ${words[i]}';
        byteWords.add(_encodeBytes(w));
      }
    }

    for (final bw in byteWords) {
      final wordIds = _wordToIds(bw);
      final tokenIds = _bpe(wordIds);
      ids.addAll(tokenIds);
    }

    if (addSpecialTokens && endTokenId != null) {
      ids.addAll(endTokenId!);
    }

    if (maxLength != null && ids.length > maxLength) {
      if (startTokenId != null && endTokenId != null && startTokenId!.length + endTokenId!.length < maxLength) {
        final keep = maxLength - startTokenId!.length - endTokenId!.length;
        return [...startTokenId!, ...ids.skip(startTokenId!.length).take(keep), ...endTokenId!];
      }
      return ids.sublist(0, maxLength);
    }

    return ids;
  }

  bool get isSiglip => _isSiglip;

  Int64List encodeClip(String text) {
    if (_isSiglip) {
      return encodeSiglip(text);
    }
    final ids = encode(text, addSpecialTokens: true, maxLength: 77);
    final padded = Int64List(77);
    final padId = vocab['<|endoftext|>'] ?? 0;
    for (int i = 0; i < 77; i++) {
      padded[i] = i < ids.length ? ids[i] : padId;
    }
    return padded;
  }

  Int64List encodeClap(String text) {
    final ids = encode(text, addSpecialTokens: true, maxLength: 77);
    final padded = Int64List(77);
    final padId = vocab['<pad>'] ?? 1;
    for (int i = 0; i < 77; i++) {
      padded[i] = i < ids.length ? ids[i] : padId;
    }
    return padded;
  }

  Int64List encodeSiglip(String text) {
    const maxLen = 64;
    final ids = encode(text, addSpecialTokens: true, maxLength: maxLen);
    final padded = Int64List(maxLen);
    final padId = vocab['<pad>'] ?? 0;
    for (int i = 0; i < maxLen; i++) {
      padded[i] = i < ids.length ? ids[i] : padId;
    }
    return padded;
  }

  /// Decode token IDs back to text (reverse of encode).
  String decode(List<int> ids, {bool skipSpecialTokens = true}) {
    final parts = <String>[];
    for (final id in ids) {
      final token = revVocab[id];
      if (token == null) continue;
      if (skipSpecialTokens && _isSpecialToken(token)) continue;
      parts.add(token);
    }
    final joined = parts.join();
    if (_isSiglip) {
      return joined.replaceAll('\u2581', ' ');
    }
    return _decodeBytes(joined);
  }

  bool _isSpecialToken(String token) {
    return token.startsWith('<|') && token.endsWith('|>');
  }

  /// Reverse byte encoding: unicode chars → bytes → UTF-8.
  String _decodeBytes(String text) {
    final bytes = <int>[];
    for (int i = 0; i < text.length; i++) {
      final c = text[i];
      final byte = _unicodeToBytes[c];
      bytes.add(byte ?? c.codeUnitAt(0));
    }
    return utf8.decode(bytes);
  }
}

/// Whisper tokenizer helper wrapping HuggingFaceTokenizer.
class WhisperTokenizer {
  final HuggingFaceTokenizer _inner;
  static const int sotId = 50258;
  static const int enId = 50259;
  static const int transcribeId = 50359;
  static const int notimestampsId = 50363;
  static const int eosId = 50257;

  WhisperTokenizer._(this._inner);

  factory WhisperTokenizer.fromFile(String path) {
    return WhisperTokenizer._(HuggingFaceTokenizer.fromFile(path));
  }

  Map<String, int> get vocab => _inner.vocab;
  Map<int, String> get revVocab => _inner.revVocab;

  /// Build the initial decoder prompt tokens: SOT + lang + task + notimestamps.
  List<int> promptTokens({int langId = enId, int taskId = transcribeId}) {
    return [sotId, langId, taskId, notimestampsId];
  }

  /// Decode whisper output tokens, stripping special/timestamp tokens.
  String decodeWhisper(List<int> ids) {
    final textTokens = ids.where((t) => t >= 0 && t < eosId).toList();
    return _inner.decode(textTokens, skipSpecialTokens: false);
  }

  Int64List encodeClip(String text) => _inner.encodeClip(text);
  Int64List encodeClap(String text) => _inner.encodeClap(text);
  List<int> encode(String text, {int? maxLength, bool addSpecialTokens = true}) =>
      _inner.encode(text, maxLength: maxLength, addSpecialTokens: addSpecialTokens);
}
