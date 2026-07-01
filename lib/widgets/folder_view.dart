import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_manager/file_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gradient_borders/gradient_borders.dart';
import 'package:memefolder/backend/indexer.dart';
import 'package:memefolder/config/theme.dart';
import 'package:memefolder/filtering/filtering.dart';
import 'package:memefolder/helpers/styled_inputfields.dart';
import 'package:memefolder/prefs.dart';
import 'package:memefolder/utils/binary_paths.dart';
import 'package:memefolder/widgets/file_badges.dart';
import 'package:memefolder/widgets/morphing_index_fab.dart';
import 'package:path/path.dart' as p;
import 'package:silky_scroll/silky_scroll.dart';

class FileBrowserPane extends StatefulWidget {
  const FileBrowserPane({
    super.key,
    required this.currentPath,
    required this.pathController,
    required this.isGrid,
    required this.folderScale,
    required this.canGoBack,
    required this.canGoForward,
    required this.onBack,
    required this.onForward,
    required this.onUp,
    required this.onToggleGrid,
    required this.onScaleChanged,
    required this.onNavigate,
    required this.onRefresh,
    required this.onSelectedFileChanged,
  });

  final String currentPath;
  final TextEditingController pathController;
  final bool isGrid;
  final double folderScale;
  final bool canGoBack;
  final bool canGoForward;
  final VoidCallback onBack;
  final VoidCallback onForward;
  final VoidCallback onUp;
  final VoidCallback onToggleGrid;
  final ValueChanged<double> onScaleChanged;
  final ValueChanged<String> onNavigate;
  final VoidCallback onRefresh;
  final ValueChanged<File?> onSelectedFileChanged;

  @override
  State<FileBrowserPane> createState() => _FileBrowserPaneState();
}

class _FileBrowserPaneState extends State<FileBrowserPane> {
  String? _hoveredPath;
  String? _selectedPath;
  String? _lastPressedPath;
  DateTime? _lastPressedAt;
  late Future<IndexStatus> _indexedFilesFuture;
  final Map<String, Future<File?>> _videoThumbnailFutures = {};
  int _thumbnailSlots = 2;
  final Queue<Completer<void>> _thumbnailWaiters = Queue();
  bool _thumbnailQueueCancelled = false;
  ValueNotifier<bool> isReindexing = ValueNotifier(false);
  ValueNotifier<double> indexProgress = ValueNotifier(0.0);
  ValueNotifier<String> indexProgressText = ValueNotifier('');
  CancellationToken? _cancelToken;

  List<FileSystemEntity> _loadedEntities = [];
  bool _isLoadingEntities = true;
  int _totalEntityCount = 0;
  StreamSubscription<FileSystemEntity>? _dirSub;

  List<String> _suggestions = [];
  int _selectedSuggestionIndex = -1;
  final LayerLink _pathBarLink = LayerLink();
  OverlayEntry? _suggestionsOverlay;

  @override
  void initState() {
    super.initState();
    FilterService.instance.addListener(_onFilterChanged);
    _loadData();
  }

  @override
  void dispose() {
    FilterService.instance.removeListener(_onFilterChanged);
    _dirSub?.cancel();
    _thumbnailQueueCancelled = true;
    while (_thumbnailWaiters.isNotEmpty) {
      _thumbnailWaiters.removeFirst().complete();
    }
    _removeSuggestionsOverlay();
    _hoveredPath = null;
    super.dispose();
  }

  void _onFilterChanged() {
    _loadData();
  }

  Future<void> _loadData() async {
    _dirSub?.cancel();
    _thumbnailQueueCancelled = true;
    while (_thumbnailWaiters.isNotEmpty) {
      _thumbnailWaiters.removeFirst().complete();
    }
    _thumbnailSlots = 2;
    _thumbnailQueueCancelled = false;
    _loadedEntities = [];
    _isLoadingEntities = true;
    if (mounted) setState(() {});

    final isActive = FilterService.instance.isActive;
    if (isActive) {
      final root = PlayerPrefs.getString("main_folder");
      if (root.isNotEmpty) {
        final filter = FilterService.instance;
        final paths = await filter.execute(root);
        final scores = filter.scores;
        final sorted = paths.toList()
          ..sort((a, b) => (scores[b] ?? 0).compareTo(scores[a] ?? 0));
        if (mounted) {
          setState(() {
            _loadedEntities = sorted
                .map((p) => File(p))
                .where((e) => !p.basename(e.path).startsWith('.'))
                .toList();
            _isLoadingEntities = false;
          });
        }
      } else {
        if (mounted) setState(() => _isLoadingEntities = false);
      }
    } else {
      _loadDirectoryData();
    }
    _indexedFilesFuture = getIndexedFiles(widget.currentPath);
  }

  void _loadDirectoryData() {
    final collected = <FileSystemEntity>[];
    _totalEntityCount = 0;
    _isLoadingEntities = true;
    _countTotalEntities(widget.currentPath);

    _dirSub = Directory(widget.currentPath).list().listen(
      (entity) {
        if (p.basename(entity.path).startsWith('.')) return;
        collected.add(entity);
      },
      onDone: () {
        _loadedEntities = collected;
        _sortLoadedEntities();
        if (mounted) {
          setState(() {
            _isLoadingEntities = false;
          });
        }
      },
      onError: (_) {
        _loadedEntities = collected;
        _sortLoadedEntities();
        if (mounted) {
          setState(() {
            _isLoadingEntities = false;
          });
        }
      },
    );
  }

  Future<void> _countTotalEntities(String path) async {
    int count = 0;
    try {
      await for (final entity in Directory(path).list()) {
        if (!p.basename(entity.path).startsWith('.')) count++;
      }
    } catch (_) {}
    if (mounted) setState(() => _totalEntityCount = count);
  }

  void _sortLoadedEntities() {
    if (FilterService.instance.isActive) return;
    _loadedEntities.sort((a, b) {
      final aIsDir = FileManager.isDirectory(a);
      final bIsDir = FileManager.isDirectory(b);
      if (aIsDir != bIsDir) return aIsDir ? -1 : 1;
      return p
          .basename(a.path)
          .toLowerCase()
          .compareTo(p.basename(b.path).toLowerCase());
    });
  }

  Widget _buildLoadingBar() {
    final progress = _totalEntityCount > 0
        ? (_loadedEntities.length / _totalEntityCount).clamp(0.0, 1.0)
        : null;
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(value: progress),
          if (_totalEntityCount > 0)
            Padding(
              padding: EdgeInsets.only(top: 2),
              child: Text(
                '${_loadedEntities.length} / $_totalEntityCount',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  void didUpdateWidget(covariant FileBrowserPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentPath != widget.currentPath) {
      _hoveredPath = null;
      _selectedPath = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onSelectedFileChanged(null);
      });
      _loadData();
    }
  }

  void _updateSuggestions(String value) {
    _removeSuggestionsOverlay();
    if (value.isEmpty) {
      setState(() => _suggestions = []);
      return;
    }

    final lastSlash = value.lastIndexOf('/');
    if (lastSlash < 0) {
      setState(() => _suggestions = []);
      return;
    }

    final parentPath = value.substring(0, lastSlash == 0 ? 1 : lastSlash);
    final prefix = value.substring(lastSlash + 1).toLowerCase();

    final parentDir = Directory(parentPath);
    if (!parentDir.existsSync()) {
      setState(() => _suggestions = []);
      return;
    }

    try {
      final matches = parentDir
          .listSync()
          .whereType<Directory>()
          .map((d) => d.uri.pathSegments.where((s) => s.isNotEmpty).last)
          .where((name) => name.toLowerCase().startsWith(prefix))
          .take(5)
          .toList();

      setState(() {
        _suggestions = matches;
        _selectedSuggestionIndex = -1;
      });

      if (_suggestions.isNotEmpty) {
        _showSuggestionsOverlay();
      }
    } catch (_) {
      setState(() => _suggestions = []);
    }
  }

  void _showSuggestionsOverlay() {
    _removeSuggestionsOverlay();
    _suggestionsOverlay = OverlayEntry(
      builder: (context) => _SuggestionsPopup(
        link: _pathBarLink,
        suggestions: _suggestions,
        selectedIndex: _selectedSuggestionIndex,
        onTap: (index) => _applySuggestion(index),
      ),
    );
    Overlay.of(context).insert(_suggestionsOverlay!);
  }

  void _removeSuggestionsOverlay() {
    _suggestionsOverlay?.remove();
    _suggestionsOverlay = null;
  }

  void _applySuggestion(int index) {
    if (index < 0 || index >= _suggestions.length) return;
    final current = widget.pathController.text;
    final lastSlash = current.lastIndexOf('/');
    final parentPath = current.substring(0, lastSlash < 0 ? 0 : lastSlash);
    final suggestion = _suggestions[index];
    final newPath = '$parentPath/$suggestion';

    widget.pathController.text = newPath;
    widget.pathController.selection = TextSelection.fromPosition(
      TextPosition(offset: newPath.length),
    );

    _removeSuggestionsOverlay();
    setState(() => _suggestions = []);
    widget.onNavigate(newPath);
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (_suggestions.isEmpty) return false;

    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        setState(() {
          _selectedSuggestionIndex = (_selectedSuggestionIndex + 1).clamp(
            0,
            _suggestions.length - 1,
          );
        });
        _suggestionsOverlay?.markNeedsBuild();
        return true;
      } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        setState(() {
          _selectedSuggestionIndex = (_selectedSuggestionIndex - 1).clamp(
            0,
            _suggestions.length - 1,
          );
        });
        _suggestionsOverlay?.markNeedsBuild();
        return true;
      } else if (event.logicalKey == LogicalKeyboardKey.escape) {
        _removeSuggestionsOverlay();
        setState(() => _suggestions = []);
        return true;
      }
    }
    return false;
  }

  void _handleItemPointerDown(FileSystemEntity entity, bool isDir) {
    final now = DateTime.now();
    final isDoublePress =
        _lastPressedPath == entity.path &&
        _lastPressedAt != null &&
        now.difference(_lastPressedAt!) < const Duration(milliseconds: 320);

    _lastPressedPath = entity.path;
    _lastPressedAt = now;

    if (isDoublePress && isDir) {
      widget.onNavigate(entity.path);
      _lastPressedPath = null;
      _lastPressedAt = null;
    } else {
      setState(() {
        _selectedPath = entity.path;
      });
      widget.onSelectedFileChanged(isDir ? null : File(entity.path));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: cs.surfaceContainerHighest.withValues(alpha: 0.72),
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        flexibleSpace: ClipRect(
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: const SizedBox.expand(),
          ),
        ),
        title: Row(
          children: [
            IconButton(
              onPressed: widget.canGoBack ? widget.onBack : null,
              icon: const Icon(Icons.chevron_left),
            ),
            IconButton(
              onPressed: widget.canGoForward ? widget.onForward : null,
              icon: const Icon(Icons.chevron_right),
            ),
            IconButton(
              onPressed: widget.onUp,
              icon: const Icon(Icons.arrow_upward),
            ),
            IconButton(
              onPressed: widget.onToggleGrid,
              icon: Icon(widget.isGrid ? Icons.list : Icons.grid_view),
            ),
            SizedBox(
              width: 140,
              child: Slider(
                value: widget.folderScale,
                onChanged: widget.onScaleChanged,
                divisions: 8,
              ),
            ),
            Expanded(
              child: CompositedTransformTarget(
                link: _pathBarLink,
                child: KeyboardListener(
                  focusNode: FocusNode(),
                  onKeyEvent: _handleKeyEvent,
                  child: TextField(
                    decoration: newInputDeco(context).copyWith(
                      hintText: "path",
                      prefixIcon: ValueListenableBuilder(
                        valueListenable: widget.pathController,
                        builder: (context, value, child) {
                          return Directory(
                                widget.pathController.text,
                              ).existsSync()
                              ? Icon(Icons.folder)
                              : Icon(Icons.warning);
                        },
                      ),
                    ),
                    style: newInputStyle(context),
                    controller: widget.pathController,
                    onChanged: _updateSuggestions,
                    onSubmitted: (value) {
                      if (_selectedSuggestionIndex >= 0 &&
                          _selectedSuggestionIndex < _suggestions.length) {
                        _applySuggestion(_selectedSuggestionIndex);
                      } else {
                        _removeSuggestionsOverlay();
                        setState(() => _suggestions = []);
                        widget.onNavigate(value);
                      }
                    },
                    onTapOutside: (_) {
                      _removeSuggestionsOverlay();
                      setState(() => _suggestions = []);
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.03, 0),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        ),
        child: FutureBuilder<IndexStatus>(
          key: ValueKey(
            "${widget.currentPath}-${widget.isGrid}-${widget.folderScale}",
          ),
          future: _indexedFilesFuture,
          builder: (context, indexedSnapshot) => SilkyScroll(
            builder: (context, controller, physics, pointerDeviceKind) {

              if (_isLoadingEntities && _loadedEntities.isEmpty) {
                return const Center(child: CircularProgressIndicator());
              }

              final entities = _loadedEntities;
              final isFiltering = FilterService.instance.isActive;

              if (entities.isEmpty) {
                if (isFiltering) {
                  final root = PlayerPrefs.getString("main_folder");
                  final dbExists =
                      root.isNotEmpty &&
                      File(p.join(root, '.memefolder.db')).existsSync();
                  return Center(
                    child: Text(
                      dbExists
                          ? "no results"
                          : "(!) please index directory to enable search (!)",
                    ),
                  );
                }
                return const Center(child: Text("Empty Directory"));
              }

              final indexedStatus = indexedSnapshot.data ?? const IndexStatus();
              final indexedFiles = indexedStatus.indexed;
              final failedFiles = indexedStatus.failed;
              final zoom = 0.75 + (widget.folderScale * 1.25);
              final listColumns = 1 + (widget.folderScale * 3).round();
              final gridCellWidth = 88.0 * zoom;
              final gridCellHeight = 120.0 * zoom;
              final iconSize = 44.0 * zoom;
              final listRowHeight = 52.0 * zoom;
              final listIconSize = 28.0 * zoom;
              final labelSize = 11.0 * zoom.clamp(1.0, 1.35);

              if (widget.isGrid) {
                return Stack(
                  children: [
                    GridView.builder(
                      padding: const EdgeInsets.all(8),
                      controller: controller,
                      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: gridCellWidth,
                        mainAxisExtent: gridCellHeight,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                      ),
                      itemCount: entities.length,
                      itemBuilder: (context, index) {
                        final e = entities[index];
                        final isDir = FileManager.isDirectory(e);
                        return _buildGridTile(
                          context: context,
                          isDir: isDir,
                          entity: e,
                          isHovered: _hoveredPath == e.path,
                          isSelected: _selectedPath == e.path,
                          isIndexed:
                              !isDir &&
                              (isFiltering || indexedFiles.contains(e.path)),
                          isFailed: failedFiles.contains(e.path),
                          iconSize: iconSize,
                          gridWidth: gridCellWidth,
                          labelSize: labelSize,
                        );
                      },
                    ),
                    if (_isLoadingEntities) _buildLoadingBar(),
                  ],
                );
              } else {
                return Stack(
                  children: [
                    GridView.builder(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: listColumns,
                        mainAxisExtent: listRowHeight,
                      ),
                      controller: controller,
                      itemCount: entities.length,
                      itemBuilder: (context, index) {
                        final e = entities[index];
                        final isDir = FileManager.isDirectory(e);
                        return _buildListTile(
                          context: context,
                          isDir: isDir,
                          entity: e,
                          isHovered: _hoveredPath == e.path,
                          isSelected: _selectedPath == e.path,
                          isIndexed:
                              !isDir &&
                              (isFiltering || indexedFiles.contains(e.path)),
                          isFailed: failedFiles.contains(e.path),
                          iconSize: listIconSize,
                        );
                      },
                    ),
                    if (_isLoadingEntities) _buildLoadingBar(),
                  ],
                );
              }
            },
          ),
        ),
      ),
      floatingActionButton: ValueListenableBuilder<bool>(
        valueListenable: isReindexing,
        builder: (context, reindexing, _) => ValueListenableBuilder<double>(
          valueListenable: indexProgress,
          builder: (context, progress, _) => ValueListenableBuilder<String>(
            valueListenable: indexProgressText,
            builder: (context, progressText, _) => MorphingIndexFab(
              isReindexing: reindexing,
              indexProgress: progress,
              indexProgressText: progressText,
              onCancel: () {
                _cancelToken?.cancel();
              },
              onRun: (options) async {
                _cancelToken = CancellationToken();
                isReindexing.value = true;
                indexProgress.value = 0;
                indexProgressText.value = 'indexing...';
                await indexDirectory(
                  widget.currentPath,
                  onProgress: (text, p) {
                    indexProgress.value = p;
                    indexProgressText.value = text;
                  },
                  cancelToken: _cancelToken,
                  options: options,
                );
                _indexedFilesFuture = getIndexedFiles(widget.currentPath);
                _loadDirectoryData();
                indexProgress.value = 0;
                indexProgressText.value = '';
                isReindexing.value = false;
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGridTile({
    required BuildContext context,
    required bool isDir,
    required FileSystemEntity entity,
    required bool isHovered,
    required bool isSelected,
    required bool isIndexed,
    required bool isFailed,
    required double iconSize,
    required double gridWidth,
    required double labelSize,
  }) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredPath = entity.path),
      onExit: (_) {
        if (_hoveredPath == entity.path) setState(() => _hoveredPath = null);
      },
      child: _GradientHoverOutline(
        isHovered: isHovered,
        isSelected: isSelected,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (_) => _handleItemPointerDown(entity, isDir),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: EdgeInsets.only(
                top: (gridWidth - iconSize) / 4 + 1,
                left: 4,
                right: 4,
                bottom: 4,
              ),
              child: Column(
                children: [
                  _buildPreview(
                    context: context,
                    entity: entity,
                    isDir: isDir,
                    size: iconSize * 1.45,
                    iconSize: iconSize,
                    isIndexed: isIndexed,
                    isFailed: isFailed,
                  ),
                  const SizedBox(height: 4),
                  Expanded(
                    child: Text(
                      p.basename(entity.path),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: labelSize),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildListTile({
    required BuildContext context,
    required bool isDir,
    required FileSystemEntity entity,
    required bool isHovered,
    required bool isSelected,
    required bool isIndexed,
    required bool isFailed,
    required double iconSize,
  }) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredPath = entity.path),
      onExit: (_) {
        if (_hoveredPath == entity.path) setState(() => _hoveredPath = null);
      },
      child: _GradientHoverOutline(
        isHovered: isHovered,
        isSelected: isSelected,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (_) => _handleItemPointerDown(entity, isDir),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            child: ListTile(
              dense: true,
              leading: _buildPreview(
                context: context,
                entity: entity,
                isDir: isDir,
                size: iconSize * 1.45,
                iconSize: iconSize,
                isIndexed: isIndexed,
                isFailed: isFailed,
              ),
              title: Text(
                p.basename(entity.path),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPreview({
    required BuildContext context,
    required FileSystemEntity entity,
    required bool isDir,
    required bool isIndexed,
    required bool isFailed,
    required double size,
    required double iconSize,
  }) {
    final fs = FilterService.instance;
    final score = fs.scores[entity.path];
    final space = fs.searchSpace;

    if (isDir) {
      return ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (Rect bounds) => LinearGradient(
          stops: [0, 1],
          begin: .bottomRight,
          end: .topLeft,
          colors: [
            Theme.of(context).colorScheme.primary,
            Color.lerp(
              Theme.of(context).colorScheme.primary,
              Colors.white,
              0.5,
            )!,
          ],
        ).createShader(bounds),
        child: Icon(Icons.folder, size: iconSize),
      );
    }

    final kind = _previewKind(entity.path);
    final preview = SizedBox.square(
      dimension: size,
      child: switch (kind) {
        _PreviewKind.image => _ImagePreview(file: File(entity.path)),
        _PreviewKind.gif => Stack(
          fit: StackFit.expand,
          children: [
            _ImagePreview(file: File(entity.path)),
            const _PreviewBadge(label: "GIF"),
          ],
        ),
        _PreviewKind.video => _VideoPreview(
          file: File(entity.path),
          thumbnail: _videoThumbnailFutures.putIfAbsent(
            entity.path,
            () => _loadVideoThumbnail(entity.path),
          ),
        ),
        _PreviewKind.file => Icon(Icons.insert_drive_file, size: iconSize),
      },
    );

    final badges = <Widget>[];
    if (isFailed) badges.add(const _FailedBadge());
    if (isIndexed && !isFailed) badges.add(const IndexedBadge());
    if (score != null) {
      badges.add(_ScoreBadge(score: score, label: space.label));
    }

    if (badges.isNotEmpty) {
      return SizedBox.square(
        dimension: size,
        child: Stack(
          fit: StackFit.expand,
          children: [preview, ...badges.reversed],
        ),
      );
    }

    return preview;
  }

  _PreviewKind _previewKind(String path) {
    final ext = path.split('.').last.toLowerCase();
    if (ext == 'gif') return _PreviewKind.gif;
    if (_imageExtensions.contains(ext)) return _PreviewKind.image;
    if (_videoExtensions.contains(ext)) return _PreviewKind.video;
    return _PreviewKind.file;
  }

  Future<File?> _loadVideoThumbnail(String path) async {
    final safeName = path.hashCode.toUnsigned(32).toRadixString(16);
    final thumb = File('${Directory.systemTemp.path}/memefolder-$safeName.png');
    if (await thumb.exists()) return thumb;

    await _acquireThumbnailSlot();
    if (await thumb.exists()) {
      _releaseThumbnailSlot();
      return thumb;
    }

    try {
      final result = await Process.run(ffmpegPath, [
        '-y',
        '-hwaccel', 'auto',
        '-ss',
        '00:00:01',
        '-i',
        path,
        '-frames:v',
        '1',
        '-vf',
        'scale=160:-1',
        thumb.path,
      ]);
      if (result.exitCode == 0 && await thumb.exists()) return thumb;
    } catch (_) {
      return null;
    } finally {
      _releaseThumbnailSlot();
    }

    return null;
  }

  Future<void> _acquireThumbnailSlot() async {
    if (_thumbnailQueueCancelled) return;
    if (_thumbnailSlots > 0) {
      _thumbnailSlots--;
      return;
    }
    final completer = Completer<void>();
    _thumbnailWaiters.add(completer);
    return completer.future;
  }

  void _releaseThumbnailSlot() {
    if (_thumbnailWaiters.isNotEmpty) {
      _thumbnailWaiters.removeFirst().complete();
    } else {
      _thumbnailSlots++;
    }
  }
}

enum _PreviewKind { image, gif, video, file }

const _imageExtensions = {
  'jpg',
  'jpeg',
  'png',
  'webp',
  'bmp',
  'wbmp',
  'heic',
  'heif',
};

const _videoExtensions = {
  'mp4',
  'm4v',
  'mov',
  'webm',
  'mkv',
  'avi',
  'wmv',
  'flv',
  'mpeg',
  'mpg',
};

class _ImagePreview extends StatelessWidget {
  const _ImagePreview({required this.file});

  final File file;
  static final Map<String, Future<(int, int)>> _sizeFutures = {};

  static Future<(int, int)> _loadSize(File file) async {
    try {
      final decodedImage = await decodeImageFromList(await file.readAsBytes());
      final size = (decodedImage.width, decodedImage.height);
      decodedImage.dispose();
      return size;
    } catch (e) {
      debugPrint("an error occurred during imagegen: $e");
    }
    return (-1, -1);
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),

      child: FutureBuilder<(int, int)>(
        future: _sizeFutures.putIfAbsent(file.path, () => _loadSize(file)),
        builder: (context, snapshot) {
          final size = snapshot.data;
          if (size == null) {
            return const Center(child: SizedBox.square(dimension: 12));
          }

          if (size.$1 <= 0 || size.$2 <= 0) {
            return CircularProgressIndicator();
          }
          (int, int) smallsize = size.$1 > size.$2
              ? ((size.$1 / size.$2 * 64).toInt(), 64)
              : (64, (size.$2 / size.$1 * 64).toInt());

          return AspectRatio(
            aspectRatio: size.$1 / size.$2,
            child: Image.file(
              file,
              fit: BoxFit.cover,
              cacheWidth: smallsize.$1,
              cacheHeight: smallsize.$2,
              filterQuality: FilterQuality.low,
              gaplessPlayback: true,
              errorBuilder: (context, error, stackTrace) =>
                  const Icon(Icons.broken_image),
            ),
          );
        },
      ),
    );
  }
}

class _VideoPreview extends StatelessWidget {
  const _VideoPreview({required this.file, required this.thumbnail});

  final File file;
  final Future<File?> thumbnail;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        FutureBuilder<File?>(
          future: thumbnail,
          builder: (context, snapshot) {
            final thumb = snapshot.data;
            if (thumb != null) {
              return _ImagePreview(file: thumb);
            }

            return DecoratedBox(
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(Icons.movie, color: cs.onSurfaceVariant),
            );
          },
        ),
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
}

class _PreviewBadge extends StatelessWidget {
  const _PreviewBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 2,
      right: 2,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.58),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
          child: Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontSize: 8,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class _FailedBadge extends StatelessWidget {
  const _FailedBadge();

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 2,
      right: 2,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.red.shade700,
          borderRadius: BorderRadius.circular(3),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
          child: Icon(Icons.close, color: Colors.white, size: 10),
        ),
      ),
    );
  }
}

class _ScoreBadge extends StatelessWidget {
  final double score;
  final String label;
  const _ScoreBadge({required this.score, this.label = ''});

  Color _scoreColor(ColorScheme cs, double score) {
    if (score < 50) return cs.error;
    final t = (score - 50) / 50;
    return Color.lerp(cs.error, cs.primary, t)!;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final display = label.isEmpty ? '${score.round()}%' : '$label ${score.round()}%';
    return Positioned(
      top: 2,
      left: 2,
      child: _Chip(label: display, color: _scoreColor(cs, score)),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final Color color;
  const _Chip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
          child: Text(
            label,
            style: TextStyle(
              color: readableOn(color),
              fontSize: 8,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class _GradientHoverOutline extends StatelessWidget {
  const _GradientHoverOutline({
    required this.isHovered,
    required this.isSelected,
    required this.child,
  });

  final bool isHovered;
  final bool isSelected;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final color = isSelected
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.inverseSurface;
    return TweenAnimationBuilder<double>(
      duration: const Duration(milliseconds: 540),
      curve: Curves.easeOutCubic,
      tween: Tween<double>(end: isHovered || isSelected ? 1 : 0),
      builder: (context, progress, child) {
        return Container(
          foregroundDecoration: BoxDecoration(
            color: color.withAlpha((35 * progress).toInt()),
            borderRadius: .circular(15),
            border: GradientBoxBorder(
              width: 2,
              gradient: RadialGradient(
                colors: [
                  color.withAlpha((progress * 0.9 * 256).toInt()),
                  color.withAlpha((progress * 0.4 * 256).toInt()),
                ],
                radius: 1,
                center: .bottomCenter,
              ),
            ),
          ),
          child: child,
        );
      },
      child: child,
    );
  }
}

class _SuggestionsPopup extends StatefulWidget {
  final LayerLink link;
  final List<String> suggestions;
  final int selectedIndex;
  final ValueChanged<int> onTap;

  const _SuggestionsPopup({
    required this.link,
    required this.suggestions,
    required this.selectedIndex,
    required this.onTap,
  });

  @override
  State<_SuggestionsPopup> createState() => _SuggestionsPopupState();
}

class _SuggestionsPopupState extends State<_SuggestionsPopup>
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

  Widget _buildItem(BuildContext context, int index, ColorScheme cs) {
    final isSelected = index == widget.selectedIndex;
    return Material(
      color: isSelected ? cs.primary.withAlpha(30) : Colors.transparent,
      child: InkWell(
        onTap: () => widget.onTap(index),
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          child: Row(
            children: [
              Icon(Icons.folder, size: 14, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.suggestions[index],
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface,
                    fontWeight: isSelected
                        ? FontWeight.w600
                        : FontWeight.normal,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

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
                width: 300,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (
                      var index = 0;
                      index < widget.suggestions.length;
                      index++
                    )
                      _buildItem(context, index, cs),
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
