import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dotted_border/dotted_border.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_vector_icons/flutter_vector_icons.dart';
import 'package:http/http.dart' as http;
import 'package:memefolder/widgets/bubble_snackbar.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:memefolder/backend/embedding_service.dart';
import 'package:memefolder/backend/system_specs.dart';
import 'package:memefolder/helpers/new_dialog.dart';
import 'package:memefolder/prefs.dart';
import 'package:desktop_drop/desktop_drop.dart';

void showRuntimeManagerDialog(BuildContext context) {
  showScaleDialog(
    context: context,
    width: 640,
    builder: (dialogCtx) => const _RuntimeManagerDialog(),
  );
}

List<String> manifestFilesForTier(String tier) {
  final siglip = [
    'clip/vision_model.onnx',
    'clip/text_model.onnx',
    'clip/tokenizer.json',
  ];
  final cap = [
    'ocr/recognition.onnx',
    'ocr/vocab.txt',
    'whisper/tiny_encoder.onnx',
    'whisper/tiny_decoder.onnx',
    'whisper/tokenizer.json',
  ];
  final clap = [
    'clap/audio_model_fp16.onnx',
    'clap/text_model_quantized.onnx',
    'clap/tokenizer.json',
  ];
  switch (tier) {
    case 'lite':
      return [...siglip];
    case 'mid':
      return [...siglip, ...cap];
    case 'full':
      return [...siglip, ...clap, ...cap];
    default:
      return [];
  }
}

const tierMeta = {
  'lite': {
    'label': 'Lite',
    'desc': 'SigLIP vision + text (768d)',
    'clip': '768d',
    'vram': '1.2 GB',
    'ram': '600 MB',
    'remoteUrl': '',
  },
  'mid': {
    'label': 'Mid',
    'desc': 'SigLIP + OCR + Whisper Tiny',
    'clip': '768d',
    'vram': '1.9 GB',
    'ram': '900 MB',
    'remoteUrl': '',
  },
  'full': {
    'label': 'Full',
    'desc': 'SigLIP + CLAP + OCR + Whisper Tiny',
    'clip': '768d',
    'vram': '2.8 GB',
    'ram': '1.4 GB',
    'remoteUrl': '',
  },
};

Future<String> _modelsDir() async {
  return p.join((await getApplicationSupportDirectory()).path, 'models');
}

class _RuntimeManagerDialog extends StatefulWidget {
  const _RuntimeManagerDialog();
  @override
  State<_RuntimeManagerDialog> createState() => _RuntimeManagerDialogState();
}

class _RuntimeManagerDialogState extends State<_RuntimeManagerDialog> {
  SystemSpecs? _specs;
  bool _loadingSpecs = true;
  String _tier = 'lite';
  String _basePath = '';
  bool _loadingModels = true;
  bool _busy = false;
  double _progress = 0;
  String? _statusMsg;

  @override
  void initState() {
    super.initState();
    _loadSpecs();
  }

  Future<void> _loadSpecs() async {
    final specs = await SystemSpecs.detect();
    if (!mounted) return;
    final saved = PlayerPrefs.getString('model_tier', '');
    setState(() {
      _specs = specs;
      _loadingSpecs = false;
      if (saved == 'low') {
        _tier = 'lite';
      } else if (saved == 'high') {
        _tier = 'full';
      } else {
        _tier = saved.isNotEmpty ? saved : specs.tierRecommendation;
      }
    });
    _basePath = await _modelsDir();
    if (mounted) setState(() => _loadingModels = false);
  }

  Manifest? _readManifest() {
    try {
      final f = File(p.join(_basePath, _tier, 'manifest.yaml'));
      if (!f.existsSync()) return null;
      final lines = f.readAsLinesSync();
      String? tier, clipDim, vram, ram, desc;
      for (final l in lines) {
        if (l.startsWith('tier:')) tier = l.split(':').last.trim();
        if (l.startsWith('clip_dim:')) clipDim = l.split(':').last.trim();
        if (l.startsWith('vram_usage_mb:')) vram = l.split(':').last.trim();
        if (l.startsWith('ram_usage_mb:')) ram = l.split(':').last.trim();
        if (l.startsWith('description:')) desc = l.split(':').last.trim();
      }
      if (tier == null) return null;
      return Manifest(
        tier: tier,
        clipDim: clipDim,
        vramMb: vram,
        ramMb: ram,
        description: desc,
      );
    } catch (_) {
      return null;
    }
  }

  bool _hasModel(String file) =>
      File(p.join(_basePath, _tier, file)).existsSync();
  List<String> get _manifestFiles => manifestFilesForTier(_tier);
  bool get _hasAllModels => _manifestFiles.every(_hasModel);

  int get _modelCount => _manifestFiles.where((f) => _hasModel(f)).length;

  void _setTier(String tier) {
    setState(() => _tier = tier);
    PlayerPrefs.setString('model_tier', tier);
  }

  Future<void> _downloadModels() async {
    final url = tierMeta[_tier]!['remoteUrl'] as String;
    if (url.isEmpty) {
      setState(() => _statusMsg = 'No download URL configured for $_tier tier');
      return;
    }

    setState(() {
      _busy = true;
      _progress = 0;
      _statusMsg = 'Downloading $_tier models...';
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
        if (total > 0 && mounted) setState(() => _progress = received / total);
      }
      final bytes = Uint8List.fromList(chunks);
      await _extractZip(bytes);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _statusMsg = 'Download failed: $e';
        });
      }
    }
  }

  Future<void> _uploadZip({Uint8List? bytes}) async {
    if (bytes != null) {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );
      if (result == null || result.files.isEmpty) return;
      setState(() async {
        _busy = true;
        _progress = 0;
        _statusMsg = 'Extracting...';

        try {
          final bytespromise =
              result.files.single.bytes ??
              await File(result.files.single.path!).readAsBytes();
          bytes = bytespromise;
        } catch (e) {
          if (mounted) {
            setState(() {
              _busy = false;
              _statusMsg = 'Failed: $e';
            });
          }
          return;
        }
      });
    }
    if (bytes != null) await _extractZip(bytes!);
  }

  Future<void> _extractZip(Uint8List bytes) async {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final tierDir = Directory(p.join(_basePath, _tier));
      if (!await tierDir.exists()) await tierDir.create(recursive: true);

      var extracted = 0;
      final total = archive.length;
      // detect zip layout: if entries start with a single top dir, strip it
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
          setState(() => _progress = total > 0 ? extracted / total : 0);
        }
      }

      // validate manifest
      final man = _readManifest();
      if (man == null || man.tier != _tier) {
        if (mounted) {
          setState(
            () => _statusMsg = 'Warning: manifest missing or tier mismatch',
          );
        }
      }

      if (mounted) {
        setState(() {
          _busy = false;
          _statusMsg = _hasAllModels
              ? '${_tier.toUpperCase()} models ready'
              : 'Some files missing';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _statusMsg = 'Extraction failed: $e';
        });
      }
    }
  }

  Future<void> _loadModels() async {
    setState(() {
      _busy = true;
      _statusMsg = 'Loading...';
    });
    try {
      final gpuProvider = _specs?.recommendedGpuProvider;
      await EmbeddingService.instance.initialize(
        modelsPath: _basePath,
        gpuProvider: gpuProvider,
        tier: _tier,
      );
      if (mounted) {
        final gpuErr = EmbeddingService.instance.gpuInitError;
        if (gpuProvider != null && gpuProvider != 'CPU' && gpuErr != null) {
          setState(() {
            _busy = false;
            _statusMsg = 'Models loaded, but GPU acceleration failed:\n$gpuErr';
            showBubble(
              Text(
                "Loaded! (CPU only. GPU acceleration failed:\n$gpuErr)",
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.none,
                ),
                softWrap: true,
              ),
            );
          });
          Navigator.of(context).pop();
        } else {
          if (gpuProvider == null || gpuProvider == 'CPU') {
            setState(() => _statusMsg = 'Loaded! (CPU only)');
            showBubble(
              Text(
                "Loaded! (CPU only)",
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.none,
                ),
                softWrap: true,
              ),
            );
          } else {
            setState(() => _statusMsg = 'Loaded! (GPU: $gpuProvider)');
            showBubble(
              Text(
                "Loaded! (GPU: $gpuProvider)",
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
          Navigator.of(context).pop();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _statusMsg = 'Failed: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 6),
          Icon(Ionicons.hardware_chip_sharp, size: 42, color: cs.primary),
          const SizedBox(height: 8),
          Text(
            "Runtime Manager",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 22,
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
            "system specs & neural models",
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          if (_loadingSpecs || _loadingModels)
            const Padding(
              padding: EdgeInsets.all(32),
              child: CircularProgressIndicator(),
            )
          else ...[
            _buildSpecsCard(cs),
            const SizedBox(height: 16),
            _buildTierCards(cs),
            const SizedBox(height: 14),
            _buildModelStatus(cs),
            const SizedBox(height: 14),
            _buildActions(cs),
            const SizedBox(height: 10),
            _buildFooter(cs),
          ],
        ],
      ),
    );
  }

  Widget _buildSpecsCard(ColorScheme cs) {
    if (_loadingSpecs) {
      return _card(cs, [
        Row(
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
              'getting system specs...',
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ]);
    }

    final s = _specs!;
    return _card(cs, [
      Text('System Specs', style: _sectionTitle(cs)),
      const SizedBox(height: 10),
      _specRow(cs, Icons.memory, 'CPU', s.cpuModel),
      _specRow(cs, Icons.scatter_plot, 'Cores', '${s.cpuCores}'),
      _specRow(cs, Icons.storage, 'RAM', '${s.ramGb.toStringAsFixed(1)} GB'),
      Divider(height: 12, color: cs.onSurface.withAlpha(80)),
      _specRow(cs, Icons.memory, 'GPU', s.gpuName),
      _specRow(
        cs,
        Icons.memory,
        s.isIntegratedGpu ? 'Shared Mem' : 'VRAM',
        s.isIntegratedGpu
            ? '~${s.vramGb.toStringAsFixed(1)} GB (from RAM)'
            : '${s.vramGb.toStringAsFixed(1)} GB',
      ),
    ]);
  }

  Widget _card(ColorScheme cs, List<Widget> children) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withAlpha(100),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  TextStyle _sectionTitle(ColorScheme cs) => TextStyle(
    fontFamily: "Syne",
    fontVariations: const [FontVariation('wght', 600)],
    fontSize: 14,
    color: cs.onSurface,
  );

  Widget _specRow(ColorScheme cs, IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 14, color: cs.primary),
          const SizedBox(width: 8),
          SizedBox(
            width: 65,
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

  Widget _buildTierCards(ColorScheme cs) {
    return Row(
      children: ['lite', 'mid', 'full'].map((t) {
        final sel = _tier == t;
        final meta = tierMeta[t]!;
        final files = manifestFilesForTier(t);
        final cnt = files
            .where((f) => File(p.join(_basePath, t, f)).existsSync())
            .length;
        return Expanded(
          child: GestureDetector(
            onTap: () => _setTier(t),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: EdgeInsets.only(
                right: t == 'lite'
                    ? 6
                    : t == 'mid'
                    ? 6
                    : 0,
              ),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: sel
                    ? cs.primary.withAlpha(20)
                    : cs.surfaceContainerHighest.withAlpha(60),
                borderRadius: BorderRadius.circular(12),
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
                        size: 14,
                        color: sel ? cs.primary : cs.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        meta['label'] as String,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          color: sel ? cs.primary : cs.onSurface,
                        ),
                      ),
                      const Spacer(),
                      _statusIcon(cnt, files.length, cs),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    meta['desc'] as String,
                    style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _usageChip(cs, Icons.memory, 'VRAM ${meta['vram']}'),
                      const SizedBox(width: 4),
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

  Widget _statusIcon(int count, int total, ColorScheme cs) {
    if (count == total) {
      return Icon(Icons.check_circle, size: 14, color: cs.primary);
    }
    if (count > 0) return Icon(Icons.warning, size: 14, color: Colors.orange);
    return Icon(Icons.circle_outlined, size: 14, color: cs.onSurfaceVariant);
  }

  Widget _usageChip(ColorScheme cs, IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 9, color: cs.primary),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 8,
              color: cs.onSurfaceVariant,
              fontFamily: 'Hack',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModelStatus(ColorScheme cs) {
    final man = _readManifest();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withAlpha(80),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Models  ·  ${_tier.toUpperCase()}',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  color: cs.onSurface,
                ),
              ),
              const Spacer(),
              Text(
                '$_modelCount/${_manifestFiles.length}',
                style: TextStyle(
                  fontSize: 11,
                  color: cs.onSurfaceVariant,
                  fontFamily: 'Hack',
                ),
              ),
            ],
          ),
          if (man != null) ...[
            const SizedBox(height: 4),
            Text(
              man.description ?? '',
              style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: _manifestFiles.map((f) {
              final ok = _hasModel(f);
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: ok
                      ? cs.primary.withAlpha(20)
                      : cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      ok ? Icons.check_circle : Icons.circle_outlined,
                      size: 10,
                      color: ok ? cs.primary : cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      p.basename(f),
                      style: TextStyle(
                        fontSize: 9,
                        fontFamily: 'Hack',
                        color: cs.onSurface,
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
          if (_busy && _progress > 0) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: _progress, minHeight: 4),
            ),
          ],
          if (_statusMsg != null) ...[
            const SizedBox(height: 4),
            Text(
              _statusMsg!,
              style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }

  bool _dragHoveringZip = false;

  Widget _buildActions(ColorScheme cs) {
    return Column(
      children: [
        _actionBtn(
          cs,
          Icons.download,
          'Download ${tierMeta[_tier]!['label']}',
          _busy ? null : _downloadModels,
          cs.primary,
        ),
        const SizedBox(height: 10),
        GestureDetector(
          onTap: _busy ? null : _uploadZip,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              color: _dragHoveringZip
                  ? cs.primary.withValues(alpha: 0.08)
                  : cs.surfaceContainerHighest.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(10),
            ),
            child: DottedBorder(
              options: RoundedRectDottedBorderOptions(
                radius: const Radius.circular(10),
                color: _dragHoveringZip
                    ? cs.primary
                    : cs.onSurfaceVariant.withValues(alpha: 0.45),
                strokeWidth: 1.5,
                dashPattern: const [6, 3],
              ),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: DropTarget(
                  onDragEntered: (_) {
                    if (!_busy) {
                      setState(() => _dragHoveringZip = true);
                    }
                  },
                  onDragExited: (_) {
                    if (_dragHoveringZip) {
                      setState(() => _dragHoveringZip = false);
                    }
                  },
                  onDragDone: (details) async {
                    setState(() => _dragHoveringZip = false);
                    final f = details.files.firstOrNull;
                    if (f == null || !f.name.endsWith('.zip')) return;
                    final bytes = await f.readAsBytes();
                    await _uploadZip(bytes: bytes);
                  },
                  child: Column(
                    children: [
                      Icon(
                        Icons.cloud_upload_outlined,
                        size: 24,
                        color: _dragHoveringZip
                            ? cs.primary
                            : cs.onSurfaceVariant.withValues(alpha: 0.7),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'drag \'n\' drop a .zip file here, or tap to browse',
                        style: TextStyle(
                          fontSize: 11,
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
    return FilledButton.tonal(
      onPressed: onTap,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 10),
        backgroundColor: color.withAlpha(25),
        foregroundColor: color,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 14),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 11)),
        ],
      ),
    );
  }

  Widget _buildFooter(ColorScheme cs) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(right: 12),
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        getButton(
          Text("Done", style: TextStyle(color: cs.primary, fontSize: 13)),
          () => _loadModels(),
          cs.primary,
        ),
      ],
    );
  }
}

class Manifest {
  final String tier;
  final String? clipDim;
  final String? vramMb;
  final String? ramMb;
  final String? description;
  Manifest({
    required this.tier,
    this.clipDim,
    this.vramMb,
    this.ramMb,
    this.description,
  });
}
