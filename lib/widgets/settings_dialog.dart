import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:flutter_vector_icons/flutter_vector_icons.dart';
import 'package:memefolder/backend/embedding_service.dart';
import 'package:memefolder/config/theme.dart';
import 'package:memefolder/helpers/new_dialog.dart';
import 'package:memefolder/prefs.dart';
import 'package:open_dir/open_dir.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'dart:io';

void showSettingsDialog(BuildContext context) {
  showScaleDialog(
    context: context,
    width: 420,
    builder: (dialogCtx) => const _SettingsDialog(),
  );
}

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog();

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late double _idleValue;
  late Color _accentColor;

  @override
  void initState() {
    super.initState();
    _idleValue = PlayerPrefs.getInt('model_idle_timeout', 10).toDouble();
    _accentColor = Color(PlayerPrefs.getInt('AccentColor', 0xFF6A79D7));
  }

  String get _idleLabel {
    if (_idleValue <= 0) return 'keep loaded';
    final m = _idleValue.round();
    if (m < 60) return '${m}min idle';
    return '${(m / 60).round()}h ${m % 60}min idle';
  }

  Future<String> _modelsDir() async {
    final projectDir = Directory(
      p.join(Directory.current.path, 'searchmodels'),
    );
    if (await projectDir.exists()) return projectDir.path;
    return p.join((await getApplicationSupportDirectory()).path, 'models');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    bool verboseConsole = PlayerPrefs.getBool('verbose_console', false);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(child: Icon(Ionicons.cog, size: 42, color: cs.primary)),
            const SizedBox(height: 8),
            Center(
              child: Text(
                'settings',
                style: TextStyle(
                  fontSize: 20,
                  fontFamily: 'Syne',
                  color: cs.onSurface,
                  fontVariations: const [
                    FontVariation('wdth', 2800),
                    FontVariation('wght', 700),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'model idle timeout',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _idleLabel,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
            Row(
              children: [
                const Text('off', style: TextStyle(fontSize: 10)),
                Expanded(
                  child: Slider(
                    min: 0,
                    max: 120,
                    divisions: 12,
                    value: _idleValue,
                    onChanged: (v) {
                      setState(() => _idleValue = v);
                      final clamped = v.round();
                      PlayerPrefs.setInt('model_idle_timeout', clamped);
                      if (EmbeddingService.instance.isInitialized) {
                        EmbeddingService.instance.restartIdleTimer();
                      }
                    },
                  ),
                ),
                const Text('2h', style: TextStyle(fontSize: 10)),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'verbose console',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                Switch(
                  value: verboseConsole,
                  onChanged: (v) async {
                    PlayerPrefs.setBool('verbose_console', v);
                    setState(() {
                      verboseConsole = v;
                    });
                    final dir = await getApplicationSupportDirectory();
                    final flag = File(p.join(dir.path, 'verbose.txt'));
                    if (v) {
                      await flag.writeAsString('1');
                    } else {
                      await flag.delete();
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'open models folder',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.folder_open, color: cs.primary),
                  onPressed: () async {
                    final dir = await _modelsDir();
                    final openDirPlugin = OpenDir();
                    await openDirPlugin.openNativeDir(path: dir);
                  },
                ),
              ],
            ),
            Divider(),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'dark mode',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                Switch(
                  value: PlayerPrefs.getBool('isDarkMode', true),
                  onChanged: (v) {
                    PlayerPrefs.setBool('isDarkMode', v);
                    Provider.of<ThemeModel>(context, listen: false).dark = v;
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),

            ExpansionTile(
              collapsedShape: RoundedRectangleBorder(
                side: BorderSide(
                  color: cs.onSurface.withValues(alpha: .4),
                  width: 1.5,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              shape: RoundedRectangleBorder(
                side: BorderSide(
                  color: cs.onSurface.withValues(alpha: .4),
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              leading: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  border: BoxBorder.all(
                    color: readableOn(_accentColor),
                    width: 2,
                  ),
                  color: _accentColor,
                  borderRadius: .circular(16),
                ),
              ),
              title: Text(
                'accent color',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
              children: [
                ColorPicker(
                  pickerColor: _accentColor,
                  onColorChanged: (c) {
                    setState(() => _accentColor = c);
                    PlayerPrefs.setInt('AccentColor', c.toARGB32());
                    Provider.of<ThemeModel>(context, listen: false).accent = c;
                  },
                  pickerAreaBorderRadius: .circular(8),
                  portraitOnly: true,
                  enableAlpha: false,
                  displayThumbColor: true,
                  hexInputBar: true,
                  pickerAreaHeightPercent: 0.3,
                ),
              ],
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton.icon(
                  icon: Icon(Icons.delete_forever, size: 14, color: cs.error),
                  onPressed: () async {
                    late bool confirm = false;
                    await showNoticeDialog(
                      context: context,
                      type: .error,
                      dismissText: "cancel",
                      subtitle:
                          'this will reset all settings and cached data!!!!!! you must restart the app for changes to take effect.',
                      buildButtons: (ctx) {
                        return [
                          TimedButton(
                            duration: Duration(seconds: 2),
                            onPressed: () {
                              confirm = true;
                              Navigator.of(ctx).pop(true);
                            },
                            accent: cs.error,
                            child: Text(
                              'clear',
                              style: TextStyle(color: cs.error),
                            ),
                          ),
                        ];
                      },
                      title: "clear all data?",
                    );
                    if (confirm == true && context.mounted) {
                      await PlayerPrefs.deleteAll();
                      if (context.mounted) Navigator.of(context).pop();
                    }
                  },
                  label: Text(
                    'clear all data',
                    style: TextStyle(color: cs.error, fontSize: 12),
                  ),
                ),
                getButton(
                  Text(
                    "Done",
                    style: TextStyle(color: cs.primary, fontSize: 13),
                  ),
                  () => Navigator.of(context).pop(),
                  cs.primary,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
