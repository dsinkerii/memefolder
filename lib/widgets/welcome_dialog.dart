import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' hide SearchController;
import 'package:flutter_vector_icons/flutter_vector_icons.dart';
import 'package:http/http.dart' as http;
import 'package:memefolder/helpers/styled_inputfields.dart';
import 'package:memefolder/widgets/runtime_manager.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:dotted_border/dotted_border.dart';
import 'package:desktop_drop/desktop_drop.dart';

import 'package:memefolder/backend/system_specs.dart';
import 'package:memefolder/config/theme.dart';
import 'package:memefolder/helpers/new_dialog.dart';
import 'package:memefolder/prefs.dart';
import 'package:memefolder/widgets/file_badges.dart';
import 'package:memefolder/widgets/morphing_index_fab.dart';
import 'package:memefolder/widgets/smart_context_bar.dart';
import 'package:confetti/confetti.dart';

const _welcomeDoneKey = 'welcome_done';
const _launchCountKey = 'launch_count';

int get launchCount => PlayerPrefs.getInt(_launchCountKey, 0);
bool get isWelcomeDone => PlayerPrefs.getBool(_welcomeDoneKey, false);

void showWelcomeDialog(BuildContext context) {
  showScaleDialog(
    context: context,
    width: 600,
    maxHeight: 600,
    barrierDismissible: false,
    builder: (dialogCtx) => _TutorialDialog(
      onFinish: () {
        PlayerPrefs.setBool(_welcomeDoneKey, true);
        Navigator.of(dialogCtx).pop();
      },
    ),
  );
}

class _FakeFile {
  final String name;
  final String type;
  const _FakeFile(this.name, this.type);
}

const _fakeFiles = [
  _FakeFile('attachemnt.jpg', 'image'),
  _FakeFile('bob.png', 'image'),
  _FakeFile('saturnburger.mp4', 'video'),
  _FakeFile('video.mov', 'video'),
  _FakeFile('fart.mp3', 'audio'),
];

const _tutorialTags = ['@audio', '@video', '@image'];
const _tutorialOperators = ['&', '|', '!', '(', ')'];
List<String> get _tutorialSuggestions => [
  ..._tutorialTags,
  ..._tutorialOperators,
];

abstract class _Expr {
  bool eval(_FakeFile f);
}

class _TagAtom extends _Expr {
  final String tag;
  _TagAtom(this.tag);
  @override
  bool eval(_FakeFile f) => f.type == tag.replaceFirst('@', '').toLowerCase();
}

class _NotExpr extends _Expr {
  final _Expr inner;
  _NotExpr(this.inner);
  @override
  bool eval(_FakeFile f) => !inner.eval(f);
}

class _AndExpr extends _Expr {
  final _Expr left, right;
  _AndExpr(this.left, this.right);
  @override
  bool eval(_FakeFile f) => left.eval(f) && right.eval(f);
}

class _OrExpr extends _Expr {
  final _Expr left, right;
  _OrExpr(this.left, this.right);
  @override
  bool eval(_FakeFile f) => left.eval(f) || right.eval(f);
}

List<String> _tokenize(String input) =>
    RegExp(r'@\w+|[&|!()]').allMatches(input).map((m) => m.group(0)!).toList();

class _Parser {
  final List<String> tokens;
  int pos = 0;
  _Parser(this.tokens);

  _Expr? parse() => _parseE();

  _Expr? _parseE() {
    var left = _parseT();
    while (pos < tokens.length && tokens[pos] == '|') {
      pos++;
      final right = _parseT();
      if (right == null) break;
      left = _OrExpr(left!, right);
    }
    return left;
  }

  _Expr? _parseT() {
    var left = _parseF();
    while (pos < tokens.length && tokens[pos] == '&') {
      pos++;
      final right = _parseF();
      if (right == null) break;
      left = _AndExpr(left!, right);
    }
    return left;
  }

  _Expr? _parseF() {
    if (pos >= tokens.length) return null;
    if (tokens[pos] == '!') {
      pos++;
      final inner = _parseF();
      return inner != null ? _NotExpr(inner) : null;
    }
    if (tokens[pos] == '(') {
      pos++;
      final inner = _parseE();
      if (pos < tokens.length && tokens[pos] == ')') pos++;
      return inner;
    }
    if (tokens[pos].startsWith('@')) {
      final tag = _TagAtom(tokens[pos]);
      pos++;
      return tag;
    }
    return null;
  }
}

_Expr? _parseQuery(String input) {
  final tokens = _tokenize(input);
  if (tokens.isEmpty) return null;
  return _Parser(tokens).parse();
}

class _TutorialDialog extends StatefulWidget {
  final VoidCallback onFinish;
  const _TutorialDialog({required this.onFinish});
  @override
  State<_TutorialDialog> createState() => _TutorialDialogState();
}

class _TutorialDialogState extends State<_TutorialDialog> {
  late final PageController _pageCtrl;
  int _currentSlide = 0;

  late final ConfettiController _confettiCtrl = ConfettiController(
    duration: const Duration(seconds: 10),
  );
  OverlayEntry? _confettiEntry;

  // slide 1
  late final SearchController _searchCtrl = SearchController();
  final FocusNode _searchFocus = FocusNode();
  String _searchQuery = '';

  // slide 2
  bool _isIndexing = false;
  bool _indexed = false;
  double _fakeProgress = 0;
  String _fakeProgressText = '';

  // slide 3
  String _tier = 'lite';
  bool _loadingSpecs = true;
  String _tierRecommendation = '';
  bool _modelBusy = false;
  double _modelProgress = 0;
  String? _modelStatus;
  bool _dragHoveringZip = false;
  String _basePath = '';

  @override
  void initState() {
    super.initState();
    _pageCtrl = PageController();
    _loadTierData();
  }

  Future<void> _loadTierData() async {
    final saved = PlayerPrefs.getString('model_tier', '');
    final specs = await SystemSpecs.detect();
    if (!mounted) return;
    setState(() {
      if (saved == 'low') {
        _tier = 'lite';
      } else if (saved == 'high') {
        _tier = 'full';
      } else {
        _tier = saved.isNotEmpty ? saved : specs.tierRecommendation;
      }
      _tierRecommendation = specs.tierRecommendation;
      _loadingSpecs = false;
    });
    _basePath = await _modelsDir();
    if (mounted) setState(() {});
  }

  Future<String> _modelsDir() async {
    final projectDir = Directory(
      p.join(Directory.current.path, 'searchmodels'),
    );
    if (await projectDir.exists()) return projectDir.path;
    return p.join((await getApplicationSupportDirectory()).path, 'models');
  }

  @override
  void dispose() {
    _confettiEntry?.remove();
    _confettiCtrl.dispose();
    _pageCtrl.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _goToSlide(int index) {
    _pageCtrl.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOutCubic,
    );
    if (index == 4) {
      debugPrint("confetti");
      _showConfetti();
    }
  }

  void _showConfetti() {
    _confettiEntry?.remove();
    _confettiEntry = OverlayEntry(
      builder: (_) => IgnorePointer(
        child: ConfettiWidget(
          confettiController: _confettiCtrl,
          blastDirectionality: BlastDirectionality.explosive,
          shouldLoop: false,
          colors: const [
            Colors.green,
            Colors.blue,
            Colors.pink,
            Colors.orange,
            Colors.purple,
            Colors.yellow,
          ],
          numberOfParticles: 30,
          emissionFrequency: 0.05,
          particleDrag: 0.05,
          gravity: 0.02,
        ),
      ),
    );
    Overlay.of(context).insert(_confettiEntry!);
    _confettiCtrl.play();
    Future.delayed(const Duration(seconds: 12), () {
      _confettiEntry?.remove();
      _confettiEntry = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_currentSlide > 0 && _currentSlide < 4) _buildProgressDots(cs),
            Expanded(
              child: PageView(
                controller: _pageCtrl,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (i) {
                  setState(() => _currentSlide = i);
                  _searchFocus.unfocus();
                },
                children: [
                  _buildSlide0(),
                  _buildSlide1(),
                  _buildSlide2(),
                  _buildSlide3(),
                  _buildSlide4(),
                ],
              ),
            ),
            const SizedBox(height: 10),
            _buildNavigation(cs),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressDots(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(5, (i) {
          final active = i <= _currentSlide;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: active ? 18 : 5,
            height: 5,
            decoration: BoxDecoration(
              color: active ? cs.primary : cs.onSurface.withAlpha(40),
              borderRadius: BorderRadius.circular(3),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildSlide0() {
    final cs = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 6),
          Image(
            image: const ExactAssetImage("Assets/Images/CroppedLogo.png"),
            height: 180,
          ),
          const SizedBox(height: 6),
          Text(
            'welcome!',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 28,
              fontFamily: 'Syne',
              color: cs.onSurface,
              fontVariations: const [
                FontVariation('wdth', 2800),
                FontVariation('wght', 700),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'memefolder is a powerful app that you can use to search for files in '
            'your folders, powered by semantic search and cool tags!',
            textAlign: TextAlign.left,
            style: TextStyle(fontSize: 15, color: cs.onSurface),
          ),
          const SizedBox(height: 10),
          Text(
            'this quick tutorial will show you around',
            textAlign: TextAlign.left,
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildSlide1() {
    final cs = Theme.of(context).colorScheme;
    final q = _searchQuery.trim();
    final expr = q.isNotEmpty ? _parseQuery(q) : null;
    final filtered = expr == null
        ? _fakeFiles
        : _fakeFiles.where((f) => expr.eval(f)).toList();

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'what the hell is memefolder',
            style: TextStyle(
              fontSize: 18,
              fontFamily: 'Syne',
              color: cs.onSurface,
              fontVariations: const [
                FontVariation('wdth', 2800),
                FontVariation('wght', 700),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'memefolder is an app that lets you find anything in your '
            'memefolder! how convenient.',
            style: TextStyle(fontSize: 14, color: cs.onSurface),
          ),
          const SizedBox(height: 4),
          Text(
            'use contextual queries to find what you need, '
            'narrow it down using tags\n'
            'try it out!\n'
            '\np.s. contextual search is disabled, '
            'as you haven\'t isntalled a model for it yet.',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          _buildTutorialSearchBar(cs),
          const SizedBox(height: 8),
          Text(
            'folder preview',
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'Syne',
              fontVariations: const [FontVariation('wght', 600)],
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          _buildFakeFolderRow(cs, files: filtered),
        ],
      ),
    );
  }

  Widget _buildTutorialSearchBar(ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _TutorialAutocompleteField(
          controller: _searchCtrl,
          focusNode: _searchFocus,
          suggestions: _tutorialSuggestions,
          onChanged: (q) => setState(() => _searchQuery = q),
        ),
      ],
    );
  }

  Widget _buildFakeFolderRow(
    ColorScheme cs, {
    bool indexed = false,
    List<_FakeFile>? files,
    bool showIndex = false,
  }) {
    final items = files ?? _fakeFiles;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withAlpha(60),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.onSurface.withAlpha(20)),
      ),
      child: Column(
        mainAxisSize: .min,
        spacing: 12,
        crossAxisAlignment: .end,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: items
                .map((f) => _buildFakeGridTile(cs, f, indexed))
                .toList(),
          ),
          if (showIndex) _buildIndexButton(cs),
        ],
      ),
    );
  }

  Widget _buildFakeGridTile(ColorScheme cs, _FakeFile file, bool indexed) {
    const previewSize = 64.0;
    return SizedBox(
      width: 96,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: previewSize,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildFakePreview(cs, file),
                if (indexed) const IndexedBadge(),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            file.name,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: cs.onSurface),
          ),
        ],
      ),
    );
  }

  Widget _buildFakePreview(ColorScheme cs, _FakeFile file) {
    if (file.type == 'video') {
      final bg = DecoratedBox(
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(Icons.movie, color: cs.onSurfaceVariant, size: 48),
      );

      return Stack(
        fit: StackFit.expand,
        children: [
          bg,
          Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.45),
                shape: BoxShape.circle,
              ),
              child: const Padding(
                padding: EdgeInsets.all(5),
                child: Icon(Icons.play_arrow, color: Colors.white, size: 18),
              ),
            ),
          ),
        ],
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(
        file.type == 'image' ? Icons.image : Icons.audio_file,
        color: cs.onSurfaceVariant,
        size: 48,
      ),
    );
  }

  Widget _buildSlide2() {
    final cs = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'before you can search anything in the folder, '
            'you must index it',
            style: TextStyle(
              fontSize: 18,
              fontFamily: 'Syne',
              color: cs.onSurface,
              fontVariations: const [
                FontVariation('wdth', 2800),
                FontVariation('wght', 700),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'this lets you find stuff in your folder mega fast',
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 48),
          _buildFakeFolderRow(cs, indexed: _indexed, showIndex: true),
          const SizedBox(height: 6),
          Center(
            child: Text(
              _isIndexing
                  ? 'indexing & embedding...'
                  : _indexed
                  ? '\u2713 5 files indexed successfully'
                  : 'tap the index button to see how it works',
              style: TextStyle(
                fontSize: 11,
                color: _indexed ? cs.primary : cs.onSurfaceVariant,
                fontFamily: _indexed ? 'Syne' : null,
                fontVariations: _indexed
                    ? const [FontVariation('wght', 600)]
                    : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIndexButton(ColorScheme cs) {
    return MorphingIndexFab(
      isReindexing: _isIndexing,
      indexProgress: _fakeProgress,
      indexProgressText: _fakeProgressText,
      visibleToggles: const {'unprocessed', 'clip', 'clap'},
      onCancel: () {
        if (_isIndexing) {
          setState(() {
            _isIndexing = false;
            _fakeProgress = 0;
            _fakeProgressText = '';
          });
        }
      },
      onRun: (options) {
        if (!_indexed) _startFakeIndex();
      },
    );
  }

  void _startFakeIndex() {
    setState(() {
      _isIndexing = true;
      _fakeProgress = 0;
      _fakeProgressText = 'scanning files...';
    });
    // simulate multi-step indexing with progress updates
    final steps = [
      (0.15, 'scanning files...'),
      (0.30, 'indexing 1/5...'),
      (0.433, 'embedding 1/5...'),
      (0.682, 'embedding 2/5...'),
      (0.792, 'embedding 3/5...'),
      (0.921, 'embedding 4/5...'),
    ];
    var i = 0;
    void tick() {
      if (!mounted || i >= steps.length) {
        if (mounted) {
          setState(() {
            _isIndexing = false;
            _indexed = true;
            _fakeProgress = 0;
            _fakeProgressText = '';
          });
        }
        return;
      }
      Future.delayed(Duration(milliseconds: Random().nextInt(300) + 500), () {
        if (mounted) {
          setState(() {
            _fakeProgress = steps[i].$1;
            _fakeProgressText = steps[i].$2;
          });
          i++;
          tick();
        }
      });
    }

    tick();
  }

  Widget _buildSlide3() {
    final cs = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'lastly, you must download the models themselves '
            'to use the app',
            style: TextStyle(
              fontSize: 18,
              fontFamily: 'Syne',
              color: cs.onSurface,
              fontVariations: const [
                FontVariation('wdth', 2800),
                FontVariation('wght', 700),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'lite tier models are faster, but have lower accuracy. '
            'full tier is more accurate, but less performant.',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          if (!_loadingSpecs) ...[
            const SizedBox(height: 2),
            Text(
              'i recommend the ${_tierRecommendation == 'lite' ? 'lite' : 'full'} tier '
              'for you.',
              style: TextStyle(
                fontSize: 11,
                color: cs.primary,
                fontFamily: 'Syne',
                fontVariations: const [FontVariation('wght', 600)],
              ),
            ),
          ],
          const SizedBox(height: 8),
          _buildTutorialTierCards(cs),
          const SizedBox(height: 8),
          _buildTutorialModelActions(cs),
        ],
      ),
    );
  }

  Widget _buildTutorialTierCards(ColorScheme cs) {
    const metas = {
      'lite': {
        'label': 'Lite',
        'desc': 'SigLIP vision + text (768d)',
        'clip': '768d',
        'vram': '1.2 GB',
        'ram': '600 MB',
      },
      'mid': {
        'label': 'Mid',
        'desc': 'SigLIP + OCR + Whisper Tiny',
        'clip': '768d',
        'vram': '1.9 GB',
        'ram': '900 MB',
      },
      'full': {
        'label': 'Full',
        'desc': 'SigLIP + CLAP + OCR + Whisper Tiny',
        'clip': '768d',
        'vram': '2.8 GB',
        'ram': '1.4 GB',
      },
    };

    return Row(
      children: ['lite', 'mid', 'full'].map((t) {
        final sel = _tier == t;
        final meta = metas[t]!;
        return Expanded(
          child: GestureDetector(
            onTap: !_modelBusy
                ? () {
                    setState(() => _tier = t);
                    PlayerPrefs.setString('model_tier', t);
                  }
                : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: EdgeInsets.only(right: t != 'full' ? 4 : 0),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: sel
                    ? cs.primary.withAlpha(20)
                    : cs.surfaceContainerHighest.withAlpha(60),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: sel ? cs.primary : Colors.transparent,
                  width: 1.5,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        sel
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        size: 11,
                        color: sel ? cs.primary : cs.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        meta['label'] as String,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                          color: sel ? cs.primary : cs.onSurface,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    meta['desc'] as String,
                    style: TextStyle(fontSize: 8, color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      _usageChip(cs, Icons.memory, 'VRAM ${meta['vram']}'),
                      const SizedBox(width: 2),
                      _usageChip(cs, Icons.storage, 'RAM ${meta['ram']}'),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _usageChip(ColorScheme cs, IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 7, color: cs.primary),
          const SizedBox(width: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 6,
              color: cs.onSurfaceVariant,
              fontFamily: 'Hack',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTutorialModelActions(ColorScheme cs) {
    return Column(
      children: [
        _actionBtn(
          cs,
          Icons.download,
          'Download ${tierMeta[_tier]!['label']} Models',
          _modelBusy
              ? null
              : () => _downloadModels(tierMeta[_tier]!['remoteUrl']!),
          cs.primary,
        ),
        const SizedBox(height: 6),
        DropTarget(
          onDragEntered: (_) {
            if (!_modelBusy) setState(() => _dragHoveringZip = true);
          },
          onDragExited: (_) {
            if (_dragHoveringZip) setState(() => _dragHoveringZip = false);
          },
          onDragDone: (details) async {
            setState(() => _dragHoveringZip = false);
            final f = details.files.firstOrNull;
            if (f == null || !f.name.endsWith('.zip')) return;
            _extractZip(await f.readAsBytes());
          },
          child: GestureDetector(
            onTap: _modelBusy ? null : () => _uploadZip(),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              decoration: BoxDecoration(
                color: _dragHoveringZip
                    ? cs.primary.withValues(alpha: 0.08)
                    : cs.surfaceContainerHighest.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(8),
              ),
              child: DottedBorder(
                options: RoundedRectDottedBorderOptions(
                  dashPattern: const [6, 3],
                  strokeWidth: 1.5,
                  color: _dragHoveringZip
                      ? cs.primary
                      : cs.onSurfaceVariant.withValues(alpha: 0.45),
                  radius: const Radius.circular(8),
                ),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    children: [
                      Icon(
                        Icons.cloud_upload_outlined,
                        size: 16,
                        color: _dragHoveringZip
                            ? cs.primary
                            : cs.onSurfaceVariant.withValues(alpha: 0.7),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        "drag 'n' drop a .zip file here, or tap to browse",
                        style: TextStyle(
                          fontSize: 8.5,
                          color: _dragHoveringZip
                              ? cs.primary
                              : cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (_modelBusy && _modelProgress > 0) ...[
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(value: _modelProgress, minHeight: 2),
          ),
        ],
        if (_modelStatus != null) ...[
          const SizedBox(height: 2),
          Text(
            _modelStatus!,
            style: TextStyle(fontSize: 8, color: cs.onSurfaceVariant),
          ),
        ],
      ],
    );
  }

  Widget _actionBtn(
    ColorScheme cs,
    IconData icon,
    String label,
    VoidCallback? onTap,
    Color color,
  ) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.tonal(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 6),
          backgroundColor: color.withAlpha(25),
          foregroundColor: color,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 11),
            const SizedBox(width: 3),
            Text(label, style: const TextStyle(fontSize: 9.5)),
          ],
        ),
      ),
    );
  }

  Future<void> _downloadModels(String url) async {
    setState(() {
      _modelBusy = true;
      _modelProgress = 0;
      _modelStatus = 'Downloading $_tier models...';
    });

    try {
      final request = http.Request('GET', Uri.parse(url));
      final response = await http.Client().send(request);
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final total = response.contentLength ?? 0;
      var received = 0;
      final chunks = <int>[];
      await for (final chunk in response.stream) {
        chunks.addAll(chunk);
        received += chunk.length;
        if (total > 0 && mounted) {
          setState(() => _modelProgress = received / total);
        }
      }
      final bytes = Uint8List.fromList(chunks);
      await _extractZip(bytes);
    } catch (e) {
      if (mounted) {
        setState(() {
          _modelBusy = false;
          _modelStatus = 'Download failed: $e';
        });
      }
    }
  }

  Future<void> _uploadZip({Uint8List? bytes}) async {
    Uint8List data;
    if (bytes != null) {
      data = bytes;
    } else {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );
      if (result == null || result.files.isEmpty) return;
      setState(() {
        _modelBusy = true;
        _modelProgress = 0;
        _modelStatus = 'Extracting...';
      });
      try {
        data =
            result.files.single.bytes ??
            await File(result.files.single.path!).readAsBytes();
      } catch (e) {
        if (mounted) {
          setState(() {
            _modelBusy = false;
            _modelStatus = 'Failed: $e';
          });
        }
        return;
      }
    }
    await _extractZip(data);
  }

  Future<void> _extractZip(Uint8List bytes) async {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final tierDir = Directory(p.join(_basePath, _tier));
      if (!await tierDir.exists()) await tierDir.create(recursive: true);

      var extracted = 0;
      final total = archive.length;
      final firstFile = archive.firstWhere(
        (e) => e.isFile,
        orElse: () => archive.first,
      );
      final firstParts = firstFile.name.split('/');
      final stripTop =
          firstParts.length > 2 &&
          [
            'clip',
            'clap',
            'ocr',
            'whisper',
            'manifest.yaml',
          ].contains(firstParts[1]);

      for (final entry in archive) {
        if (entry.isFile) {
          final relPath = stripTop
              ? entry.name.split('/').sublist(1).join('/')
              : entry.name;
          final outPath = p.join(_basePath, _tier, relPath);
          final outFile = File(outPath);
          await outFile.create(recursive: true);
          await outFile.writeAsBytes(entry.content);
        }
        extracted++;
        if (mounted) {
          setState(() => _modelProgress = total > 0 ? extracted / total : 0);
        }
      }

      if (mounted) {
        setState(() {
          _modelBusy = false;
          _modelStatus = '${_tier.toUpperCase()} models ready';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _modelBusy = false;
          _modelStatus = 'Extraction failed: $e';
        });
      }
    }
  }

  Widget _buildSlide4() {
    final cs = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: .max,
        children: [
          const SizedBox(height: 8),
          Icon(Ionicons.checkmark_circle_sharp, size: 40, color: cs.primary),
          const SizedBox(height: 8),
          Text(
            'you\'re all set!',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 22,
              fontFamily: 'Syne',
              color: cs.onSurface,
              fontVariations: const [
                FontVariation('wdth', 2800),
                FontVariation('wght', 700),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'you now know how to use memefolder.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: cs.onSurface),
          ),
          const SizedBox(height: 4),
          Text(
            'index your folders, download the models, '
            'and start searching!',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 92),
          Image(
            image: ExactAssetImage("Assets/Images/AntumbraHappy.png"),
            height: 256,
          ),
        ],
      ),
    );
  }

  Widget _buildNavigation(ColorScheme cs) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        if (_currentSlide > 0)
          getButton(
            const Text('back', style: TextStyle(fontSize: 12)),
            () => _goToSlide(_currentSlide - 1),
            cs.primary,
            padding: const EdgeInsets.symmetric(horizontal: 10),
          )
        else
          getButton(
            const Text('skip tutorial', style: TextStyle(fontSize: 12)),
            widget.onFinish,
            cs.primary,
            padding: const EdgeInsets.symmetric(horizontal: 10),
          ),
        const Spacer(),
        if (_currentSlide < 4)
          getButton(
            Text(
              _currentSlide == 0 ? 'next' : 'got it, continue',
              style: const TextStyle(fontSize: 12),
            ),
            () => _goToSlide(_currentSlide + 1),
            cs.primary,
            filled: true,
            padding: const EdgeInsets.symmetric(horizontal: 10),
          )
        else
          getButton(
            const Text('finish', style: TextStyle(fontSize: 12)),
            widget.onFinish,
            cs.primary,
            filled: true,
            padding: const EdgeInsets.symmetric(horizontal: 10),
          ),
      ],
    );
  }
}

class _TutorialAutocompleteField extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final List<String> suggestions;
  final ValueChanged<String> onChanged;

  const _TutorialAutocompleteField({
    required this.controller,
    required this.focusNode,
    required this.suggestions,
    required this.onChanged,
  });

  @override
  State<_TutorialAutocompleteField> createState() =>
      _TutorialAutocompleteFieldState();
}

class _TutorialAutocompleteFieldState
    extends State<_TutorialAutocompleteField> {
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlay;
  List<String> _filtered = [];

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
    widget.focusNode.addListener(() {
      if (!widget.focusNode.hasFocus) _removeOverlay();
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _removeOverlay();
    super.dispose();
  }

  Color _colorFor(String s) {
    if (s == '&') return const Color(0xFFAE4393);
    if (s == '|') return const Color(0xFF8AD4E4);
    if (s == '!') return const Color(0xFFB01B00);
    if (s == '(' || s == ')') return const Color(0xFFAB5C74);
    return const Color(0xFFB1F024);
  }

  void _insertSuggestion(String s) {
    widget.controller.text = s;
    widget.controller.selection = TextSelection.collapsed(offset: s.length);
    widget.onChanged(s);
    _removeOverlay();
    widget.focusNode.unfocus();
  }

  void _onTextChanged() {
    final text = widget.controller.text;
    widget.onChanged(text);

    if (!widget.focusNode.hasFocus || text.isEmpty) {
      _removeOverlay();
      return;
    }

    final lower = text.toLowerCase();
    _filtered = widget.suggestions
        .where((s) => s.toLowerCase().startsWith(lower))
        .toList();

    if (_filtered.isEmpty) {
      _removeOverlay();
    } else {
      _showOverlay();
    }
  }

  void _showOverlay() {
    _removeOverlay();
    _overlay = OverlayEntry(
      builder: (_) => CompositedTransformFollower(
        link: _layerLink,
        showWhenUnlinked: false,
        offset: const Offset(0, 34),
        child: UnconstrainedBox(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 180,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: _filtered.map((s) {
                  final c = _colorFor(s);
                  return InkWell(
                    onTap: () => _insertSuggestion(s),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: c,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            s,
                            style: TextStyle(
                              fontSize: 10,
                              fontFamily: 'Syne',
                              fontVariations: const [
                                FontVariation('wght', 600),
                              ],
                              color: c,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_overlay!);
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  void _applyQuery() {
    final t = widget.controller.text;
    widget.onChanged(t);
    _removeOverlay();
    widget.focusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return CompositedTransformTarget(
      link: _layerLink,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: widget.focusNode,
              decoration: newInputDeco(
                context,
              ).copyWith(hintText: '@audio & @video, !@image, (@audio|@video)'),
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface,
                fontFamily: 'Syne',
                fontVariations: const [
                  FontVariation('wdth', 2800),
                  FontVariation('wght', 600),
                ],
              ),
              onTapOutside: (_) => widget.focusNode.unfocus(),
              onSubmitted: (_) => _applyQuery(),
            ),
          ),
          const SizedBox(width: 16),
          FloatingActionButton(
            mini: true,
            onPressed: _applyQuery,
            backgroundColor: Theme.of(context).colorScheme.primary,
            child: Icon(
              Icons.search,
              size: 28,
              color: readableOn(Theme.of(context).colorScheme.primary),
            ),
          ),
        ],
      ),
    );
  }
}
