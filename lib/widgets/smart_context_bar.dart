import 'package:flutter/material.dart';
import 'package:memefolder/helpers/styled_inputfields.dart';

final SearchController _searchController = SearchController(
  knownCustomTags: {'f'},
);
Widget contextBar(BuildContext context) {
  return TextField(
    decoration: newInputDeco(context).copyWith(hintText: "context..."),
    style: newInputStyle(context).copyWith(
      fontFamily: "Syne",
      fontVariations: [FontVariation('wdth', 2800), FontVariation('wght', 600)],
    ),
    controller: _searchController,
  );
}

class SearchController extends TextEditingController {
  final Set<String> knownCustomTags;
  SearchController({required this.knownCustomTags});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final tokens = tokenize(text, knownCustomTags);
    return TextSpan(
      style: style,
      children: tokens
          .map((t) => TextSpan(text: t.value, style: t.type.style))
          .toList(),
    );
  }
}

List<Token> tokenize(String text, Set<String> knownCustomTags) {
  List<Token> tokens = [];
  final regexTokens = RegExp(
    r'(\\@)' // 1. escape @'s
    r'|(@has:(?:audio|speech|text))|' // 2. modality
    r'(\(|\))|(!)|(&)|(\|)|' // 3. brackets. 4. not. 5. and. 6. or.
    r'(@\.[a-zA-Z0-9]{2,4}(?=\s|$|[&|!()\\]))|' // 7. extension
    r'(@(?:video|gif|picture|image|photo|audio|sound))|' // 8. type
    r'(@(?:minecraft))|' // 9. custom
    r'(@date[><=:][^\s@&|!()]+)|' // 10. date ranges
    r'(@(?:size|length|duration|width|height|fps|score)(?:[<>=]=?)[^\s@&|!()]+)|' // 11. logical
    r'(@[^\s]*)', // 12. invalid
    caseSensitive: false,
  );
  int cursor = 0;

  for (final match in regexTokens.allMatches(text)) {
    // plain text before this match
    if (match.start > cursor) {
      tokens.add(Token(TokText(), text.substring(cursor, match.start)));
    }

    tokens.add(Token(groupToTokenType(match), match.group(0)!));
    cursor = match.end;
  }

  // trailing plain text after last match
  if (cursor < text.length) {
    tokens.add(Token(TokText(), text.substring(cursor)));
  }

  return tokens;
}

TokenType groupToTokenType(RegExpMatch m) {
  if (m.group(1) != null) return TokEscaped();
  if (m.group(2) != null) return TokTagModality();
  if (m.group(3) != null) return TokOpBracket();
  if (m.group(4) != null) return TokOpNot();
  if (m.group(5) != null) return TokOpAnd();
  if (m.group(6) != null) return TokOpOr();
  if (m.group(7) != null) return TokTagFiletype();
  if (m.group(8) != null) return TokTagLogical(); // date
  if (m.group(9) != null) return TokTagLogical(); // size/length/etc
  if (m.group(10) != null) return TokTagFileext();
  if (m.group(11) != null) return TokTagCustom();
  if (m.group(12) != null) return TokTagInvalid();
  return TokText();
}

class Token {
  final TokenType type;
  final String value;
  Token(this.type, this.value);
}

TextStyle _underlined(Color c) => TextStyle(
  color: c,
  decoration: TextDecoration.underline,
  decorationColor: c,
  decorationThickness: 2.0,
  decorationStyle: TextDecorationStyle.solid,
);
TextStyle _squiggly(Color c) => TextStyle(
  color: c,
  decoration: TextDecoration.underline,
  decorationColor: c,
  decorationThickness: 1.0,
  decorationStyle: TextDecorationStyle.wavy,
);

sealed class TokenType {
  late TextStyle style;
}

class TokText extends TokenType {
  @override
  final TextStyle style = TextStyle();
}

class TokTagFiletype extends TokenType {
  @override
  final TextStyle style = _underlined(Color(0xFFB1F024));
}

class TokTagFileext extends TokenType {
  @override
  final TextStyle style = _underlined(Color(0xFF55AFD4));
}

class TokTagLogical extends TokenType {
  @override
  final TextStyle style = _underlined(Color(0xFFFFB30B));
}

class TokTagCustom extends TokenType {
  @override
  final TextStyle style = _underlined(Color(0xFF9436A6));
}

class TokTagModality extends TokenType {
  @override
  final TextStyle style = _underlined(Color(0xFFF36E36));
}

class TokTagInvalid extends TokenType {
  @override
  final TextStyle style = _squiggly(Color(0xFFE03030));
}

class TokOpOr extends TokenType {
  @override
  final TextStyle style = _underlined(Color(0xFF8AD4E4));
}

class TokOpAnd extends TokenType {
  @override
  final TextStyle style = _underlined(Color(0xFFAE4393));
}

class TokOpNot extends TokenType {
  @override
  final TextStyle style = _underlined(Color(0xFFB01B00));
}

class TokOpBracket extends TokenType {
  @override
  final TextStyle style = _underlined(Color(0xFFAB5C74));
}

class TokOpRange extends TokenType {
  @override
  final TextStyle style = _underlined(Color(0xFFAB5C74));
}

class TokEscaped extends TokenType {
  @override
  final TextStyle style = _squiggly(Color(0xFF6E6E7A));
}
