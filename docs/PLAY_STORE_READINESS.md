# VaultX Play Store Readiness

## Release Identity

- Package name: `com.vaultx.secure`
- App name: `VaultX`
- Version: `1.0.0+1`
- Release signing: create `android/key.properties` from `android/key.properties.example`; the Gradle release build uses it automatically when present.

## Store Listing Positioning

Short description:
Local-first encrypted notes with hidden vault, decoy access, and secure offline backups.

Full description:
VaultX is a privacy-first secure notes app designed for users who want sensitive notes, attachments, and voice recordings to stay on their device. Notes are encrypted locally, backups are exported as encrypted files, and no cloud account is required in the initial version.

## Data Safety Notes

- No user account is created.
- No notes, attachments, credentials, biometrics, or vault metadata are transmitted to a developer server.
- Camera permission is used for local intruder detection.
- Microphone permission is used for local voice note recording.
- File picker access is initiated by the user for attachments and encrypted backup restore.

## Pre-Submission Checklist

- Create a private upload keystore and `android/key.properties`.
- Test backup export and restore on a clean physical Android device.
- Test camera and microphone runtime permissions.
- Review all copy for jurisdiction-specific privacy requirements.
- Confirm self-destruct and dead-man-switch options remain disabled by default.
- Run `flutter build appbundle --release` for Play Store upload.
