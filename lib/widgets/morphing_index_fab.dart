import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:gradient_borders/box_borders/gradient_box_border.dart';
import 'package:memefolder/config/theme.dart';
import 'package:memefolder/prefs.dart';

class IndexOptions {
  bool onlyUnprocessed;
  bool enableClip;
  bool enableClap;
  bool enableOcr;
  bool enableWhisper;

  IndexOptions({
    this.onlyUnprocessed = true,
    this.enableClip = true,
    this.enableClap = false,
    this.enableOcr = true,
    this.enableWhisper = true,
  });

  static IndexOptions load() {
    return IndexOptions(
      onlyUnprocessed: PlayerPrefs.getBool('index_only_unprocessed', true),
      enableClip: PlayerPrefs.getBool('index_enable_clip', true),
      enableClap: PlayerPrefs.getBool('index_enable_clap', false),
      enableOcr: PlayerPrefs.getBool('index_enable_ocr', true),
      enableWhisper: PlayerPrefs.getBool('index_enable_whisper', true),
    );
  }

  Future<void> save() async {
    await PlayerPrefs.setBool('index_only_unprocessed', onlyUnprocessed);
    await PlayerPrefs.setBool('index_enable_clip', enableClip);
    await PlayerPrefs.setBool('index_enable_clap', enableClap);
    await PlayerPrefs.setBool('index_enable_ocr', enableOcr);
    await PlayerPrefs.setBool('index_enable_whisper', enableWhisper);
  }
}

class MorphingIndexFab extends StatefulWidget {
  final bool isReindexing;
  final double indexProgress;
  final String indexProgressText;
  final VoidCallback onCancel;
  final ValueChanged<IndexOptions> onRun;
  final VoidCallback? onClose;
  final Set<String>? visibleToggles;

  const MorphingIndexFab({
    super.key,
    required this.isReindexing,
    required this.indexProgress,
    required this.indexProgressText,
    required this.onCancel,
    required this.onRun,
    this.onClose,
    this.visibleToggles,
  });

  @override
  State<MorphingIndexFab> createState() => _MorphingIndexFabState();
}

class _MorphingIndexFabState extends State<MorphingIndexFab> {
  static const double _closedHeight = 56;
  static const double _openWidth = 260;
  static const double _itemHeight = 48;
  static const double _elasticOverflow = 48;
  static const double _sidePadding = 12;

  bool _open = false;
  late IndexOptions _options;

  int get _visibleCount => widget.visibleToggles?.length ?? 5;
  double get _openHeight => (_visibleCount + 1) * _itemHeight + 16;

  TextStyle get _buttonTextStyle => TextStyle(
    fontFamily: "Syne",
    fontVariations: [FontVariation('wdth', 2800), FontVariation('wght', 750)],
  );

  double _measureTextWidth(String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: ui.TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return painter.width;
  }

  double get _closedWidth {
    if (widget.isReindexing) {
      // 48 spinner + 4 gap + text width + 24 padding
      return 48 +
          4 +
          _measureTextWidth(widget.indexProgressText, _buttonTextStyle) +
          _sidePadding * 2;
    }
    // 32 icon + 4 gap + text width + 6 trailing + 24 padding
    return 32 +
        4 +
        _measureTextWidth("index", _buttonTextStyle) +
        6 +
        _sidePadding * 2;
  }

  @override
  void initState() {
    super.initState();
    _options = IndexOptions.load();
  }

  @override
  void didUpdateWidget(MorphingIndexFab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_open && oldWidget.isReindexing != widget.isReindexing) {
      _open = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final duration = const Duration(milliseconds: 300);
    final elasticDuration = const Duration(milliseconds: 1000);

    return Hero(
      tag: 'index-fab',
      child: SizedBox(
        width: _openWidth,
        height: _openHeight,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: _open ? 1 : 0),
          duration: duration,
          curve: Curves.easeInOut,
          builder: (context, smoothValue, child) {
            final smoothProgress = smoothValue.clamp(0.0, 1.0);
            final menuCanTap = _open && smoothProgress > 0.95;
            final buttonCanTap = !_open && smoothProgress < 0.05;
            final blur = math.sin(math.pi * smoothProgress) * 6;

            return TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: _open ? 1 : 0),
              duration: elasticDuration,
              curve: Curves.elasticOut,
              builder: (context, elasticValue, child) {
                final elasticProgress = elasticValue.clamp(0.0, 1.0);
                final width =
                    _closedWidth + (_openWidth - _closedWidth) * elasticValue;
                final height =
                    _closedHeight +
                    (_openHeight - _closedHeight) * elasticValue;
                final radius = 28 - (28 - 12) * elasticProgress;
                final slide = Offset(0, (1 - elasticValue) * 4);

                return OverflowBox(
                  alignment: Alignment.bottomRight,
                  minWidth: 0,
                  maxWidth: _openWidth + _elasticOverflow,
                  minHeight: 0,
                  maxHeight: _openHeight + _elasticOverflow,
                  child: Align(
                    alignment: Alignment.bottomRight,
                    child: Transform.translate(
                      offset: slide,
                      child: SizedBox(
                        width: width,
                        height: height,
                        child: _MorphingFabBody(
                          progress: smoothProgress,
                          color: Color.lerp(
                            cs.primary,
                            cs.surfaceContainerHighest,
                            smoothProgress,
                          )!,
                          borderRadius: BorderRadius.circular(radius),
                          blur: blur,
                          buttonCanTap: buttonCanTap,
                          menuCanTap: menuCanTap,
                          button: _buildButton(context),
                          menu: _buildMenu(context),
                        ),
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildButton(BuildContext context) {
    return InkResponse(
      onTap: widget.isReindexing
          ? widget.onCancel
          : () => setState(() => _open = true),
      containedInkWell: true,
      highlightShape: BoxShape.circle,
      mouseCursor: WidgetStateMouseCursor.clickable,
      radius: _closedHeight * 2,
      splashColor: const Color.fromARGB(10, 255, 255, 255),
      child: Center(
        child: widget.isReindexing
            ? SizedBox(
                height: 36,
                child: Row(
                  mainAxisAlignment: .center,
                  children: [
                    SizedBox(
                      height: 36,
                      width: 36,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          SizedBox(
                            height: 24,
                            width: 24,
                            child: CircularProgressIndicator(
                              value: widget.indexProgress > 0
                                  ? widget.indexProgress
                                  : null,
                              color: readableOn(
                                Theme.of(context).colorScheme.primary,
                              ),
                              strokeWidth: 2,
                            ),
                          ),
                          Icon(
                            Icons.close,
                            size: 16,
                            color: readableOn(
                              Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: 12),
                    Text(
                      widget.indexProgressText,
                      style: TextStyle(
                        fontFamily: "Syne",
                        fontVariations: [
                          FontVariation('wdth', 2800),
                          FontVariation('wght', 750),
                        ],
                        color: readableOn(
                          Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                    SizedBox(width: 6),
                  ],
                ),
              )
            : Row(
                mainAxisAlignment: .center,
                children: [
                  Icon(
                    Icons.refresh,
                    size: 32,
                    color: readableOn(Theme.of(context).colorScheme.primary),
                  ),
                  SizedBox(width: 4),
                  Text(
                    "index",
                    style: TextStyle(
                      fontFamily: "Syne",
                      fontVariations: [
                        FontVariation('wdth', 2800),
                        FontVariation('wght', 750),
                      ],
                      color: readableOn(Theme.of(context).colorScheme.primary),
                    ),
                  ),
                  SizedBox(width: 6),
                ],
              ),
      ),
    );
  }

  Widget _buildMenu(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final vis = widget.visibleToggles;

    final allToggles = [
      ('unprocessed', Icons.filter_alt, 'Only unprocessed', _options.onlyUnprocessed, (bool v) => setState(() => _options.onlyUnprocessed = v)),
      ('clip', Icons.image, 'Image context', _options.enableClip, (bool v) => setState(() => _options.enableClip = v)),
      ('clap', Icons.music_note, 'Audio context', _options.enableClap, (bool v) => setState(() => _options.enableClap = v)),
      ('ocr', Icons.text_fields, 'Image text', _options.enableOcr, (bool v) => setState(() => _options.enableOcr = v)),
      ('whisper', Icons.mic, 'Audio text', _options.enableWhisper, (bool v) => setState(() => _options.enableWhisper = v)),
    ];

    final toggles = vis == null ? allToggles : allToggles.where((t) => vis.contains(t.$1)).toList();

    return Stack(
      alignment: Alignment.bottomRight,
      children: [
        OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: _openWidth,
          maxWidth: _openWidth,
          minHeight: _openHeight,
          maxHeight: _openHeight,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < toggles.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  _buildToggleRow(
                    context,
                    icon: toggles[i].$2,
                    label: toggles[i].$3,
                    value: toggles[i].$4,
                    onChanged: toggles[i].$5,
                  ),
                ],
              ],
            ),
          ),
        ),
        Row(
          mainAxisAlignment: .spaceBetween,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                borderRadius: .circular(8),
                color: Colors.white.withAlpha(10),
              ),
              child: ClipRect(
                child: InkResponse(
                  onTap: () async {
                    await _options.save();
                    setState(() => _open = false);
                  },
                  mouseCursor: WidgetStateMouseCursor.clickable,
                  containedInkWell: true,
                  highlightShape: BoxShape.rectangle,
                  splashColor: const Color.fromARGB(10, 255, 255, 255),
                  child: Row(
                    mainAxisAlignment: .center,
                    spacing: 4,
                    children: [Icon(Icons.close, size: 28, color: cs.primary)],
                  ),
                ),
              ),
            ),
            Container(
              width: 120,
              height: 56,
              decoration: BoxDecoration(
                borderRadius: .circular(8),
                color: Colors.white.withAlpha(10),
              ),
              child: ClipRect(
                child: InkResponse(
                  onTap: () async {
                    await _options.save();
                    setState(() => _open = false);
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      widget.onRun(_options);
                    });
                  },
                  mouseCursor: WidgetStateMouseCursor.clickable,
                  containedInkWell: true,
                  highlightShape: BoxShape.rectangle,
                  splashColor: const Color.fromARGB(10, 255, 255, 255),
                  child: Row(
                    mainAxisAlignment: .center,
                    spacing: 4,
                    children: [
                      Icon(Icons.play_arrow, size: 28, color: cs.primary),
                      Text(
                        "run",
                        style: TextStyle(
                          fontFamily: "Syne",
                          fontVariations: [
                            FontVariation('wdth', 2800),
                            FontVariation('wght', 750),
                          ],
                        ),
                      ),
                      SizedBox(width: 6),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildToggleRow(
    BuildContext context, {
    required IconData icon,
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SizedBox(
      height: _itemHeight,
      child: Row(
        children: [
          const SizedBox(width: 8),
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
          Switch(
            value: value,
            onChanged: onChanged,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

class _MorphingFabBody extends StatelessWidget {
  final double progress;
  final Color color;
  final BorderRadius borderRadius;
  final double blur;
  final bool buttonCanTap;
  final bool menuCanTap;
  final Widget button;
  final Widget menu;

  const _MorphingFabBody({
    required this.progress,
    required this.color,
    required this.borderRadius,
    required this.blur,
    required this.buttonCanTap,
    required this.menuCanTap,
    required this.button,
    required this.menu,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(45),
            offset: const Offset(0, 8),
            blurRadius: 24,
            spreadRadius: -2,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.9),
              borderRadius: borderRadius,
              border: GradientBoxBorder(
                gradient: RadialGradient(
                  center: Alignment.topLeft,
                  radius: 2,
                  colors: [
                    cs.outlineVariant.withAlpha((20 * progress).toInt()),
                    cs.outlineVariant.withAlpha((90 * progress).toInt()),
                  ],
                ),
                width: 1.5,
              ),
            ),
            child: Material(
              color: Colors.transparent,
              child: ImageFiltered(
                enabled: blur > 0,
                imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    IgnorePointer(
                      ignoring: !buttonCanTap,
                      child: Opacity(opacity: 1 - progress, child: button),
                    ),
                    IgnorePointer(
                      ignoring: !menuCanTap,
                      child: Opacity(opacity: progress, child: menu),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
