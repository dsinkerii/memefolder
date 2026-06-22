import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_vector_icons/flutter_vector_icons.dart';
import 'package:memefolder/backend/custom_tags_store.dart';
import 'package:memefolder/helpers/new_dialog.dart';
import 'package:memefolder/helpers/styled_inputfields.dart';
import 'package:memefolder/prefs.dart';

void showCustomTagsDialog(BuildContext context) {
  showScaleDialog(
    context: context,
    width: 420,
    builder: (dialogCtx) => const _CustomTagsDialog(),
  );
}

class _CustomTagsDialog extends StatefulWidget {
  const _CustomTagsDialog();

  @override
  State<_CustomTagsDialog> createState() => _CustomTagsDialogState();
}

class _CustomTagsDialogState extends State<_CustomTagsDialog> {
  late Map<String, String> _tags;
  final _nameController = TextEditingController();
  final _descController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final raw = PlayerPrefs.getString("custom_tags", '{}');
    if (raw.isNotEmpty) {
      try {
        _tags = Map<String, String>.from(jsonDecode(raw));
      } catch (_) {
        _tags = {'dsinkerii': 'awesome developer'}; // teehee
      }
    } else {
      _tags = {'dsinkerii': 'awesome developer'};
    }
  }

  void _save() {
    PlayerPrefs.setString("custom_tags", jsonEncode(_tags));
    CustomTagsStore.instance.refresh();
  }

  void _addTag() {
    final name = _nameController.text.trim();
    final desc = _descController.text.trim();
    if (name.isEmpty) return;

    final key = name.startsWith('@') ? name.substring(1) : name;
    setState(() {
      _tags[key] = desc;
    });
    _nameController.clear();
    _descController.clear();
    _save();
  }

  void _removeTag(String key) {
    setState(() {
      _tags.remove(key);
    });
    _save();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 6),
        Icon(MaterialCommunityIcons.tag_text, size: 48),
        const SizedBox(height: 10),
        Text(
          "Custom Tags",
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
          "define your own @tags for filtering. use descriptions to nudge the AI to know what this tag is about.",
          style: TextStyle(fontSize: 16, color: cs.onSurfaceVariant),
          textAlign: .center,
        ),
        const SizedBox(height: 16),

        if (_tags.isNotEmpty)
          Container(
            constraints: const BoxConstraints(maxHeight: 200),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withAlpha(100),
              borderRadius: BorderRadius.circular(12),
            ),
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: _tags.length,
              itemBuilder: (context, index) {
                final entry = _tags.entries.elementAt(index);
                return ListTile(
                  dense: true,
                  leading: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: cs.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                  title: Text(
                    '@${entry.key}',
                    style: TextStyle(
                      fontFamily: "Syne",
                      fontVariations: const [FontVariation('wght', 600)],
                      color: cs.primary,
                      fontSize: 14,
                    ),
                  ),
                  subtitle: entry.value.isNotEmpty
                      ? Text(entry.value, style: const TextStyle(fontSize: 12))
                      : null,
                  trailing: IconButton(
                    icon: Icon(Icons.close, size: 16),
                    onPressed: () => _removeTag(entry.key),
                  ),
                );
              },
            ),
          ),

        const SizedBox(height: 12),

        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _nameController,
                decoration: newInputDeco(context).copyWith(
                  hintText: "tag name",
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                style: const TextStyle(fontFamily: "Syne", fontSize: 16),
                onSubmitted: (_) => _addTag(),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _descController,
                decoration: newInputDeco(context).copyWith(
                  hintText: "description",
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                style: const TextStyle(fontSize: 16),
                onSubmitted: (_) => _addTag(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: _addTag,
              icon: const Icon(Icons.add, size: 20),
            ),
          ],
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
    );
  }
}
