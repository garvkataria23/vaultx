import 'package:flutter/material.dart';

import 'ui_widgets.dart';

/// Displays the overall vault health: device risk, auto-lock, PIN fails, backup status.
class SecurityDashboard extends StatelessWidget {
  const SecurityDashboard({
    super.key,
    required this.posture,
    required this.failedPinAttempts,
    required this.lockMinutes,
    required this.lastBackupAt,
  });

  final Map<String, dynamic> posture;
  final int failedPinAttempts;
  final int lockMinutes;
  final String? lastBackupAt;

  @override
  Widget build(BuildContext context) {
    final deviceRisk =
        posture['rooted'] == true || posture['debuggable'] == true;
    final score = [
      !deviceRisk,
      lockMinutes <= 5,
      failedPinAttempts == 0,
      lastBackupAt != null,
    ].where((v) => v).length;
    final strength = switch (score) {
      4 => 'Maximum',
      3 => 'Strong',
      2 => 'Moderate',
      _ => 'Needs attention',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.security,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Vault strength: $strength',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                SecurityPill(
                  icon: Icons.timer,
                  label: 'Auto-lock ${lockMinutes}m',
                ),
                SecurityPill(
                  icon: Icons.pin,
                  label: 'PIN fails $failedPinAttempts/5',
                ),
                SecurityPill(
                  icon: deviceRisk ? Icons.warning : Icons.verified_user,
                  label: deviceRisk ? 'Device risk' : 'Device OK',
                ),
                SecurityPill(
                  icon: Icons.backup,
                  label: lastBackupAt == null
                      ? 'No backup yet'
                      : 'Backup ready',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
