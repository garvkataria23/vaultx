import 'package:flutter/material.dart';
import '../services/browser_extension_service.dart';
import '../widgets/ui_widgets.dart';

class ExtensionPairingScreen extends StatelessWidget {
  const ExtensionPairingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = BrowserExtensionService.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Browser Extension')),
      body: PremiumSurface(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.extension, size: 64, color: Colors.blue),
                  const SizedBox(height: 24),
                  Text('Connect Browser Extension', style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 16),
                  const Text('1. Install VaultX extension in your browser.\n2. Click the extension icon.\n3. Enter the IP, Port, and Pairing PIN below.', textAlign: TextAlign.center),
                  const SizedBox(height: 32),
                  if (svc.isRunning) ...[
                    _buildInfoCard(context, 'IP Address', '127.0.0.1'),
                    const SizedBox(height: 12),
                    _buildInfoCard(context, 'Port', '8080'),
                    const SizedBox(height: 12),
                    _buildInfoCard(context, 'Pairing PIN', svc.pairingPin),
                  ] else ...[
                    const Text('Bridge is not running. Please unlock your vault.'),
                  ]
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInfoCard(BuildContext context, String label, String value) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
          Text(value, style: const TextStyle(fontFamily: 'monospace', fontSize: 18, letterSpacing: 2)),
        ],
      ),
    );
  }
}