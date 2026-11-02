import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/chat_screen.dart';
import 'screens/splash_screen.dart';
import 'services/app_database.dart';
import 'services/chat_repository.dart';
import 'services/local_ai_service.dart';
import 'services/model_installer.dart';
import 'services/settings_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    final database = await AppDatabase.open();
    final repository = ChatRepository(database);
    final settings = await SettingsService.load(database);

    runApp(
      MultiProvider(
        providers: [
          Provider<ChatRepository>.value(value: repository),
          ChangeNotifierProvider<SettingsService>.value(value: settings),
        ],
        child: const OfflineAiApp(),
      ),
    );
  } catch (error) {
    runApp(_StorageErrorApp(error: error));
  }
}

/// Shown only if the private SQLite database cannot be opened.
class _StorageErrorApp extends StatelessWidget {
  const _StorageErrorApp({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.storage, size: 56),
                const SizedBox(height: 16),
                const Text(
                  'Local storage could not be opened.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                SelectableText(error.toString(), textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class OfflineAiApp extends StatelessWidget {
  const OfflineAiApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF3F6B5B);
    return MaterialApp(
      title: 'JAI',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.light,
        ),
        inputDecorationTheme: const InputDecorationTheme(isDense: true),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.dark,
        ),
        inputDecorationTheme: const InputDecorationTheme(isDense: true),
      ),
      home: const BootstrapScreen(),
    );
  }
}

/// Copies the bundled GGUF, loads it, then shows the chat UI.
class BootstrapScreen extends StatefulWidget {
  const BootstrapScreen({super.key});

  @override
  State<BootstrapScreen> createState() => _BootstrapScreenState();
}

class _BootstrapScreenState extends State<BootstrapScreen> {
  final ModelInstaller _installer = ModelInstaller();
  LocalAiService? _ai;
  String _status = 'Starting…';
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    setState(() {
      _loading = true;
      _error = null;
      _status = 'Preparing the on-device model…';
    });

    try {
      final path = await _installer.ensureModel(
        onStatus: (status) {
          if (mounted) setState(() => _status = status);
        },
      );
      if (mounted) {
        setState(() => _status = 'Loading the model into memory…');
      }

      final ai = LocalAiService();
      await ai.load(path, contextSize: 4096, gpuLayers: 0, threads: 4);

      if (!mounted) {
        await ai.dispose();
        return;
      }
      setState(() {
        _ai = ai;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    final ai = _ai;
    if (ai != null) unawaited(ai.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return SplashScreen(status: _status);
    }

    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('JAI')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 56,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  'The local model could not start.',
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                SelectableText(
                  _error.toString(),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _boot,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return ChatScreen(ai: _ai!);
  }
}
