import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:file_manager/file_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_vector_icons/flutter_vector_icons.dart';
import 'package:intl/intl.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:memefolder/backend/audio_player_service.dart';
import 'package:memefolder/backend/indexer.dart';
import 'package:memefolder/backend/waveform_generator.dart';
import 'package:memefolder/prefs.dart';
import 'package:memefolder/widgets/bubble_snackbar.dart';
import 'package:memefolder/helpers/styled_inputfields.dart';
import 'package:open_dir/open_dir.dart';
import 'package:open_file/open_file.dart';
import 'package:silky_scroll/silky_scroll.dart';

class FilePreviewPane extends StatelessWidget {
  const FilePreviewPane({super.key, required this.file});

  final File? file;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final currentFile = file;

    return Scaffold(
      appBar: AppBar(
        scrolledUnderElevation: 0,
        backgroundColor: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withAlpha(110),
        centerTitle: true,
        title: Text(
          FileManager.basename(currentFile),
          style: newInputStyle(context).copyWith(
            fontFamily: "Syne",
            fontVariations: [
              FontVariation('wdth', 2800),
              FontVariation('wght', 600),
            ],
            fontSize: 16,
          ),
          overflow: .fade,
          maxLines: 1,
        ),
      ),
      body: SilkyScroll(
        builder: (context, controller, physics, pointerDeviceKind) =>
            SingleChildScrollView(
              controller: controller,
              child: Center(
                child: Container(
                  margin: const EdgeInsets.all(16),
                  padding: .all(16),
                  constraints: const BoxConstraints(maxWidth: 900),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: cs.outlineVariant.withAlpha(160),
                      width: 1.8,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: AspectRatio(
                          aspectRatio: 16 / 10,
                          child: currentFile == null
                              ? Icon(
                                  Icons.insert_drive_file,
                                  size: 64,
                                  color: cs.onSurfaceVariant,
                                )
                              : _PreviewContent(file: currentFile),
                        ),
                      ),
                      if (currentFile != null) ...[
                        const SizedBox(height: 12),
                        _FileActionButtons(file: currentFile),
                        const SizedBox(height: 12),
                        _FileMetadataSection(file: currentFile),
                        const SizedBox(height: 12),
                        _TagsSection(file: currentFile),
                        const SizedBox(height: 12),
                        _AudioMetadataSection(file: currentFile),
                      ],
                    ],
                  ),
                ),
              ),
            ),
      ),
    );
  }
}

class _FileActionButtons extends StatelessWidget {
  const _FileActionButtons({required this.file});
  final File file;

  Future<void> _openInExplorer(BuildContext context) async {
    final dir = file.parent.path;
    final _openDirPlugin = OpenDir();
    await _openDirPlugin.openNativeDir(
      path: dir,
      highlightedFileName: FileManager.basename(file),
    );
  }

  Future<void> _openFile(BuildContext context) async {
    await OpenFile.open(file.path);
  }

  Future<void> _copyPath(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: file.path));
    if (context.mounted) {
      showBubble(
        Text(
          'path copied to clipboard',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w500,
            decoration: TextDecoration.none,
          ),
          softWrap: true,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Row(
      children: [
        Expanded(
          child: _ActionButton(
            icon: Icons.folder_open,
            label: 'Open in Explorer',
            onTap: () => _openInExplorer(context),
            color: cs.primary,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _ActionButton(
            icon: Icons.open_in_new,
            label: 'Open File',
            onTap: () => _openFile(context),
            color: cs.primary,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _ActionButton(
            icon: Icons.copy,
            label: 'Copy Path',
            onTap: () => _copyPath(context),
            color: cs.primary,
          ),
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Material(
      color: color.withAlpha(25),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: cs.onSurface,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FileMetadataSection extends StatelessWidget {
  const _FileMetadataSection({required this.file});
  final File file;

  static final _dateFmt = DateFormat('MMM d, yyyy  h:mm a');

  String _formatSize(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1073741824) {
      return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
  }

  String _formatMode(int mode) {
    final perms = <String>[];
    if (mode & 0x100 != 0) perms.add('r');
    if (mode & 0x80 != 0) perms.add('w');
    if (mode & 0x40 != 0) perms.add('x');
    if (mode & 0x20 != 0) perms.add('r');
    if (mode & 0x10 != 0) perms.add('w');
    if (mode & 0x08 != 0) perms.add('x');
    if (mode & 0x04 != 0) perms.add('r');
    if (mode & 0x02 != 0) perms.add('w');
    if (mode & 0x01 != 0) perms.add('x');
    return perms.join('');
  }

  String _getMimeCategory(String ext) {
    const imageExts = {
      'jpg',
      'jpeg',
      'png',
      'webp',
      'bmp',
      'gif',
      'heic',
      'heif',
      'tiff',
      'tif',
      'svg',
      'ico',
      'avif',
    };
    const videoExts = {
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
      '3gp',
      'ogv',
    };
    const audioExts = {
      'mp3',
      'ogg',
      'wav',
      'flac',
      'aac',
      'm4a',
      'opus',
      'wma',
      'mid',
      'midi',
      'amr',
    };
    const docExts = {
      'pdf',
      'doc',
      'docx',
      'xls',
      'xlsx',
      'ppt',
      'pptx',
      'odt',
      'ods',
      'odp',
      'txt',
      'rtf',
      'csv',
    };
    const archiveExts = {
      'zip',
      'tar',
      'gz',
      'bz2',
      'xz',
      '7z',
      'rar',
      'tgz',
      'deb',
      'rpm',
    };
    const codeExts = {
      'dart',
      'js',
      'ts',
      'jsx',
      'tsx',
      'py',
      'rs',
      'go',
      'java',
      'c',
      'cpp',
      'h',
      'hpp',
      'cs',
      'rb',
      'php',
      'swift',
      'kt',
      'sh',
      'bash',
      'zsh',
      'yaml',
      'yml',
      'toml',
      'json',
      'xml',
      'html',
      'css',
      'scss',
      'sql',
      'md',
      'markdown',
    };

    final e = ext.toLowerCase();
    if (imageExts.contains(e)) return 'Image';
    if (videoExts.contains(e)) return 'Video';
    if (audioExts.contains(e)) return 'Audio';
    if (docExts.contains(e)) return 'Document';
    if (archiveExts.contains(e)) return 'Archive';
    if (codeExts.contains(e)) return 'Code';
    return 'File';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ext = file.path.split('.').last.toLowerCase();
    final name = FileManager.basename(file);

    return FutureBuilder<FileStat>(
      future: file.stat(),
      builder: (context, snapshot) {
        final stat = snapshot.data;
        final size = stat?.size ?? 0;
        final modified = stat?.modified;
        final changed = stat?.changed;
        final accessed = stat?.accessed;
        final mode = stat?.mode ?? 0;

        final items = <_InfoItem>[
          _InfoItem(label: 'Name', value: name),
          _InfoItem(label: 'Path', value: file.path, copyable: true),
          _InfoItem(label: 'Type', value: _getMimeCategory(ext)),
          _InfoItem(
            label: 'Extension',
            value: ext.isNotEmpty ? '.$ext' : 'None',
          ),
          _InfoItem(label: 'Size', value: _formatSize(size)),
          _InfoItem(label: 'Size (bytes)', value: size.toString()),
          if (modified != null)
            _InfoItem(label: 'Modified', value: _dateFmt.format(modified)),
          if (changed != null)
            _InfoItem(label: 'Created', value: _dateFmt.format(changed)),
          if (accessed != null)
            _InfoItem(label: 'Last Accessed', value: _dateFmt.format(accessed)),
          if (mode != 0)
            _InfoItem(label: 'Permissions', value: _formatMode(mode)),
          _InfoItem(
            label: 'Hidden',
            value: name.startsWith('.') ? 'Yes' : 'No',
          ),
          _InfoItem(
            label: 'Readable',
            value: file.existsSync() && file.existsSync() ? 'Yes' : 'No',
          ),
        ];

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withAlpha(80),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: cs.outlineVariant.withAlpha(60),
              width: 2,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'File Information',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 16,
                runSpacing: 6,
                children: items
                    .map(
                      (item) => SizedBox(
                        width: 220,
                        child: _buildInfoRow(context, item),
                      ),
                    )
                    .toList(),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildInfoRow(BuildContext context, _InfoItem item) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        SelectableText(
          '${item.label}: ',
          style: TextStyle(
            fontSize: 11,
            color: cs.onSurfaceVariant.withAlpha(180),
            overflow: TextOverflow.fade,
          ),
        ),
        Expanded(
          child: SelectableText(
            item.value,
            style: TextStyle(
              fontSize: 11,
              color: cs.onSurface,
              fontWeight: FontWeight.w500,
              overflow: TextOverflow.fade,
            ),
            maxLines: 1,
          ),
        ),
      ],
    );
  }
}

class _InfoItem {
  final String label;
  final String value;
  final bool copyable;

  const _InfoItem({
    required this.label,
    required this.value,
    this.copyable = false,
  });
}

class _AudioMetadataSection extends StatefulWidget {
  const _AudioMetadataSection({required this.file});
  final File file;

  @override
  State<_AudioMetadataSection> createState() => _AudioMetadataSectionState();
}

class _AudioMetadataSectionState extends State<_AudioMetadataSection> {
  late Future<Map<String, String?>> _future;

  static const _audioExts = {
    'mp3',
    'ogg',
    'wav',
    'flac',
    'aac',
    'm4a',
    'opus',
    'wma',
    'aiff',
    'aif',
    'alac',
  };

  @override
  void initState() {
    super.initState();
    _future = _loadMeta(widget.file.path);
  }

  @override
  void didUpdateWidget(covariant _AudioMetadataSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) {
      _future = _loadMeta(widget.file.path);
    }
  }

  Future<Map<String, String?>> _loadMeta(String path) {
    final ext = path.split('.').last.toLowerCase();
    return _audioExts.contains(ext) ? _extract(path) : Future.value({});
  }

  Future<Map<String, String?>> _extract(String path) async {
    try {
      final result = await Process.run('ffprobe', [
        '-v',
        'error',
        '-show_entries',
        'format_tags=artist,album,genre,date,comment,track',
        '-show_entries',
        'format=duration,bit_rate',
        '-of',
        'json',
        path,
      ]);
      if (result.exitCode != 0) return {};
      final json = jsonDecode(result.stdout as String) as Map<String, dynamic>?;
      if (json == null) return {};
      final tags = json['format']?['tags'] as Map<String, dynamic>?;
      final duration = double.tryParse(
        json['format']?['duration']?.toString() ?? '',
      );
      final bitRate = int.tryParse(
        json['format']?['bit_rate']?.toString() ?? '',
      );
      return {
        'Artist': tags?['artist']?.toString(),
        'Album': tags?['album']?.toString(),
        'Genre': tags?['genre']?.toString(),
        'Year': tags?['date']?.toString(),
        'Track': tags?['track']?.toString(),
        'Comment': tags?['comment']?.toString(),
        'Duration': duration != null ? _fmtDuration(duration) : null,
        'Bitrate': bitRate != null ? '${(bitRate / 1000).round()} kbps' : null,
      };
    } catch (_) {
      return {};
    }
  }

  String _fmtDuration(double secs) {
    final d = Duration(milliseconds: (secs * 1000).round());
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0)
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return FutureBuilder<Map<String, String?>>(
      future: _future,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null || data.isEmpty) return const SizedBox.shrink();

        final items = data.entries
            .where((e) => e.value != null && e.value!.isNotEmpty)
            .toList();
        if (items.isEmpty) return const SizedBox.shrink();

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withAlpha(80),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: cs.outlineVariant.withAlpha(60),
              width: 2,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.audio_file_outlined,
                    size: 16,
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Audio Metadata',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 16,
                runSpacing: 6,
                children: items
                    .map(
                      (e) => SizedBox(
                        width: 220,
                        child: _buildRow(context, e.key, e.value!),
                      ),
                    )
                    .toList(),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildRow(BuildContext context, String label, String value) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        SelectableText(
          '$label: ',
          style: TextStyle(
            fontSize: 11,
            color: cs.onSurfaceVariant.withAlpha(180),
            overflow: TextOverflow.fade,
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: TextStyle(
              fontSize: 11,
              color: cs.onSurface,
              fontWeight: FontWeight.w500,
              overflow: TextOverflow.fade,
            ),
            maxLines: 1,
          ),
        ),
      ],
    );
  }
}

class _TagsSection extends StatefulWidget {
  const _TagsSection({required this.file});
  final File file;

  @override
  State<_TagsSection> createState() => _TagsSectionState();
}

class _TagsSectionState extends State<_TagsSection> {
  late Future<List<String>> _future;
  bool _adding = false;
  final _controller = TextEditingController();
  List<String> _allTags = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _TagsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) {
      _load();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _load() {
    final root = PlayerPrefs.getString("main_folder");
    if (root.isEmpty) {
      _future = Future.value([]);
      return;
    }
    _future = getFileTags(root, widget.file.path);
    getAvailableTags(root).then((t) {
      if (mounted) setState(() => _allTags = t);
    });
  }

  Future<void> _addTag(String tag) async {
    final root = PlayerPrefs.getString("main_folder");
    if (root.isEmpty) return;
    await addFileTag(root, widget.file.path, tag);
    _controller.clear();
    setState(() {
      _adding = false;
      _load();
    });
  }

  Future<void> _removeTag(String tag) async {
    final root = PlayerPrefs.getString("main_folder");
    if (root.isEmpty) return;
    await removeFileTag(root, widget.file.path, tag);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return FutureBuilder<List<String>>(
      future: _future,
      builder: (context, snapshot) {
        final tags = snapshot.data ?? [];

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withAlpha(80),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: cs.outlineVariant.withAlpha(60),
              width: 2,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    MaterialCommunityIcons.tag_outline,
                    size: 16,
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Tags',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (tags.isEmpty && !_adding)
                Text(
                  'no tags assigned',
                  style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurfaceVariant.withAlpha(150),
                    fontStyle: FontStyle.italic,
                  ),
                )
              else ...[
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    ...tags.map((tag) => _buildTagChip(tag)),
                    if (_adding) _buildAddField(),
                  ],
                ),
              ],
              if (!_adding)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: GestureDetector(
                    onTap: () => setState(() => _adding = true),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.add,
                          size: 14,
                          color: cs.primary.withAlpha(180),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'add tag',
                          style: TextStyle(
                            fontSize: 11,
                            color: cs.primary.withAlpha(180),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTagChip(String tag) {
    final cs = Theme.of(context).colorScheme;
    return Chip(
      label: Text(
        tag,
        style: TextStyle(
          fontSize: 11,
          color: cs.onPrimaryContainer,
          fontFamily: "Hack",
        ),
      ),
      side: BorderSide(color: cs.primary.withAlpha(160), width: 1.2),
      backgroundColor: cs.primaryContainer,
      deleteIcon: Icon(Icons.close, size: 14, color: cs.onPrimaryContainer),
      onDeleted: () => _removeTag(tag),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
    );
  }

  Widget _buildAddField() {
    final cs = Theme.of(context).colorScheme;

    return Autocomplete<String>(
      optionsBuilder: (textEditingValue) {
        final query = textEditingValue.text.toLowerCase();
        if (query.isEmpty) return _allTags;
        return _allTags.where((t) => t.toLowerCase().contains(query));
      },
      onSelected: (tag) {
        _controller.text = tag;
        _addTag(tag);
      },
      fieldViewBuilder: (context, controller, focusNode, onSubmitted) {
        controller.text = _controller.text;
        controller.selection = _controller.selection;
        return SizedBox(
          width: 140,
          height: 28,
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            style: TextStyle(fontSize: 11, fontFamily: "Hack"),
            decoration: InputDecoration(
              hintText: 'tag name...',
              hintStyle: TextStyle(
                fontSize: 11,
                color: cs.onSurfaceVariant.withAlpha(120),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 4,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
              ),
              isDense: true,
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: BoxConstraints(),
                    icon: Icon(Icons.close, size: 14),
                    onPressed: () => setState(() => _adding = false),
                  ),
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: BoxConstraints(),
                    icon: Icon(Icons.check, size: 14),
                    onPressed: () {
                      final val = controller.text.trim();
                      if (val.isNotEmpty) _addTag(val);
                    },
                  ),
                ],
              ),
            ),
            onSubmitted: (v) {
              final val = v.trim();
              if (val.isNotEmpty) _addTag(val);
            },
          ),
        );
      },
    );
  }
}

class _PreviewContent extends StatelessWidget {
  const _PreviewContent({required this.file});

  final File file;

  @override
  Widget build(BuildContext context) {
    final kind = _PreviewKind.fromPath(file.path);

    return Container(
      decoration: BoxDecoration(borderRadius: .circular(8)),
      clipBehavior: .antiAlias,
      child: switch (kind) {
        _PreviewKind.image => _ImagePreview(file: file),
        _PreviewKind.gif => _MediaPreview(file: file, loop: true),
        _PreviewKind.video => _MediaPreview(file: file, loop: false),
        _PreviewKind.audio => _AudioPreview(file: file),
        _PreviewKind.file => _UnsupportedPreview(file: file),
      },
    );
  }
}

class _ImagePreview extends StatefulWidget {
  const _ImagePreview({required this.file});
  final File file;

  @override
  State<_ImagePreview> createState() => _ImagePreviewState();
}

class _ImagePreviewState extends State<_ImagePreview> {
  final TransformationController _transform = TransformationController();
  double _currentScale = 1;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_onTransformChange);
  }

  void _onTransformChange() {
    final s = _transform.value.getMaxScaleOnAxis();
    if ((s - _currentScale).abs() > 0.01) {
      setState(() => _currentScale = s);
    }
  }

  void _zoomIn() {
    final s = (_currentScale + 0.5).clamp(1.0, 6.0);
    _currentScale = s;
    _transform.value = Matrix4.diagonal3Values(s, s, s);
  }

  void _zoomOut() {
    final s = (_currentScale - 0.5).clamp(1.0, 6.0);
    _currentScale = s;
    _transform.value = Matrix4.diagonal3Values(s, s, s);
  }

  @override
  void dispose() {
    _transform.removeListener(_onTransformChange);
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Stack(
      children: [
        InteractiveViewer(
          transformationController: _transform,
          minScale: 1,
          maxScale: 6,
          child: Center(
            child: Image.file(
              widget.file,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) =>
                  const Icon(Icons.broken_image, size: 64),
            ),
          ),
        ),
        Positioned(
          right: 8,
          bottom: 8,
          child: Container(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(8)),
            clipBehavior: .hardEdge,

            child: ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: Container(
                  color: cs.surface.withAlpha(160),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Zoom in',
                        onPressed: _currentScale < 6 ? _zoomIn : null,
                        icon: Icon(
                          Icons.zoom_in,
                          size: 20,
                          color: cs.inverseSurface,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Zoom out',
                        onPressed: _currentScale > 1.01 ? _zoomOut : null,
                        icon: Icon(
                          Icons.zoom_out,
                          size: 20,
                          color: cs.inverseSurface,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MediaPreview extends StatefulWidget {
  const _MediaPreview({required this.file, required this.loop});

  final File file;
  final bool loop;

  @override
  State<_MediaPreview> createState() => _MediaPreviewState();
}

class _MediaPreviewState extends State<_MediaPreview> {
  late final Player _player;
  late final VideoController _controller;
  double _volume = PlayerPrefs.getFloat('video_volume', 80);
  bool _hovering = false;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: false,
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _open();
    });
  }

  @override
  void didUpdateWidget(covariant _MediaPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path ||
        oldWidget.loop != widget.loop) {
      _open();
    }
  }

  Future<void> _open() async {
    await _player.setPlaylistMode(
      widget.loop ? PlaylistMode.loop : PlaylistMode.none,
    );
    await _player.setVolume(_volume);
    await _player.open(Media(widget.file.path), play: false);
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _player.dispose();
    super.dispose();
  }

  void _onHover(bool hovering) {
    setState(() => _hovering = hovering);
    _hideTimer?.cancel();
    if (hovering) {
      _hideTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _hovering = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return MouseRegion(
      onEnter: (_) => _onHover(true),
      onExit: (_) => _onHover(false),
      onHover: (_) => _onHover(true),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: Colors.black,
            child: Video(
              controller: _controller,
              fit: BoxFit.contain,
              controls: null,
            ),
          ),
          Positioned.fill(
            child: StreamBuilder<bool>(
              stream: _player.stream.playing,
              initialData: _player.state.playing,
              builder: (context, snapshot) {
                final playing = snapshot.data ?? false;
                if (playing) return const SizedBox.shrink();
                return GestureDetector(
                  onTap: () => _player.play(),
                  child: Container(
                    color: Colors.black26,
                    child: const Center(
                      child: Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.white70,
                        size: 64,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Positioned.fill(
            child: AnimatedOpacity(
              opacity: _hovering ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_hovering,
                child: _buildControls(cs),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControls(ColorScheme cs) {
    return Stack(
      children: [
        Positioned(
          left: 12,
          right: 12,
          bottom: 12,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: cs.surface.withValues(alpha: 0.86),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildSeekBar(cs),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      StreamBuilder<bool>(
                        stream: _player.stream.playing,
                        initialData: _player.state.playing,
                        builder: (context, snapshot) {
                          final playing = snapshot.data ?? false;
                          return IconButton(
                            tooltip: playing ? 'Pause' : 'Play',
                            onPressed: playing ? _player.pause : _player.play,
                            icon: Icon(
                              playing ? Icons.pause : Icons.play_arrow,
                            ),
                          );
                        },
                      ),
                      if (!widget.loop)
                        IconButton(
                          tooltip: 'Loop',
                          onPressed: () => _player.setPlaylistMode(
                            _player.state.playlistMode == PlaylistMode.loop
                                ? PlaylistMode.none
                                : PlaylistMode.loop,
                          ),
                          icon: StreamBuilder<PlaylistMode>(
                            stream: _player.stream.playlistMode,
                            initialData: _player.state.playlistMode,
                            builder: (context, snapshot) => Icon(
                              snapshot.data == PlaylistMode.loop
                                  ? Icons.repeat_on
                                  : Icons.repeat,
                            ),
                          ),
                        ),
                      IconButton(
                        icon: Icon(
                          _volume > 50
                              ? Icons.volume_up
                              : _volume > 0
                              ? Icons.volume_down
                              : Icons.volume_off,
                          color: cs.onSurfaceVariant,
                        ),
                        onPressed: () {
                          setState(() {
                            _volume = _volume > 0 ? 0 : 80;
                          });
                          _player.setVolume(_volume);
                          PlayerPrefs.setFloat('video_volume', _volume);
                        },
                      ),

                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: 160),
                        child: Expanded(
                          child: SliderTheme(
                            data: SliderThemeData(
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6,
                              ),
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 12,
                              ),
                              trackHeight: 3,
                              activeTrackColor: cs.primary,
                              inactiveTrackColor: cs.onSurface.withAlpha(30),
                              thumbColor: cs.primary,
                              overlayColor: cs.primary.withAlpha(30),
                            ),
                            child: Slider(
                              value: _volume,
                              min: 0,
                              max: 100,
                              onChanged: (value) {
                                setState(() => _volume = value);
                                _player.setVolume(value);
                                PlayerPrefs.setFloat('video_volume', value);
                              },
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSeekBar(ColorScheme cs) {
    return StreamBuilder<Duration>(
      stream: _player.stream.position,
      initialData: _player.state.position,
      builder: (context, posSnap) {
        return StreamBuilder<Duration>(
          stream: _player.stream.duration,
          initialData: _player.state.duration,
          builder: (context, durSnap) {
            final position = posSnap.data ?? Duration.zero;
            final duration = durSnap.data ?? Duration.zero;
            final ms = duration.inMilliseconds;
            final fraction = ms > 0
                ? (position.inMilliseconds / ms).clamp(0.0, 1.0)
                : 0.0;

            return Row(
              children: [
                Text(
                  _fmtDuration(position),
                  style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderThemeData(
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 5,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 10,
                      ),
                      trackHeight: 3,
                      activeTrackColor: cs.primary,
                      inactiveTrackColor: cs.onSurface.withAlpha(30),
                      thumbColor: cs.primary,
                      overlayColor: cs.primary.withAlpha(30),
                    ),
                    child: Slider(
                      value: fraction,
                      onChanged: (v) {
                        _player.seek(Duration(milliseconds: (v * ms).round()));
                      },
                    ),
                  ),
                ),
                Text(
                  _fmtDuration(duration),
                  style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  String _fmtDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

class _AudioPreview extends StatefulWidget {
  const _AudioPreview({required this.file});

  final File file;

  @override
  State<_AudioPreview> createState() => _AudioPreviewState();
}

class _AudioPreviewState extends State<_AudioPreview> {
  List<double>? _waveform;
  final AudioPlayerService _audio = AudioPlayerService.instance;

  @override
  void initState() {
    super.initState();
    _generateWaveform();
  }

  @override
  void didUpdateWidget(covariant _AudioPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) {
      _waveform = null;
      _generateWaveform();
    }
  }

  Future<void> _generateWaveform() async {
    final wave = await WaveformGenerator.generate(widget.file.path);
    if (mounted) setState(() => _waveform = wave);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final name = FileManager.basename(widget.file);
    final size = widget.file.existsSync() ? widget.file.lengthSync() : 0;

    return ListenableBuilder(
      listenable: _audio,
      builder: (context, _) {
        final isCurrentTrack = _audio.currentPath == widget.file.path;
        final playing = isCurrentTrack && _audio.playing;
        final progress = isCurrentTrack && _audio.duration.inMilliseconds > 0
            ? (_audio.position.inMilliseconds / _audio.duration.inMilliseconds)
                  .clamp(0.0, 1.0)
            : 0.0;

        return Container(
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  GestureDetector(
                    onTap: () {
                      if (isCurrentTrack) {
                        playing ? _audio.pause() : _audio.resume();
                      } else {
                        _audio.play(
                          widget.file.path,
                          title: name,
                          waveform: _waveform,
                        );
                      }
                    },
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: cs.primary,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        size: 28,
                        color: cs.onPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          name,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: cs.onSurface,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _formatSize(size),
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),

                  _buildAudioVolumeBar(cs),
                ],
              ),
              if (_waveform != null && _waveform!.isNotEmpty) ...[
                const SizedBox(height: 12),
                WaveformBars(bars: _waveform!, progress: progress),
              ],
              if (isCurrentTrack) ...[
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [Expanded(child: _buildAudioSeekBar(cs))],
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildAudioSeekBar(ColorScheme cs) {
    return Row(
      children: [
        Text(
          _fmtDuration(_audio.position),
          style: TextStyle(
            fontSize: 11,
            color: cs.onSurfaceVariant,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
              trackHeight: 3,
              activeTrackColor: cs.primary,
              inactiveTrackColor: cs.onSurface.withAlpha(30),
              thumbColor: cs.primary,
              overlayColor: cs.primary.withAlpha(30),
            ),
            child: Slider(
              value: _audio.duration.inMilliseconds > 0
                  ? (_audio.position.inMilliseconds /
                            _audio.duration.inMilliseconds)
                        .clamp(0.0, 1.0)
                  : 0.0,
              onChanged: (v) => _audio.seekFraction(v),
            ),
          ),
        ),
        Text(
          _fmtDuration(_audio.duration),
          style: TextStyle(
            fontSize: 11,
            color: cs.onSurfaceVariant,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  Widget _buildAudioVolumeBar(ColorScheme cs) {
    final vol = _audio.volume;
    return SizedBox(
      height: 80,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            vol > 0.5
                ? Icons.volume_up
                : vol > 0
                ? Icons.volume_down
                : Icons.volume_off,
            size: 16,
            color: cs.onSurfaceVariant,
          ),
          Expanded(
            child: RotatedBox(
              quarterTurns: -1,
              child: SliderTheme(
                data: SliderThemeData(
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 5,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 10,
                  ),
                  trackHeight: 3,
                  activeTrackColor: cs.primary,
                  inactiveTrackColor: cs.onSurface.withAlpha(30),
                  thumbColor: cs.primary,
                  overlayColor: cs.primary.withAlpha(30),
                ),
                child: Slider(
                  value: vol,
                  onChanged: (v) => _audio.setVolume(v),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _formatSize(int bytes) {
    if (bytes <= 0) return 'Unknown size';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1048576).toStringAsFixed(1)} MB';
  }

  String _fmtDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

class WaveformBars extends StatelessWidget {
  final List<double> bars;
  final double progress;

  const WaveformBars({super.key, required this.bars, this.progress = 1.0});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final progressIdx = (progress * bars.length).round().clamp(0, bars.length);
    return SizedBox(
      height: 32,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < bars.length; i++)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: Container(
                  height: (bars[i].clamp(0.05, 1.0) * 32),
                  decoration: BoxDecoration(
                    color: i < progressIdx
                        ? cs.primary
                        : cs.primary.withAlpha(50),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _UnsupportedPreview extends StatelessWidget {
  const _UnsupportedPreview({required this.file});

  final File file;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.insert_drive_file, size: 64, color: cs.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            FileManager.basename(file),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

enum _PreviewKind {
  image,
  gif,
  video,
  audio,
  file;

  static _PreviewKind fromPath(String path) {
    final ext = path.split('.').last.toLowerCase();
    if (ext == 'gif') return gif;
    if (_imageExtensions.contains(ext)) return image;
    if (_videoExtensions.contains(ext)) return video;
    if (_audioExtensions.contains(ext)) return audio;
    return file;
  }
}

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

const _audioExtensions = {
  'mp3',
  'ogg',
  'wav',
  'flac',
  'aac',
  'm4a',
  'opus',
  'wma',
};
