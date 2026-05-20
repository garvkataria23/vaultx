import 'package:flutter/material.dart';

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  static const _policy = '''
VaultX Privacy Policy Template

VaultX is a local-first secure notes application. The initial version does not create user accounts, does not use cloud storage, and does not transmit notes, attachments, passwords, biometric data, or vault metadata to external servers.

Google Drive Backup (optional):
When enabled, VaultX uploads only AES-256-GCM encrypted backup files to your Google Drive App Folder. The encryption key is derived from your master password using Argon2id. Google never sees plaintext notes, passwords, or vault metadata.

Data stored on device:
- Encrypted notes and note metadata
- Encrypted file attachments and voice recordings
- Encrypted vault export files when exported by the user
- Local security settings and activity logs
- Intruder detection logs and encrypted selfie evidence when enabled by failed PIN attempts

Security model:
- Notes are encrypted before storage.
- The master password is not stored in plaintext.
- Android builds use Android Keystore-backed protected storage for device-bound key material where supported.
- Biometric authentication is used as a local access gate and does not expose biometric templates to VaultX.

Permissions:
- Camera is used only for intruder selfie capture after failed PIN unlock attempts.
- Microphone is used only for voice note recording.
- File access is used only when the user selects attachments or backup files.
- Google Sign-In is used only when the user explicitly enables Google Drive backup.

User control:
- Users can export encrypted vault backups as ZIP files.
- Users can upload encrypted backups to their own Google Drive.
- Users can wipe all VaultX data from the device.
- Self-destruct and dead-man-switch style features must remain optional and disabled unless explicitly enabled.

Contact:
Replace this section with the publisher's support email, legal entity, and region-specific disclosures before Play Store submission.
''';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy policy')),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Text(
            _policy,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(height: 1.45),
          ),
        ],
      ),
    );
  }
}
