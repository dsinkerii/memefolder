import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:memefolder/backend/embedding_service.dart';
import 'package:memefolder/prefs.dart';

class _ModelEntry {
  final String name;
  final String url;
  final String subdir;
  final String filename;
  final int sizeBytes;
  bool downloaded;
  double progress = 0;
  String? error;

  _ModelEntry({
    required this.name,
    required this.url,
    required this.subdir,
    required this.filename,
    required this.sizeBytes,
    this.downloaded = false,
  });

  String sizeLabel(BuildContext context) {
    if (sizeBytes < 1048576) return '${(sizeBytes / 1024).toStringAsFixed(0)} KB';
    return '${(sizeBytes / 1048576).toStringAsFixed(0)} MB';
  }
}

Future<String> _modelsDir() async {
  // try project searchmodels/ first
  final projectDir = Directory(p.join(Directory.current.path, 'searchmodels'));
  if (await projectDir.exists()) return projectDir.path;
  // fallback to app support dir
  return p.join((await getApplicationSupportDirectory()).path, 'models');
}

const _tiers = ['low', 'mid', 'high'];

List<List<_ModelEntry>> _modelDefs = [
  // low tier — CLIP ViT-B/32
  [
    _ModelEntry(
      name: 'CLIP ViT-B/32 Vision',
      url: 'https://huggingface.co/Xenova/clip-vit-base-patch32/resolve/main/onnx/vision_model.onnx',
      subdir: 'clip',
      filename: 'vision_model.onnx',
      sizeBytes: 352321536,
    ),
    _ModelEntry(
      name: 'CLIP ViT-B/32 Text',
      url: 'https://huggingface.co/Xenova/clip-vit-base-patch32/resolve/main/onnx/text_model_quantized.onnx',
      subdir: 'clip',
      filename: 'text_model.onnx',
      sizeBytes: 64592281,
    ),
    _ModelEntry(
      name: 'CLIP Tokenizer',
      url: 'https://huggingface.co/Xenova/clip-vit-base-patch32/resolve/main/tokenizer.json',
      subdir: 'clip',
      filename: 'tokenizer.json',
      sizeBytes: 2228224,
    ),
    _ModelEntry(
      name: 'CLAP Audio',
      url: 'https://huggingface.co/Xenova/clap-htsat-unfused/resolve/main/onnx/audio_model_quantized.onnx',
      subdir: 'clap',
      filename: 'audio_model_quantized.onnx',
      sizeBytes: 34225562,
    ),
    _ModelEntry(
      name: 'CLAP Text',
      url: 'https://huggingface.co/Xenova/clap-htsat-unfused/resolve/main/onnx/text_model_quantized.onnx',
      subdir: 'clap',
      filename: 'text_model_quantized.onnx',
      sizeBytes: 126509353,
    ),
    _ModelEntry(
      name: 'CLAP Tokenizer',
      url: 'https://huggingface.co/Xenova/clap-htsat-unfused/resolve/main/tokenizer.json',
      subdir: 'clap',
      filename: 'tokenizer.json',
      sizeBytes: 2105344,
    ),
  ],
];

void showModelManagerDialog(BuildContext context) {
  showDialog(
    context: context,
    builder: (_) => const _ModelManagerDialog(),
  );
}

class _ModelManagerDialog extends StatefulWidget {
  const _ModelManagerDialog();

  @override
  State<_ModelManagerDialog> createState() => _ModelManagerDialogState();
}

class _ModelManagerDialogState extends State<_ModelManagerDialog> {
  late List<_ModelEntry> _models;
  String _basePath = '';
  bool _downloading = false;
  bool _loading = true;
  final String _selectedTier;

  _ModelManagerDialogState() : _selectedTier = PlayerPrefs.getString('model_tier', 'low');

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _basePath = await _modelsDir();
    final defs = _modelDefs[0]; // low tier for now
    _models = defs.map((m) => _ModelEntry(
      name: m.name,
      url: m.url,
      subdir: m.subdir,
      filename: m.filename,
      sizeBytes: m.sizeBytes,
      downloaded: File(p.join(_basePath, m.subdir, m.filename)).existsSync(),
    )).toList();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _downloadModel(_ModelEntry model) async {
    setState(() {
      model.progress = 0;
      model.error = null;
    });

    try {
      final dir = Directory(p.join(_basePath, model.subdir));
      if (!await dir.exists()) await dir.create(recursive: true);

      final request = http.Request('GET', Uri.parse(model.url));
      final response = await http.Client().send(request);

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final file = File(p.join(_basePath, model.subdir, model.filename));
      final sink = file.openWrite();
      final total = model.sizeBytes;
      var received = 0;

      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        final p = total > 0 ? received / total : 0.0;
        if (mounted) setState(() => model.progress = p);
      }

      await sink.flush();
      await sink.close();

      if (mounted) {
        setState(() {
          model.downloaded = true;
          model.progress = 1.0;
        });
      }
    } catch (e) {
      if (mounted) setState(() => model.error = e.toString());
    }
  }

  Future<void> _downloadAll() async {
    setState(() => _downloading = true);
    for (final m in _models) {
      if (!m.downloaded && m.error == null) {
        await _downloadModel(m);
      }
    }
    setState(() => _downloading = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final hasAll = _models.every((m) => m.downloaded);

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.model_training, color: cs.primary),
          const SizedBox(width: 8),
          Text('Models'),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: ListView(
          shrinkWrap: true,
          children: [
            // tier selector
            Row(
              children: [
                Text('Tier:', style: TextStyle(color: cs.onSurfaceVariant)),
                const SizedBox(width: 12),
                DropdownButton<String>(
                  value: _selectedTier,
                  underline: const SizedBox(),
                  items: _tiers.map((t) => DropdownMenuItem(
                    value: t,
                    child: Text(t.toUpperCase(), style: TextStyle(
                      color: cs.primary,
                      fontWeight: FontWeight.w600,
                    )),
                  )).toList(),
                  onChanged: null, // TODO: implement tier switching
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Models dir: $_basePath',
              style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            // model list
            ..._models.map((m) => _buildModelRow(cs, m)),
            const SizedBox(height: 12),
            // actions
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (_downloading)
                  const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                if (!_downloading)
                  FilledButton.tonal(
                    onPressed: hasAll ? null : _downloadAll,
                    child: Text(hasAll ? 'all downloaded' : 'download all'),
                  ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: hasAll ? () {
                    Navigator.of(context).pop();
                    EmbeddingService.instance.initialize();
                  } : null,
                  child: const Text('load models'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModelRow(ColorScheme cs, _ModelEntry m) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            m.downloaded ? Icons.check_circle : Icons.cloud_download,
            size: 18,
            color: m.downloaded ? Colors.green : cs.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(m.name, style: TextStyle(fontSize: 13, color: cs.onSurface)),
                if (m.error != null)
                  Text(m.error!, style: TextStyle(fontSize: 10, color: cs.error))
                else
                  Text(
                    '${m.sizeLabel(context)} — ${m.downloaded ? 'on disk' : 'not downloaded'}',
                    style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
                  ),
                if (m.progress > 0 && m.progress < 1)
                  LinearProgressIndicator(value: m.progress),
              ],
            ),
          ),
          if (!m.downloaded)
            IconButton(
              icon: const Icon(Icons.download, size: 18),
              onPressed: _downloading ? null : () => _downloadModel(m),
            ),
        ],
      ),
    );
  }
}
