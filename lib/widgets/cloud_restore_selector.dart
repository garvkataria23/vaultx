import 'package:flutter/material.dart';
import '../models/backup.dart';

class CloudRestoreSelector extends StatelessWidget {
  const CloudRestoreSelector({super.key, required this.onSelected});

  final ValueChanged<CloudProvider> onSelected;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 24),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Restore from Cloud',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Choose your cloud provider to find your backup.',
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _ProviderTile(
            provider: CloudProvider.googleDrive,
            title: 'Google Drive',
            subtitle: 'Restore VaultX backup from Google Drive.',
            icon: Icons.add_to_drive,
            iconColor: Colors.blue,
            onTap: () {
              Navigator.pop(context);
              onSelected(CloudProvider.googleDrive);
            },
          ),
          _ProviderTile(
            provider: CloudProvider.mega,
            title: 'MEGA Cloud',
            subtitle: 'Restore VaultX backup from MEGA Cloud.',
            icon: Icons.cloud_queue,
            iconColor: Colors.red,
            onTap: () {
              Navigator.pop(context);
              onSelected(CloudProvider.mega);
            },
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _ProviderTile extends StatelessWidget {
  const _ProviderTile({
    required this.provider,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.iconColor,
    required this.onTap,
  });

  final CloudProvider provider;
  final String title;
  final String subtitle;
  final IconData icon;
  final Color iconColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      leading: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: iconColor.withValues(alpha: 0.1),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: iconColor),
      ),
      title: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(fontSize: 13),
      ),
      onTap: onTap,
    );
  }
}
