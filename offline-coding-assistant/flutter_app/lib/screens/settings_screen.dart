import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/settings_service.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({required this.modelName, super.key});

  final String modelName;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.memory, color: theme.colorScheme.primary),
                      const SizedBox(width: 10),
                      Text(
                        'On-device model',
                        style: theme.textTheme.titleMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    modelName,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Qwen2.5-Coder 0.5B · Q4_K_M · llama.cpp\n'
                    'The model is bundled with the app. This app has no '
                    'internet permission and never calls a server.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.storage_outlined,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Local SQLite storage',
                        style: theme.textTheme.titleMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Chats, messages, drafts, and settings are saved in a '
                    'private SQLite database inside this app. Closing or '
                    'restarting the app does not erase them, and nothing is '
                    'uploaded. Uninstalling the app removes the local data.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text('Generation', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Lower temperature is more focused; higher is more creative. '
            'Max tokens limits the length of one reply.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          Text('Temperature: ${settings.temperature.toStringAsFixed(2)}'),
          Slider(
            value: settings.temperature,
            min: 0.0,
            max: 1.0,
            divisions: 20,
            label: settings.temperature.toStringAsFixed(2),
            onChanged: (value) =>
                context.read<SettingsService>().setTemperature(value),
          ),
          Text('Max reply tokens: ${settings.maxTokens}'),
          Slider(
            value: settings.maxTokens.toDouble(),
            min: 128,
            max: 2048,
            divisions: 15,
            label: '${settings.maxTokens}',
            onChanged: (value) =>
                context.read<SettingsService>().setMaxTokens(value.round()),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () => context.read<SettingsService>().reset(),
            icon: const Icon(Icons.restore),
            label: const Text('Reset generation settings'),
          ),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 12),
          Text('About this build', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Text(
            'The first launch copies the GGUF from the APK into private app '
            'storage. Chats are saved in SQLite on this device, so they are '
            'still there after a restart. After that, everything runs '
            'offline. No Wi-Fi, mobile data, or LAN is required.',
            style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
          ),
        ],
      ),
    );
  }
}
