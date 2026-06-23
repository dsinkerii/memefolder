import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:memefolder/backend/custom_tags_store.dart';
import 'package:memefolder/filtering/filtering.dart';
import 'package:memefolder/helpers/styled_inputfields.dart';
import 'package:memefolder/prefs.dart';

// autocomplete suggestions
final List<({String tag, Color color, String label})> _allTags = [
  (tag: '@video', color: Color(0xFFB1F024), label: 'type'),
  (tag: '@gif', color: Color(0xFFB1F024), label: 'type'),
  (tag: '@picture', color: Color(0xFFB1F024), label: 'type'),
  (tag: '@image', color: Color(0xFFB1F024), label: 'type'),
  (tag: '@photo', color: Color(0xFFB1F024), label: 'type'),
  (tag: '@audio', color: Color(0xFFB1F024), label: 'type'),
  (tag: '@sound', color: Color(0xFFB1F024), label: 'type'),

  (tag: '@.mp4', color: Color(0xFF55AFD4), label: 'ext'),
  (tag: '@.jpg', color: Color(0xFF55AFD4), label: 'ext'),
  (tag: '@.jpeg', color: Color(0xFF55AFD4), label: 'ext'),
  (tag: '@.png', color: Color(0xFF55AFD4), label: 'ext'),
  (tag: '@.gif', color: Color(0xFF55AFD4), label: 'ext'),
  (tag: '@.webm', color: Color(0xFF55AFD4), label: 'ext'),
  (tag: '@.webp', color: Color(0xFF55AFD4), label: 'ext'),
  (tag: '@.svg', color: Color(0xFF55AFD4), label: 'ext'),
  (tag: '@.mp3', color: Color(0xFF55AFD4), label: 'ext'),
  (tag: '@.wav', color: Color(0xFF55AFD4), label: 'ext'),
  (tag: '@.ogg', color: Color(0xFF55AFD4), label: 'ext'),
  (tag: '@.flac', color: Color(0xFF55AFD4), label: 'ext'),
  (tag: '@.mkv', color: Color(0xFF55AFD4), label: 'ext'),
  (tag: '@.avi', color: Color(0xFF55AFD4), label: 'ext'),
  (tag: '@.mov', color: Color(0xFF55AFD4), label: 'ext'),

  (tag: '@has:audio', color: Color(0xFFF36E36), label: 'modality'),
  (tag: '@has:speech', color: Color(0xFFF36E36), label: 'modality'),
  (tag: '@has:text', color: Color(0xFFF36E36), label: 'modality'),

  // folder: placeholder entries - real ones injected dynamically from workdir
  (tag: '@folder:', color: Color(0xFF4EB8A0), label: 'folder'),
  (
    tag: '@folder:${PlayerPrefs.getString("main_folder")}',
    color: Color(0xFF4EB8A0),
    label: 'folder',
  ),

  (tag: '@date>', color: Color(0xFFFFB30B), label: 'logical'),
  (tag: '@date<', color: Color(0xFFFFB30B), label: 'logical'),
  (tag: '@date=', color: Color(0xFFFFB30B), label: 'logical'),
  (tag: '@size>', color: Color(0xFFFFB30B), label: 'logical'),
  (tag: '@size<', color: Color(0xFFFFB30B), label: 'logical'),
  (tag: '@size=', color: Color(0xFFFFB30B), label: 'logical'),
  (tag: '@length>', color: Color(0xFFFFB30B), label: 'logical'),
  (tag: '@length<', color: Color(0xFFFFB30B), label: 'logical'),
  (tag: '@duration>', color: Color(0xFFFFB30B), label: 'logical'),
  (tag: '@duration<', color: Color(0xFFFFB30B), label: 'logical'),
  (tag: '@width>', color: Color(0xFFFFB30B), label: 'logical'),
  (tag: '@width<', color: Color(0xFFFFB30B), label: 'logical'),
  (tag: '@height>', color: Color(0xFFFFB30B), label: 'logical'),
  (tag: '@height<', color: Color(0xFFFFB30B), label: 'logical'),
  (tag: '@fps>', color: Color(0xFFFFB30B), label: 'logical'),
  (tag: '@fps<', color: Color(0xFFFFB30B), label: 'logical'),
];

final List<({String tag, Color color, String label})> _allOperators = [
  (tag: '&', color: Color(0xFFAE4393), label: 'and'),
  (tag: '|', color: Color(0xFF8AD4E4), label: 'or'),
  (tag: '!', color: Color(0xFFB01B00), label: 'not'),
  (tag: '(', color: Color(0xFFAB5C74), label: 'open'),
  (tag: ')', color: Color(0xFFAB5C74), label: 'close'),
];

final List<({Color color, String label})> _legendEntries = [
  (color: Color(0xFFB1F024), label: 'file type'),
  (color: Color(0xFF55AFD4), label: 'extension'),
  (color: Color(0xFFF36E36), label: 'modality'),
  (color: Color(0xFFFFB30B), label: 'logical'),
  (color: Color(0xFF9436A6), label: 'custom'),
  (color: Color(0xFF4EB8A0), label: 'folder'),
  (color: Color(0xFFAE4393), label: 'and'),
  (color: Color(0xFF8AD4E4), label: 'or'),
  (color: Color(0xFFB01B00), label: 'not'),
  (color: Color(0xFFAB5C74), label: 'group'),
];

// global focus state (for main.dart to listen)
class ContextBarState {
  static final ValueNotifier<bool> isFocused = ValueNotifier(false);
}

// public widget, just the TextField
final SearchController searchController = SearchController();

Widget contextBar(BuildContext context) {
  return _ContextBarField(controller: searchController);
}

// color legend bar (used by main.dart below the bar)
class ColorLegendBar extends StatelessWidget {
  const ColorLegendBar({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(64, 0, 16, 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 2,
        children: _legendEntries.map((e) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: e.color,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 3),
              Text(
                e.label,
                style: TextStyle(
                  fontSize: 16,
                  color: cs.onSurface.withAlpha(140),
                  fontFamily: "Syne",
                  fontVariations: [FontVariation('wght', 500)],
                ),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }
}

// the actual TextField widget with focus + autocomplete
class _ContextBarField extends StatefulWidget {
  final SearchController controller;
  const _ContextBarField({required this.controller});

  @override
  State<_ContextBarField> createState() => _ContextBarFieldState();
}

class _ContextBarFieldState extends State<_ContextBarField> {
  final FocusNode _focusNode = FocusNode();
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _suggestionsOverlay;
  List<({String tag, Color color, String label})> _suggestions = [];
  int _selectedIndex = -1;

  @override
  void initState() {
    super.initState();
    CustomTagsStore.instance.addListener(_onTagsChanged);
    _focusNode.addListener(() {
      final focused = _focusNode.hasFocus;
      ContextBarState.isFocused.value = focused;
      if (!focused) {
        _removeSuggestions();
      } else {
        _updateSuggestions(widget.controller.text);
      }
    });

    widget.controller.addListener(() {
      if (_focusNode.hasFocus) {
        _updateSuggestions(widget.controller.text);
      }
    });
  }

  @override
  void dispose() {
    CustomTagsStore.instance.removeListener(_onTagsChanged);
    _focusNode.dispose();
    _removeSuggestions();
    super.dispose();
  }

  void _onTagsChanged() {
    if (mounted) setState(() {});
    if (_focusNode.hasFocus) {
      _updateSuggestions(widget.controller.text);
    }
  }

  // autocomplete logic

  void _updateSuggestions(String text) {
    if (text.isEmpty || !_focusNode.hasFocus) {
      _removeSuggestions();
      if (mounted) setState(() => _suggestions = []);
      return;
    }

    final cursorPos = widget.controller.selection.baseOffset;
    if (cursorPos < 0) {
      _removeSuggestions();
      if (mounted) setState(() => _suggestions = []);
      return;
    }

    int tokenStart = cursorPos;
    while (tokenStart > 0) {
      final ch = text[tokenStart - 1];
      if (ch == ' ' || ch == '&' || ch == '|' || ch == '(' || ch == ')') break;
      tokenStart--;
    }
    final currentWord = text.substring(tokenStart, cursorPos);

    if (currentWord.isEmpty) {
      _removeSuggestions();
      if (mounted) setState(() => _suggestions = []);
      return;
    }

    final lower = currentWord.toLowerCase();
    final dynamicCustomTags = CustomTagsStore.instance.tags
        .map(
          (t) => (tag: '@$t', color: const Color(0xFF9436A6), label: 'custom'),
        )
        .toList();

    // TODO: replace with real folder list from DB/workdir
    final dynamicFolderTags = <({String tag, Color color, String label})>[
      (
        tag: '@folder:${PlayerPrefs.getString("main_folder")}',
        color: const Color(0xFF4EB8A0),
        label: 'folder',
      ),
    ];

    final allTags = [..._allTags, ...dynamicCustomTags, ...dynamicFolderTags];
    final matches = [
      ...allTags.where((t) => t.tag.toLowerCase().startsWith(lower)),
      ..._allOperators.where((t) => t.tag.toLowerCase().startsWith(lower)),
    ].take(8).toList();

    if (mounted) {
      setState(() {
        _suggestions = matches;
        _selectedIndex = matches.isNotEmpty ? 0 : -1;
      });
    }

    if (_suggestions.isNotEmpty) {
      _showOverlay();
    } else {
      _removeSuggestions();
    }
  }

  void _showOverlay() {
    _removeSuggestions();
    _suggestionsOverlay = OverlayEntry(
      builder: (_) => _TagSuggestionsPopup(
        link: _layerLink,
        suggestions: _suggestions,
        selectedIndex: _selectedIndex,
        onTap: _applySuggestion,
      ),
    );
    Overlay.of(context).insert(_suggestionsOverlay!);
  }

  void _removeSuggestions() {
    _suggestionsOverlay?.remove();
    _suggestionsOverlay = null;
  }

  void _applySuggestion(int index) {
    if (index < 0 || index >= _suggestions.length) return;

    final text = widget.controller.text;
    final cursorPos = widget.controller.selection.baseOffset;

    int tokenStart = cursorPos;
    while (tokenStart > 0) {
      final ch = text[tokenStart - 1];
      if (ch == ' ' || ch == '&' || ch == '|' || ch == '(' || ch == ')') break;
      tokenStart--;
    }

    final suggestion = _suggestions[index].tag;
    final newText =
        text.substring(0, tokenStart) + suggestion + text.substring(cursorPos);

    widget.controller.text = newText;
    widget.controller.selection = TextSelection.fromPosition(
      TextPosition(offset: tokenStart + suggestion.length),
    );

    _removeSuggestions();
    if (mounted) setState(() => _suggestions = []);
    _focusNode.requestFocus();
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (_suggestions.isEmpty || !_focusNode.hasFocus) return false;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;

    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() {
        _selectedIndex = (_selectedIndex + 1).clamp(0, _suggestions.length - 1);
      });
      _suggestionsOverlay?.markNeedsBuild();
      return true;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _selectedIndex = (_selectedIndex - 1).clamp(0, _suggestions.length - 1);
      });
      _suggestionsOverlay?.markNeedsBuild();
      return true;
    } else if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.tab) {
      if (_selectedIndex >= 0) {
        _applySuggestion(_selectedIndex);
        return true;
      }
    } else if (event.logicalKey == LogicalKeyboardKey.escape) {
      _removeSuggestions();
      if (mounted) setState(() => _suggestions = []);
      return true;
    }
    return false;
  }

  void _applyFilter(String val) {
    final text = searchController.text.trim();
    debugPrint('[ctxbar] _applyFilter text="$text"');
    FilterService.instance.setQuery(text);
    _removeSuggestions();
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: KeyboardListener(
        focusNode: FocusNode(),
        onKeyEvent: _handleKeyEvent,
        child: TextField(
          onSubmitted: (val) => _applyFilter(val),
          decoration: newInputDeco(context).copyWith(
            hintText: "context...",
            prefixIcon: ValueListenableBuilder(
              valueListenable: widget.controller,
              builder: (context, value, child) {
                return widget.controller.text.isNotEmpty
                    ? IconButton(
                        icon: Icon(
                          Icons.clear,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withAlpha(160),
                        ),
                        onPressed: () {
                          widget.controller.clear();
                          _removeSuggestions();
                          FilterService.instance.clear();
                        },
                      )
                    : SizedBox.shrink();
              },
            ),
            suffixIcon: ValueListenableBuilder(
              valueListenable: widget.controller,
              builder: (context, value, child) {
                return widget.controller.text.isNotEmpty
                    ? IconButton(
                        icon: Icon(Icons.search,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withAlpha(160)),
                        onPressed: () => _applyFilter(widget.controller.text),
                      )
                    : SizedBox.shrink();
              },
            ),
          ),
          style: newInputStyle(context).copyWith(
            fontFamily: "Syne",
            fontVariations: [
              FontVariation('wdth', 2800),
              FontVariation('wght', 600),
            ],
          ),
          controller: widget.controller,
          focusNode: _focusNode,
          onTapOutside: (_) => _focusNode.unfocus(),
        ),
      ),
    );
  }
}

// SearchController (syntax highlighting)

class SearchController extends TextEditingController {
  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final tokens = tokenize(text);
    return TextSpan(
      style: style,
      children: tokens
          .map(
            (t) => TextSpan(
              text: t.value,
              style: t.type.style.copyWith(
                color: Color.lerp(
                  Theme.of(context).colorScheme.onSurface,
                  t.type.style.color,
                  0.3,
                ),
              ),
            ),
          )
          .toList(),
    );
  }
}

// tokenizer

// Validates @folder:<path>:
// - must have at least one path segment after the colon
// - segments are word chars, digits, hyphens, underscores, spaces (no trailing slash)
// - max 5 depth levels (4 slashes)
final _folderPathRegex = RegExp(
  r'^folder:[a-zA-Z0-9_\- ]+(?:\/[a-zA-Z0-9_\- ]+){0,4}$',
);

List<Token> tokenize(String text) {
  final customTags = CustomTagsStore.instance.tags;

  List<Token> tokens = [];
final regexTokens = RegExp(
    r'(\\@)' // 1. escaped @
    r'|(@has:(?:audio|speech|text))' // 2. modality
    r'|(\(|\))' // 3. brackets
    r'|(!)' // 4. not
    r'|(&)' // 5. and
    r'|(\|)' // 6. or
    r'|(@\.[a-zA-Z0-9]{2,4}(?=\s|$|[&|!()]))' // 7. extension
    r'|(@(?:video|gif|picture|image|photo|audio|sound))' // 8. filetype
    r'|(@date[><=:][^\s@&|!()]+)' // 9. date logical
    r'|(@date\?[0-9]{4}(?:[\d.]*))' // 9b. date format: @date?YYYY, @date?MM.YYYY, @date?DD.MM.YYYY
    r'|(@(?:size|length|duration|width|height|fps|score)(?:[<>=]=?)[^\s@&|!()]+)' // 10. other logical
    r'|(@folder:[^\s@&|!()]*)' // 11. folder
    r'|(@[^\s]*)', // 12. catch-all
    caseSensitive: false,
  );
  int cursor = 0;

  for (final match in regexTokens.allMatches(text)) {
    if (match.start > cursor) {
      tokens.add(Token(TokText(), text.substring(cursor, match.start)));
    }

    final g = match.group(0)!;
    final TokenType type;

    if (match.group(1) != null) {
      type = TokEscaped();
    } else if (match.group(2) != null) {
      type = TokTagModality();
    } else if (match.group(3) != null) {
      type = TokOpBracket();
    } else if (match.group(4) != null) {
      type = TokOpNot();
    } else if (match.group(5) != null) {
      type = TokOpAnd();
    } else if (match.group(6) != null) {
      type = TokOpOr();
    } else if (match.group(7) != null) {
      type = TokTagFileext();
    } else if (match.group(8) != null) {
      type = TokTagFiletype();
    } else if (match.group(9) != null || match.group(10) != null) {
      type = TokTagLogical();
    } else if (match.group(11) != null) {
      type = TokTagLogical();
    } else if (match.group(12) != null) {
      final slug = g.substring(1);
      type = _folderPathRegex.hasMatch(slug) ? TokTagFolder() : TokTagInvalid();
    } else if (match.group(13) != null) {
      final word = g.startsWith('@')
          ? g.substring(1).toLowerCase()
          : g.toLowerCase();
      type = customTags.contains(word) ? TokTagCustom() : TokTagInvalid();
    } else {
      type = TokText();
    }

    tokens.add(Token(type, g));
    cursor = match.end;
  }

  if (cursor < text.length) {
    tokens.add(Token(TokText(), text.substring(cursor)));
  }

  return tokens;
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
  final TextStyle style = const TextStyle();
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

class TokTagFolder extends TokenType {
  @override
  final TextStyle style = _underlined(Color(0xFF4EB8A0));
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

class TokEscaped extends TokenType {
  @override
  final TextStyle style = _squiggly(Color(0xFF6E6E7A));
}

// autocomplete popup

class _TagSuggestionsPopup extends StatefulWidget {
  final LayerLink link;
  final List<({String tag, Color color, String label})> suggestions;
  final int selectedIndex;
  final ValueChanged<int> onTap;

  const _TagSuggestionsPopup({
    required this.link,
    required this.suggestions,
    required this.selectedIndex,
    required this.onTap,
  });

  @override
  State<_TagSuggestionsPopup> createState() => _TagSuggestionsPopupState();
}

class _TagSuggestionsPopupState extends State<_TagSuggestionsPopup>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  late final Animation<double> _fadeAnim;
  late final Animation<Offset> _slideAnim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _fadeAnim = CurvedAnimation(parent: _anim, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, -0.1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic));
    _anim.forward();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final maxHeight = min(widget.suggestions.length * 38.0, 220.0);

    return CompositedTransformFollower(
      link: widget.link,
      showWhenUnlinked: false,
      offset: const Offset(0, 48),
      child: UnconstrainedBox(
        alignment: Alignment.topLeft,
        child: FadeTransition(
          opacity: _fadeAnim,
          child: SlideTransition(
            position: _slideAnim,
            child: Material(
              elevation: 6,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: 280,
                constraints: BoxConstraints(maxHeight: maxHeight),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  shrinkWrap: true,
                  itemCount: widget.suggestions.length,
                  itemBuilder: (context, index) {
                    final s = widget.suggestions[index];
                    final isSelected = index == widget.selectedIndex;
                    return Material(
                      color: isSelected
                          ? cs.primary.withAlpha(30)
                          : Colors.transparent,
                      child: InkWell(
                        onTap: () => widget.onTap(index),
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: s.color,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  s.tag,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontFamily: "Syne",
                                    fontVariations: [
                                      FontVariation('wght', 600),
                                    ],
                                    color: s.color,
                                  ),
                                ),
                              ),
                              Text(
                                s.label,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: cs.onSurface.withAlpha(100),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
