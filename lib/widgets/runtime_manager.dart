import 'dart:io';

import 'package:dotted_border/dotted_border.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_vector_icons/flutter_vector_icons.dart';
import 'package:memefolder/backend/download_manager.dart';
import 'package:memefolder/backend/semantic_search/semantic_search_classes.dart';
import 'package:memefolder/backend/system_specs.dart';
import 'package:memefolder/helpers/new_dialog.dart';
import 'package:memefolder/prefs.dart';
import 'package:memefolder/widgets/bubble_snackbar.dart';

enum _Mode { simple, advanced }

enum _Tier { low, high }

void showRuntimeManagerDialog(BuildContext context) {
  showScaleDialog(
    context: context,
    width: 520,
    builder: (dialogCtx) => const _RuntimeManagerDialog(),
  );
}

class _RuntimeManagerDialog extends StatefulWidget {
  const _RuntimeManagerDialog();

  @override
  State<_RuntimeManagerDialog> createState() => _RuntimeManagerDialogState();
}

class _RuntimeManagerDialogState extends State<_RuntimeManagerDialog> {
  _Mode _mode = _Mode.simple;
  _Tier _tier = _Tier.low;
  SystemSpecs? _specs;
  bool _loadingSpecs = true;
  bool _downloading = false;
  double _downloadProgress = 0;
  String? _downloadError;
  List<ModelManifest> _installedModels = [];
  bool _gpuAcceleration = true;
  final Map<String, Set<EmbeddingTask>> _disabledTasks = {};
  final Map<EmbeddingTask, String?> _taskModelAssignments = {};

  final Set<EmbeddingTask> _allTasks = EmbeddingTask.values.toSet();

  static const _downloadLinks = {
    _Tier.low: {
      'linux':
          'https://github.com/dsinkerii/messedup-settings/releases/download/1.5/host_linux_x64',
      'windows':
          'https://github.com/dsinkerii/messedup-settings/releases/download/1.5/host_windows_x64.exe',
      'macos':
          'https://github.com/dsinkerii/messedup-settings/releases/download/1.5/host_macos_arm64',
    },
    _Tier.high: {
      'linux':
          'https://github.com/dsinkerii/messedup-settings/releases/download/1.5/host_linux_x64_high',
      'windows':
          'https://github.com/dsinkerii/messedup-settings/releases/download/1.5/host_windows_x64_high.exe',
      'macos':
          'https://github.com/dsinkerii/messedup-settings/releases/download/1.5/host_macos_arm64_high',
    },
  };

  String get _platformKey {
    if (Platform.isLinux) return 'linux';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    return 'linux';
  }

  @override
  void initState() {
    super.initState();
    _gpuAcceleration = PlayerPrefs.getBool(
      PlayerPrefs.gpuAccelerationKey,
      true,
    );
    _loadSpecs();
    _reloadModels();
  }

  void _reloadModels() {
    setState(() {
      _installedModels = DownloadManager.instance.getInstalledModels();
    });
  }

  Future<void> _loadSpecs() async {
    final specs = await SystemSpecs.detect();
    if (!mounted) return;
    final defaultGpu = specs.supportsGpuAcceleration;
    if (!_gpuAcceleration) {
      _gpuAcceleration = PlayerPrefs.getBool(
        PlayerPrefs.gpuAccelerationKey,
        defaultGpu,
      );
    }
    setState(() {
      _specs = specs;
      _loadingSpecs = false;
      _tier = specs.isHighEnd ? _Tier.high : _Tier.low;
    });
  }

  bool _isTaskEnabled(ModelManifest model, EmbeddingTask task) {
    final disabled = _disabledTasks[model.name];
    return disabled == null || !disabled.contains(task);
  }

  void _toggleTask(ModelManifest model, EmbeddingTask task) {
    setState(() {
      final disabled = _disabledTasks.putIfAbsent(model.name, () => {});
      if (disabled.contains(task)) {
        disabled.remove(task);
        if (disabled.isEmpty) _disabledTasks.remove(model.name);
      } else {
        disabled.add(task);
      }
    });
  }

  Set<EmbeddingTask> _coveredTasks() {
    final covered = <EmbeddingTask>{};
    for (final m in _installedModels) {
      for (final t in m.tasks) {
        if (_isTaskEnabled(m, t)) covered.add(t);
      }
    }
    // also add tasks that have a manual assignment
    for (final entry in _taskModelAssignments.entries) {
      if (entry.value != null) covered.add(entry.key);
    }
    return covered;
  }

  Set<EmbeddingTask> _missingTasks() {
    final covered = _coveredTasks();
    return _allTasks.difference(covered);
  }

  double _performanceImpact() {
    if (_specs == null) return 0.5;
    final s = _specs!;
    final modelCount = _installedModels.length.clamp(1, 4);
    final tierRam = _tier == _Tier.high ? 8.0 : 4.0;
    final tierVram = _tier == _Tier.high ? 2.0 : 1.0;
    final tierCores = _tier == _Tier.high ? 4 : 2;

    final ramRatio = (tierRam * modelCount) / s.ramGb.clamp(0.1, 999);
    final vramRatio = (tierVram * modelCount) / s.vramGb.clamp(0.1, 999);
    final coreRatio = (tierCores * modelCount) / s.cpuCores.clamp(1, 999);

    return ((ramRatio + vramRatio + coreRatio) / 3).clamp(0.0, 1.0);
  }

  Future<void> _toggleGpuAcceleration(bool value) async {
    if (value && _specs != null && !_specs!.supportsGpuAcceleration) {
      showBubble(
        const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.warning, color: Colors.white),
            SizedBox(width: 12),
            Flexible(
              child: Text(
                'GPU acceleration requires a discrete GPU with ≥2GB VRAM',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.none,
                ),
                softWrap: true,
              ),
            ),
          ],
        ),
      );
      return;
    }
    await PlayerPrefs.setBool(PlayerPrefs.gpuAccelerationKey, value);
    setState(() => _gpuAcceleration = value);
  }

  Color _impactColor(double impact, ColorScheme cs) {
    if (impact < 0.33) return Colors.green;
    if (impact < 0.66) return Colors.orange;
    return cs.error;
  }

  Future<void> _startDownload() async {
    final url = _downloadLinks[_tier]?[_platformKey];
    if (url == null) {
      showBubble(
        const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error, color: Colors.white),
            SizedBox(width: 12),
            Text(
              'No download available for this platform',
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w500,
                decoration: TextDecoration.none,
              ),
              softWrap: true,
            ),
          ],
        ),
      );
      return;
    }

    setState(() {
      _downloading = true;
      _downloadProgress = 0;
      _downloadError = null;
    });

    final result = await DownloadManager.instance.downloadFromUrl(
      url: url,
      onProgress: (p) {
        if (mounted) setState(() => _downloadProgress = p);
      },
    );

    if (!mounted) return;

    switch (result) {
      case DownloadSuccess(:final filePath):
        setState(() => _downloading = false);
        showBubble(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle, color: Colors.white),
              const SizedBox(width: 12),
              Text(
                'Downloaded: ${filePath.split(Platform.pathSeparator).last}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.none,
                ),
                softWrap: true,
              ),
            ],
          ),
        );
        break;
      case DownloadFailure(:final error):
        setState(() {
          _downloading = false;
          _downloadError = error;
        });
        showBubble(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error, color: Colors.white),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Download failed: $error',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    decoration: TextDecoration.none,
                  ),
                  softWrap: true,
                ),
              ),
            ],
          ),
        );
        break;
      case DownloadAlreadyDownloading():
        setState(() => _downloading = false);
        showBubble(
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.hourglass_top, color: Colors.white),
              SizedBox(width: 12),
              Text(
                'Already downloading...',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.none,
                ),
                softWrap: true,
              ),
            ],
          ),
        );
        break;
    }
  }

  Future<void> _pickAndInstallModel() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    if (result == null || result.files.isEmpty) return;

    final manifest = await DownloadManager.instance.pickAndExtractModel(
      result.files.first.path!,
    );

    if (!mounted) return;

    if (manifest != null) {
      _reloadModels();
      showBubble(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle, color: Colors.white),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                'Installed: ${manifest.name}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.none,
                ),
                softWrap: true,
              ),
            ),
          ],
        ),
      );
    } else {
      showBubble(
        const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error, color: Colors.white),
            SizedBox(width: 12),
            Flexible(
              child: Text(
                'Invalid model ZIP - must be v2 with package.txt',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
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

  Future<void> _removeModel(ModelManifest model) async {
    final dirName = DownloadManager.instance.getModelDirName(model);
    if (dirName == null) return;

    await DownloadManager.instance.removeModel(dirName);
    if (!mounted) return;

    _reloadModels();
    showBubble(
      const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.delete, color: Colors.white),
          SizedBox(width: 12),
          Text(
            'Model removed',
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w500,
              decoration: TextDecoration.none,
            ),
            softWrap: true,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 6),
          Icon(Ionicons.hardware_chip_sharp, size: 48, color: cs.primary),
          const SizedBox(height: 10),
          Text(
            "Runtime Manager",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 24,
              fontFamily: "Syne",
              color: cs.onSurface,
              fontVariations: const [
                FontVariation('wdth', 2800),
                FontVariation('wght', 700),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            "manage models, tiers, and hardware for embedding tasks.",
            style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          SegmentedButton<_Mode>(
            style: ButtonStyle(
              backgroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) return cs.primary;
                return null;
              }),
              foregroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) return cs.onPrimary;
                return null;
              }),
              iconColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) return cs.onPrimary;
                return null;
              }),
              side: WidgetStatePropertyAll(
                BorderSide(color: cs.primary, width: 1.5),
              ),
            ),
            segments: const [
              ButtonSegment(
                value: _Mode.simple,
                icon: Icon(Icons.speed, size: 18),
                label: Text('Simple'),
              ),
              ButtonSegment(
                value: _Mode.advanced,
                icon: Icon(Icons.tune, size: 18),
                label: Text('Advanced'),
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (m) => setState(() => _mode = m.first),
          ),
          const SizedBox(height: 16),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: _mode == _Mode.simple
                ? _buildSimpleMode(cs, key: const ValueKey('simple'))
                : _buildAdvancedMode(cs, key: const ValueKey('advanced')),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text("Done", style: TextStyle(color: cs.primary)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSimpleMode(ColorScheme cs, {Key? key}) {
    final covered = _coveredTasks();
    final missing = _missingTasks();
    final coveredCount = covered.length;
    final totalCount = _allTasks.length;

    return Column(
      key: key,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildSpecsCard(cs),
        const SizedBox(height: 12),
        _buildPerformanceBar(cs),
        const SizedBox(height: 12),
        _buildGpuToggle(cs),
        const SizedBox(height: 12),
        _buildSimpleModelStack(cs, covered, missing, coveredCount, totalCount),
        const SizedBox(height: 12),
        _buildDownloadSection(cs),
      ],
    );
  }

  Widget _buildSimpleModelStack(
    ColorScheme cs,
    Set<EmbeddingTask> covered,
    Set<EmbeddingTask> missing,
    int coveredCount,
    int totalCount,
  ) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withAlpha(100),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.layers, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Text(
                'Model Stack',
                style: TextStyle(
                  fontFamily: "Syne",
                  fontVariations: const [FontVariation('wght', 600)],
                  fontSize: 14,
                  color: cs.onSurface,
                ),
              ),
              const Spacer(),
              Text(
                '$coveredCount / $totalCount tasks covered',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ..._allTasks.map((task) {
            final hasModel = covered.contains(task);
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(
                    hasModel
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 16,
                    color: hasModel ? Colors.green : cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    task.label,
                    style: TextStyle(
                      fontSize: 12,
                      color: hasModel ? cs.onSurface : cs.onSurfaceVariant,
                    ),
                  ),
                  if (hasModel) ...[
                    const SizedBox(width: 6),
                    Text(
                      '✓',
                      style: TextStyle(fontSize: 11, color: Colors.green),
                    ),
                  ],
                ],
              ),
            );
          }),
          if (missing.isNotEmpty) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => setState(() => _mode = _Mode.advanced),
                icon: const Icon(MaterialIcons.colorize, size: 16),
                label: const Text('Pick the right settings for me'),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: cs.primary),
                  foregroundColor: cs.primary,
                ),
              ),
            ),
          ],
          if (_installedModels.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Divider(height: 1),
            const SizedBox(height: 8),
            ..._installedModels.map((m) {
              final allDisabled = m.tasks.every((t) => !_isTaskEnabled(m, t));
              final op = allDisabled ? 0.35 : 1.0;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Row(
                  children: [
                    Icon(
                      Icons.smart_toy,
                      size: 14,
                      color: cs.primary.withAlpha((op * 255).round()),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        m.name,
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurface.withAlpha((op * 255).round()),
                          decoration: allDisabled
                              ? TextDecoration.lineThrough
                              : null,
                          decorationThickness: 2.0,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      m.tasksSummary,
                      style: TextStyle(
                        fontSize: 10,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _buildAdvancedMode(ColorScheme cs, {Key? key}) {
    return Column(
      key: key,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildSpecsCard(cs),
        const SizedBox(height: 12),
        _buildPerformanceBar(cs),
        const SizedBox(height: 12),
        _buildGpuToggle(cs),
        const SizedBox(height: 12),
        _buildTaskCoverage(cs),
        const SizedBox(height: 12),
        _buildModelList(cs),
        const SizedBox(height: 16),
        _buildModelUpload(cs),
      ],
    );
  }

  Widget _buildTaskCoverage(ColorScheme cs) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withAlpha(100),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Task Coverage',
            style: TextStyle(
              fontFamily: "Syne",
              fontVariations: const [FontVariation('wght', 600)],
              fontSize: 14,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 10),
          ..._allTasks.map((task) {
            final candidates = _installedModels
                .where((m) => m.tasks.contains(task))
                .toList();
            final assigned = _taskModelAssignments[task];
            final enabledModels = candidates.where(
              (m) => _isTaskEnabled(m, task),
            );
            final hasCoverage = assigned != null
                ? _isTaskEnabled(
                    candidates.firstWhere(
                      (m) => m.name == assigned,
                      orElse: () => candidates.first,
                    ),
                    task,
                  )
                : enabledModels.isNotEmpty;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Icon(
                    hasCoverage
                        ? Icons.check_circle
                        : Icons.remove_circle_outline,
                    size: 16,
                    color: hasCoverage ? Colors.green : cs.error,
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 120,
                    child: Text(
                      task.label,
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: "Syne",
                        color: hasCoverage ? cs.onSurface : cs.onSurfaceVariant,
                        decoration: hasCoverage
                            ? null
                            : TextDecoration.lineThrough,
                        decorationThickness: 2.0,
                        decorationColor: Colors.grey,
                      ),
                    ),
                  ),
                  Expanded(
                    child: candidates.isEmpty
                        ? Text(
                            'no compatible model',
                            style: TextStyle(
                              fontSize: 11,
                              color: cs.onSurfaceVariant.withAlpha(120),
                              fontStyle: FontStyle.italic,
                            ),
                          )
                        : SizedBox(
                            height: 28,
                            child: DropdownButtonFormField<String>(
                              value:
                                  assigned ??
                                  (enabledModels.isNotEmpty
                                      ? enabledModels.first.name
                                      : candidates.first.name),
                              isDense: true,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.zero,
                                isDense: true,
                              ),
                              style: TextStyle(
                                fontSize: 11,
                                color: cs.onSurface,
                                fontFamily: "Hack",
                              ),
                              items: candidates.map((m) {
                                final en = _isTaskEnabled(m, task);
                                return DropdownMenuItem<String>(
                                  value: m.name,
                                  enabled: en,
                                  child: Text(
                                    m.name,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontFamily: "Hack",
                                      color: en
                                          ? cs.onSurface
                                          : cs.onSurfaceVariant.withAlpha(80),
                                      decoration: en
                                          ? null
                                          : TextDecoration.lineThrough,
                                      decorationThickness: 2.0,
                                    ),
                                  ),
                                );
                              }).toList(),
                              onChanged: (val) {
                                if (val != null) {
                                  setState(
                                    () => _taskModelAssignments[task] = val,
                                  );
                                }
                              },
                            ),
                          ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildModelList(ColorScheme cs) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withAlpha(100),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Installed Models',
                style: TextStyle(
                  fontFamily: "Syne",
                  fontVariations: const [FontVariation('wght', 600)],
                  fontSize: 14,
                  color: cs.onSurface,
                ),
              ),
              const Spacer(),
              Text(
                '${_installedModels.length} model${_installedModels.length == 1 ? '' : 's'}',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_installedModels.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: Text(
                  'No models installed. Upload a model ZIP below.',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ),
            )
          else
            ..._installedModels.map((m) => _buildModelCard(cs, m)),
        ],
      ),
    );
  }

  Widget _buildModelCard(ColorScheme cs, ModelManifest model) {
    final allDisabled = model.tasks.every((t) => !_isTaskEnabled(model, t));
    final nameOpacity = allDisabled ? 0.35 : 1.0;
    final nameDeco = allDisabled ? TextDecoration.lineThrough : null;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surface.withAlpha(180),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.primary.withAlpha(80), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.smart_toy,
                size: 16,
                color: cs.primary.withAlpha((nameOpacity * 255).round()),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  model.name,
                  style: TextStyle(
                    fontFamily: "Syne",
                    fontVariations: const [FontVariation('wght', 600)],
                    fontSize: 13,
                    color: cs.onSurface.withAlpha((nameOpacity * 255).round()),
                    decoration: nameDeco,
                    decorationThickness: 2.0,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: cs.primary.withAlpha(20),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  model.type,
                  style: TextStyle(
                    fontSize: 10,
                    color: cs.primary,
                    fontFamily: "Hack",
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 4,
            runSpacing: 2,
            children: model.tasks.map((task) {
              final enabled = _isTaskEnabled(model, task);
              final taskOpacity = enabled ? 1.0 : 0.35;
              final taskDeco = enabled ? null : TextDecoration.lineThrough;

              return GestureDetector(
                onTap: () => _toggleTask(model, task),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: _taskColor(task).withAlpha(enabled ? 25 : 8),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        enabled ? Icons.check_circle : Icons.remove_circle,
                        size: 12,
                        color: enabled ? _taskColor(task) : Colors.grey,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        task.label,
                        style: TextStyle(
                          fontSize: 10,
                          color: _taskColor(
                            task,
                          ).withAlpha((taskOpacity * 255).round()),
                          fontFamily: "Syne",
                          decoration: taskDeco,
                          decorationThickness: 2.0,
                          decorationColor: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _removeModel(model),
              icon: const Icon(Icons.delete_outline, size: 14),
              label: const Text('Remove', style: TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: cs.error, width: 1),
                foregroundColor: cs.error,
                padding: const EdgeInsets.symmetric(vertical: 4),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _taskColor(EmbeddingTask task) {
    switch (task) {
      case EmbeddingTask.metadataText:
        return const Color(0xFF00BCD4);
      case EmbeddingTask.imageEmbedding:
        return const Color(0xFF7C4DFF);
      case EmbeddingTask.audioAnalysis:
        return const Color(0xFFF36E36);
      case EmbeddingTask.ocr:
        return const Color(0xFF9436A6);
      case EmbeddingTask.speechToText:
        return const Color(0xFF4EB8A0);
    }
  }

  Widget _buildModelUpload(ColorScheme cs) {
    return DottedBorder(
      options: RoundedRectDottedBorderOptions(
        color: cs.primary.withAlpha(160),
        strokeWidth: 2.5,
        radius: const Radius.circular(10),
        strokeCap: StrokeCap.butt,
      ),
      child: GestureDetector(
        onTap: _pickAndInstallModel,
        child: Container(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.cloud_upload_outlined, size: 48, color: cs.primary),
                const SizedBox(height: 12),
                Text(
                  'Upload Model ZIP',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: cs.primary,
                    fontFamily: 'Syne',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGpuToggle(ColorScheme cs) {
    final canUseGpu = _specs?.supportsGpuAcceleration ?? false;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withAlpha(100),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            _gpuAcceleration ? Icons.speed : Icons.speed_outlined,
            size: 18,
            color: canUseGpu ? cs.onSurfaceVariant : cs.error,
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'GPU Acceleration',
                  style: TextStyle(
                    fontSize: 13,
                    fontFamily: "Syne",
                    fontVariations: const [FontVariation('wght', 600)],
                    color: cs.onSurface,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: _gpuAcceleration,
            onChanged: canUseGpu ? _toggleGpuAcceleration : null,
          ),
        ],
      ),
    );
  }

  Widget _buildSpecsCard(ColorScheme cs) {
    if (_loadingSpecs) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withAlpha(100),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: cs.primary,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              'Detecting system specs...',
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    final s = _specs!;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withAlpha(100),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'System Specs',
            style: TextStyle(
              fontFamily: "Syne",
              fontVariations: const [FontVariation('wght', 600)],
              fontSize: 14,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 10),
          _specRow(cs, Icons.memory, 'CPU', s.cpuModel),
          _specRow(cs, Icons.scatter_plot, 'Cores', '${s.cpuCores}'),
          _specRow(
            cs,
            Icons.storage,
            'RAM',
            '${s.ramGb.toStringAsFixed(1)} GB',
          ),
          Divider(height: 12, color: cs.onSurface.withAlpha(80)),
          _specRow(cs, Icons.videocam, 'GPU', s.gpuName),
          _specRow(
            cs,
            Icons.memory,
            s.isIntegratedGpu ? 'Shared Mem' : 'VRAM',
            s.isIntegratedGpu
                ? '~${s.vramGb.toStringAsFixed(1)} GB (from RAM)'
                : '${s.vramGb.toStringAsFixed(1)} GB',
          ),
        ],
      ),
    );
  }

  Widget _specRow(ColorScheme cs, IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 14, color: cs.primary),
          const SizedBox(width: 8),
          SizedBox(
            width: 55,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurfaceVariant,
                fontFamily: "Syne",
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface,
                fontFamily: "Hack",
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPerformanceBar(ColorScheme cs) {
    final impact = _performanceImpact();
    final color = _impactColor(impact, cs);
    final label = impact < 0.33
        ? 'Low impact'
        : impact < 0.66
        ? 'Moderate impact'
        : 'High impact';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Performance Impact',
              style: TextStyle(
                fontSize: 12,
                fontFamily: "Syne",
                fontVariations: const [FontVariation('wght', 600)],
                color: cs.onSurface,
              ),
            ),
            Text(
              label,
              style: TextStyle(fontSize: 12, color: color, fontFamily: "Hack"),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: impact,
            minHeight: 8,
            backgroundColor: cs.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
      ],
    );
  }

  Widget _buildDownloadSection(ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Runtime binary',
          style: TextStyle(
            fontSize: 12,
            fontFamily: "Syne",
            fontVariations: const [FontVariation('wght', 600)],
            color: cs.onSurface,
          ),
        ),
        const SizedBox(height: 8),
        if (_downloading) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: _downloadProgress > 0 ? _downloadProgress : null,
              minHeight: 8,
              backgroundColor: cs.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _downloadProgress > 0
                ? '${(_downloadProgress * 100).toStringAsFixed(1)}%'
                : 'Downloading...',
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurfaceVariant,
              fontFamily: "Hack",
            ),
          ),
        ] else ...[
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _startDownload,
              icon: const Icon(Icons.download, size: 18),
              label: Text(
                'Download ${_tier == _Tier.high ? 'high' : 'low'} tier zip',
              ),
              style: FilledButton.styleFrom(
                backgroundColor: cs.primary,
                foregroundColor: cs.onPrimary,
              ),
            ),
          ),
          if (_downloadError != null) ...[
            const SizedBox(height: 6),
            Text(
              _downloadError!,
              style: TextStyle(fontSize: 11, color: cs.error),
            ),
          ],
        ],
      ],
    );
  }
}
