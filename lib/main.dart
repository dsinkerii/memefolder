import 'dart:io';
import 'dart:math';

import 'package:file_manager/controller/file_manager_controller.dart';
import 'package:file_manager/file_manager.dart';
import 'package:flutter/material.dart';
import 'package:memefolder/backend/custom_tags_store.dart';
import 'package:memefolder/backend/embedding_service.dart';
import 'package:memefolder/config/theme.dart';
import 'package:memefolder/filtering/filtering.dart';
import 'package:memefolder/main_drawer.dart';
import 'package:memefolder/prefs.dart';
import 'package:memefolder/widgets/bubble_snackbar.dart';
import 'package:memefolder/widgets/file_preview.dart';
import 'package:memefolder/widgets/folder_view.dart';
import 'package:memefolder/widgets/welcome_dialog.dart';
import 'package:media_kit/media_kit.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:memefolder/widgets/smart_context_bar.dart';
import 'package:multi_split_view/multi_split_view.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  JustAudioMediaKit.ensureInitialized();
  setNavigatorKey(navigatorKey);
  await PlayerPrefs.init();
  PlayerPrefs.setInt('launch_count', PlayerPrefs.getInt('launch_count', 0) + 1);
  // Sync verbose console flag file for C++ startup check
  try {
    final dir = await getApplicationSupportDirectory();
    final flag = File(p.join(dir.path, 'verbose.txt'));
    if (PlayerPrefs.getBool('verbose_console', true)) {
      await flag.writeAsString('1');
    } else {
      if (await flag.exists()) await flag.delete();
    }
  } catch (_) {}
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  try {
    await EmbeddingService.instance.initialize();
    debugPrint('[main] EmbeddingService initialized');
  } catch (e) {
    debugPrint('[main] EmbeddingService init failed (models not found?): $e');
  }
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
      navigatorKey: navigatorKey,
      themeMode: theme.dark ? ThemeMode.dark : ThemeMode.light,
      theme: buildTheme(
        theme.dark ? Brightness.dark : Brightness.light,
        theme.accent,
      ),
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
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  late MultiSplitViewController _controller;
  late final TextEditingController _pathController;
  final FileManagerController fileController = FileManagerController();
  bool _controllerInitialized = false;

  final List<String> _history = [];
  int _historyIndex = -1;
  bool _isGrid = false;
  double _folderScale = 1.0;
  File? _selectedFile;

  void _navigateTo(String path) {
    final dir = Directory(path);
    if (!dir.existsSync()) return;

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
    CustomTagsStore.instance.load();
    final initial = _getMainFolder();
    _pathController = TextEditingController(text: initial);
    _isGrid = PlayerPrefs.getBool("is_grid", false);
    _folderScale = PlayerPrefs.getFloat("folder_scale", 1.0).clamp(0.0, 1.0);
    _navigateTo(initial);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!isWelcomeDone && mounted) {
        showWelcomeDialog(context);
      }
    });
  }

  void _applyFilter() {
    final text = searchController.text.trim();
    FilterService.instance.setQuery(text);
    // _getFilteredEntities in folder_view handles semantic + tag AND logic
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
      key: _scaffoldKey,
      drawer: buildDrawer(context),
      body: Column(
        children: [
          SafeArea(
            bottom: false,
            child: Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
                    child: Row(
                      spacing: 16,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.menu),
                          onPressed: () =>
                              _scaffoldKey.currentState?.openDrawer(),
                        ),
                        Expanded(child: contextBar(context)),
                        FloatingActionButton(
                          mini: true,
                          onPressed: _applyFilter,
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.primary,
                          child: Icon(
                            Icons.search,
                            size: 28,
                            color: readableOn(
                              Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  ValueListenableBuilder<bool>(
                    valueListenable: ContextBarState.isFocused,
                    builder: (context, focused, _) {
                      return AnimatedSize(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        alignment: Alignment.topCenter,
                        child: focused
                            ? ColorLegendBar()
                            : const SizedBox(width: double.infinity),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: MultiSplitViewTheme(
              data: MultiSplitViewThemeData(dividerThickness: 3),
              child: MultiSplitView(
                controller: _controller,
                onDividerDragEnd: (index) => _saveFlex(),
              ),
            ),
          ),
        ],
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
