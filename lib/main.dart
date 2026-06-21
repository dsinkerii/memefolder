import 'dart:io';
import 'dart:math';

import 'package:file_manager/controller/file_manager_controller.dart';
import 'package:file_manager/file_manager.dart';
import 'package:flutter/material.dart';
import 'package:memefolder/config/theme.dart';
import 'package:memefolder/prefs.dart';
import 'package:memefolder/widgets/file_preview.dart';
import 'package:memefolder/widgets/folder_view.dart';
import 'package:media_kit/media_kit.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:multi_split_view/multi_split_view.dart';
import 'package:provider/provider.dart';
import 'helpers/styled_inputfields.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  JustAudioMediaKit.ensureInitialized();
  await PlayerPrefs.init();
  runApp(
    ChangeNotifierProvider(
      create: (_) {
        final theme = ThemeModel();
        theme.dark = PlayerPrefs.getBool("isDarkMode", true);
        theme.accent = Color(PlayerPrefs.getInt("AccentColor", 0xFF6A79D7));
        return theme;
      },
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Provider.of<ThemeModel>(context);
    return MaterialApp(
      title: 'meme folder',
      themeMode: theme.dark ? ThemeMode.dark : ThemeMode.light,
      theme: buildTheme(Brightness.light, theme.accent),
      home: const MyHomePage(title: 'meme folder'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  late MultiSplitViewController _controller;
  late final TextEditingController _pathController;
  final FileManagerController fileController = FileManagerController();
  bool _controllerInitialized = false;

  // --- new state ---
  final List<String> _history = [];
  int _historyIndex = -1;
  bool _isGrid = false;
  double _folderScale = 1.0;
  File? _selectedFile;

  // navigate with history tracking
  void _navigateTo(String path) {
    final dir = Directory(path);
    if (!dir.existsSync()) return;

    // drop any forward history when navigating new path
    if (_historyIndex < _history.length - 1) {
      _history.removeRange(_historyIndex + 1, _history.length);
    }

    _history.add(path);
    _historyIndex = _history.length - 1;
    PlayerPrefs.setString("main_folder", path);
    _pathController.text = path;
    fileController.openDirectory(dir);
    setState(() {});
  }

  void _goBack() {
    if (_historyIndex > 0) {
      _historyIndex--;
      final path = _history[_historyIndex];
      _pathController.text = path;
      PlayerPrefs.setString("main_folder", path);
      fileController.openDirectory(Directory(path));
      setState(() {});
    }
  }

  void _goForward() {
    if (_historyIndex < _history.length - 1) {
      _historyIndex++;
      final path = _history[_historyIndex];
      _pathController.text = path;
      PlayerPrefs.setString("main_folder", path);
      fileController.openDirectory(Directory(path));
      setState(() {});
    }
  }

  void _goUp() {
    final current = _pathController.text;
    final parent = Directory(current).parent.path;
    if (parent != current) _navigateTo(parent);
  }

  String _getMainFolder() {
    String saved = PlayerPrefs.getString("main_folder");
    if (saved.trim().isEmpty) {
      saved = Platform.environment['HOME'] ?? '.';
      PlayerPrefs.setString("main_folder", saved);
    }
    if (!Directory(saved).existsSync()) {
      saved = Platform.environment['HOME'] ?? '.';
    }
    return saved;
  }

  @override
  void initState() {
    super.initState();
    final initial = _getMainFolder();
    _pathController = TextEditingController(text: initial);
    _isGrid = PlayerPrefs.getBool("is_grid", false);
    _folderScale = PlayerPrefs.getFloat("folder_scale", 1.0).clamp(0.0, 1.0);
    _navigateTo(initial); // seeds history
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_controllerInitialized) {
      _initController();
      _controllerInitialized = true;
    }
  }

  void _initController() {
    double savedFlex = PlayerPrefs.getFloat("split_flex", 0.8);
    if (savedFlex < 0.05 || savedFlex > 0.95) savedFlex = 0.8;

    _controller = MultiSplitViewController(
      areas: [
        Area(
          flex: savedFlex,
          builder: (context, area) => FileBrowserPane(
            currentPath: _pathController.text,
            pathController: _pathController,
            isGrid: _isGrid,
            folderScale: _folderScale,
            canGoBack: _historyIndex > 0,
            canGoForward: _historyIndex < _history.length - 1,
            onBack: _goBack,
            onForward: _goForward,
            onUp: _goUp,
            onToggleGrid: () {
              setState(() {
                _isGrid = !_isGrid;
              });
              PlayerPrefs.setBool("is_grid", _isGrid);
            },
            onScaleChanged: (value) {
              setState(() {
                _folderScale = value;
              });
              PlayerPrefs.setFloat("folder_scale", _folderScale);
            },
            onNavigate: _navigateTo,
            onRefresh: () => _navigateTo(_pathController.text),
            onSelectedFileChanged: (file) {
              setState(() {
                _selectedFile = file;
              });
            },
          ),
          min: 0.1,
        ),
        Area(
          min: max(0.1, 100 / MediaQuery.of(context).size.width),
          flex: 1.0 - savedFlex,
          builder: (context, area) => FilePreviewPane(file: _selectedFile),
        ),
      ],
    );
  }

  void _saveFlex() =>
      PlayerPrefs.setFloat("split_flex", _controller.areas[0].flex ?? 0.8);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        scrolledUnderElevation: 0,
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        title: Row(
          spacing: 12,
          children: [
            IconButton(onPressed: () {}, icon: Icon(Icons.menu)),
            Expanded(
              child: TextField(
                decoration: newInputDeco(
                  context,
                ).copyWith(hintText: "context..."),
                style: newInputStyle(context).copyWith(
                  fontFamily: "Syne",
                  fontVariations: [
                    FontVariation('wdth', 2800),
                    FontVariation('wght', 600),
                  ],
                ),
              ),
            ),
            FloatingActionButton(
              mini: true,
              onPressed: () {},
              child: Icon(
                Icons.search,
                size: 28,
                color: Theme.of(context).colorScheme.surface,
              ),
            ),
          ],
        ),
      ),
      body: MultiSplitViewTheme(
        data: MultiSplitViewThemeData(dividerThickness: 3),
        child: MultiSplitView(
          controller: _controller,
          onDividerDragEnd: (index) => _saveFlex(),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _pathController.dispose();
    fileController.dispose();
    super.dispose();
  }
}
