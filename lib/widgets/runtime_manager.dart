import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_vector_icons/flutter_vector_icons.dart';
import 'package:memefolder/backend/download_manager.dart';
import 'package:memefolder/backend/semantic_search/semantic_search_classes.dart';
import 'package:memefolder/backend/system_specs.dart';
import 'package:memefolder/helpers/new_dialog.dart';
import 'package:memefolder/widgets/bubble_snackbar.dart';

enum _Mode { simple, advanced }

enum _Tier { low, high }

void showRuntimeManagerDialog(BuildContext context) {
  showScaleDialog(
    context: context,
    width: 480,
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
  ModelManifest? _installedModel;

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
    _loadSpecs();
    _installedModel = DownloadManager.instance.getInstalledModel();
  }

  Future<void> _loadSpecs() async {
    final specs = await SystemSpecs.detect();
    if (!mounted) return;
    setState(() {
      _specs = specs;
      _loadingSpecs = false;
      _tier = specs.isHighEnd ? _Tier.high : _Tier.low;
    });
  }

  double _performanceImpact() {
    if (_specs == null) return 0.5;
    final s = _specs!;
    final tierRam = _tier == _Tier.high ? 8.0 : 4.0;
    final tierVram = _tier == _Tier.high ? 2.0 : 1.0;
    final tierCores = _tier == _Tier.high ? 4 : 2;

    final ramRatio = tierRam / s.ramGb.clamp(0.1, 999);
    final vramRatio = tierVram / s.vramGb.clamp(0.1, 999);
    final coreRatio = tierCores / s.cpuCores.clamp(1, 999);

    return ((ramRatio + vramRatio + coreRatio) / 3).clamp(0.0, 1.0);
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
              style: TextStyle(color: Colors.white),
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
                style: const TextStyle(color: Colors.white),
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
              Flexible(
                child: Text(
                  'Download failed: $error',
                  style: const TextStyle(color: Colors.white),
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
                style: TextStyle(color: Colors.white),
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
      setState(() => _installedModel = manifest);
      showBubble(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle, color: Colors.white),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                'Installed: ${manifest.name}',
                style: const TextStyle(color: Colors.white),
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
                'Invalid model ZIP - missing package.txt or model files',
                style: TextStyle(color: Colors.white),
                softWrap: true,
              ),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _removeModel() async {
    final dirName = DownloadManager.instance.getInstalledModelDirName();
    if (dirName == null) return;

    await DownloadManager.instance.removeModel(dirName);
    if (!mounted) return;

    setState(() => _installedModel = null);
    showBubble(
      const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.delete, color: Colors.white),
          SizedBox(width: 12),
          Text('Model removed', style: TextStyle(color: Colors.white)),
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
            "manage runtime tiers, install models, and configure hardware.",
            style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
            textAlign: .center,
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
    return Column(
      key: key,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildSpecsCard(cs),
        const SizedBox(height: 12),
        _buildPerformanceBar(cs),
        const SizedBox(height: 12),
        _buildTierSelector(cs),
        const SizedBox(height: 12),
        _buildDownloadSection(cs),
      ],
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
        _buildModelSection(cs),
      ],
    );
  }

  Widget _buildModelSection(ColorScheme cs) {
    final hasModel = _installedModel != null;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withAlpha(100),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: hasModel
              ? Colors.green.withAlpha(120)
              : cs.outlineVariant.withAlpha(60),
          width: hasModel ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                hasModel ? Icons.smart_toy : Icons.cloud_upload,
                size: 18,
                color: hasModel ? Colors.green : cs.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Text(
                _installedModel!.name,
                style: TextStyle(
                  fontFamily: "Syne",
                  fontVariations: const [FontVariation('wght', 600)],
                  fontSize: 14,
                  color: cs.onSurface,
                ),
              ),
              const Spacer(),
              if (hasModel)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.green.withAlpha(30),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'installed',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.green.shade700,
                      fontFamily: "Hack",
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (hasModel) ...[
            _specRow(cs, Icons.category, 'Type', _installedModel!.type),
            _specRow(
              cs,
              Icons.format_list_bulleted,
              'Supports',
              _installedModel!.supportsSummary,
            ),
            _specRow(cs, Icons.settings, 'Runtime', _installedModel!.runtime),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickAndInstallModel,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Replace'),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: cs.primary),
                      foregroundColor: cs.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _removeModel,
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('Remove'),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: cs.error),
                      foregroundColor: cs.error,
                    ),
                  ),
                ),
              ],
            ),
          ] else ...[
            Text(
              'No model installed. Install a model to enable smart search.',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _pickAndInstallModel,
                icon: const Icon(Icons.upload_file, size: 18),
                label: const Text('Install Model from ZIP'),
                style: FilledButton.styleFrom(
                  backgroundColor: cs.primary,
                  foregroundColor: cs.onPrimary,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'ZIP must contain package.txt + model files',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ],
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
          _specRow(cs, Icons.speed, 'Clock', _formatClock(s.cpuClockKhz)),
          _specRow(
            cs,
            Icons.storage,
            'RAM',
            '${s.ramGb.toStringAsFixed(1)} GB',
          ),
          const Divider(height: 16),
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

  Widget _buildTierSelector(ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Tier',
              style: TextStyle(
                fontSize: 12,
                fontFamily: "Syne",
                fontVariations: const [FontVariation('wght', 600)],
                color: cs.onSurface,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Recommended: ${_specs?.tierRecommendation ?? 'high'}',
                style: TextStyle(
                  fontSize: 11,
                  color: cs.onPrimaryContainer,
                  fontFamily: "Syne",
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SegmentedButton<_Tier>(
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.selected)) return cs.primary;
              return null;
            }),
            foregroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.selected)) return cs.onPrimary;
              return null;
            }),
            side: WidgetStatePropertyAll(
              BorderSide(color: cs.primary, width: 1.5),
            ),
          ),
          segments: const [
            ButtonSegment(value: _Tier.low, label: Text('Low')),
            ButtonSegment(value: _Tier.high, label: Text('High')),
          ],
          selected: {_tier},
          onSelectionChanged: (t) => setState(() => _tier = t.first),
        ),
        const SizedBox(height: 6),
        Text(
          _tier == _Tier.high
              ? 'High tier: ≥2GB VRAM, ≥8GB RAM, ≥2 cores @ 8GHz+'
              : 'Low tier: lighter models, works on most hardware',
          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _buildDownloadSection(ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Download Host Binary',
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
                'Download ${_tier == _Tier.high ? 'high' : 'low'} tier binary',
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

  String _formatClock(int khz) {
    if (khz >= 1000000) return '${(khz / 1000000).toStringAsFixed(1)} GHz';
    if (khz >= 1000) return '${(khz / 1000).toStringAsFixed(0)} MHz';
    return '$khz kHz';
  }
}
