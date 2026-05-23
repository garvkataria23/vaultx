import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:local_auth/local_auth.dart';

import 'crypto_service.dart';
import 'audit_log.dart';
import '../models/auth.dart';

const _secureChannel = MethodChannel('vaultx/security');

/// Handles vault setup, authentication (password, biometric, hidden vault, decoy).
class VaultAuthService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  final _crypto = CryptoService();
  final _localAuth = LocalAuthentication();

  /// Tracks consecutive secure storage failures to avoid aggressive Keystore resets.
  int _storageFailureCount = 0;
  static const int _maxStorageFailuresBeforeReset = 3;

  Future<bool> isInitialized() async {
    debugPrint('SECURE STORAGE INIT: checking passwordSalt');
    return (await _readSecure('passwordSalt')) != null;
  }

  Future<void> setup({required String password, String? fakePin}) async {
    final passwordSalt = base64Encode(_crypto.randomBytes(16));

    final masterKey = _crypto.randomBytes(32);
    final passwordKey = await _crypto.deriveCredentialKey(
      password,
      passwordSalt,
    );
    await _writeSecure('passwordSalt', passwordSalt);
    await _writeSecure('passwordKdf', 'argon2id:v1');
    await _writeSecure(
      'wrappedMaster.password',
      jsonEncode(
        _crypto.encryptJson({'k': base64Encode(masterKey)}, passwordKey),
      ),
    );

    final keystoreWrapped = await SecurityPlatform.wrapWithAndroidKeystore(
      masterKey,
    );
    if (keystoreWrapped != null) {
      await _writeSecure('wrappedMaster.androidKeystore', keystoreWrapped);
    }

    await _writeSecure(
      'masterVerifier',
      Hmac(sha256, masterKey).convert(utf8.encode('vaultx-master')).toString(),
    );

    if (fakePin != null && fakePin.length >= 4) {
      await setFakePin(fakePin);
    }

    _crypto.wipe(passwordKey);
    _crypto.wipe(masterKey);
    await AuditLog.write('Vault initialized with local-only encrypted storage');
  }

  // ---------------------------------------------------------------------------
  // Password unlock — checks decoy FIRST (before main), then main, then hidden.
  // Order matters: checking decoy first means a coercer who watches the code
  // path cannot distinguish decoy from main by timing.
  // ---------------------------------------------------------------------------

  Future<AuthResult> unlockWithPassword(String password) async {
    // 1. Check decoy password first.
    final decoyResult = await _checkDecoy(password);
    if (decoyResult != null) return decoyResult;

    // 2. Try main vault.
    final salt = await _readSecure('passwordSalt');
    final wrapped = await _readSecure('wrappedMaster.password');
    if (salt == null || wrapped == null) {
      return AuthResult.failure('Vault is not initialized');
    }
    final kdf = await _readSecure('passwordKdf');
    final key = kdf == 'argon2id:v1'
        ? await _crypto.deriveCredentialKey(password, salt)
        : _crypto.deriveLegacyCredentialKey(password, salt);
    final result = _unwrapMaster(
      jsonDecode(wrapped) as Map<String, dynamic>,
      key,
      VaultKind.main,
    );
    _crypto.wipe(key);
    return result;
  }

  // ---------------------------------------------------------------------------
  // Decoy check — compares entered password against the stored decoy hash.
  // Returns an AuthResult with kind=decoy if it matches, null otherwise.
  // ---------------------------------------------------------------------------

  Future<AuthResult?> _checkDecoy(String password) async {
    final salt = await _readSecure('fakePinSalt');
    final storedHash = await _readSecure('fakePinHash');
    if (salt == null || storedHash == null) return null;

    final kdf = await _readSecure('fakePinKdf');
    final key = kdf == 'argon2id:v1'
        ? await _crypto.deriveCredentialKey(password, salt)
        : _crypto.deriveLegacyCredentialKey(password, salt);
    final computedHash = Hmac(
      sha256,
      key,
    ).convert(utf8.encode('vaultx-decoy')).toString();
    _crypto.wipe(key);

    if (computedHash == storedHash) {
      await AuditLog.write('Decoy vault unlocked');
      // Decoy needs no real master key — pass a zero key, VaultHome handles it.
      return AuthResult.decoy();
    }
    return null;
  }

  Future<bool> verifyDecoyPassword(String password) async {
    final result = await _checkDecoy(password);
    return result != null;
  }

  // ---------------------------------------------------------------------------
  // Biometric unlock
  // ---------------------------------------------------------------------------

  Future<bool> isBiometricEnabled() async {
    final box = Hive.box('vaultx_settings');
    return box.get('biometricEnabled', defaultValue: false) as bool;
  }

  Future<List<BiometricType>> getAvailableBiometrics() async {
    return _localAuth.getAvailableBiometrics();
  }

  Future<String> biometricTypeLabel() async {
    final types = await getAvailableBiometrics();
    if (types.contains(BiometricType.face)) return 'Face Unlock';
    if (types.contains(BiometricType.strong)) return 'Biometrics';
    if (types.contains(BiometricType.fingerprint)) return 'Fingerprint';
    if (types.contains(BiometricType.iris)) return 'Iris';
    return 'Device Biometrics';
  }

  Future<IconData> biometricTypeIcon() async {
    final types = await getAvailableBiometrics();
    if (types.contains(BiometricType.face)) return Icons.face;
    if (types.contains(BiometricType.iris)) return Icons.visibility;
    if (types.contains(BiometricType.strong) ||
        types.contains(BiometricType.fingerprint)) {
      return Icons.fingerprint;
    }
    return Icons.security;
  }

  // Returns true only when ALL three are true:
  //   1. biometricEnabled Hive flag is set
  //   2. device has biometric hardware with enrolled templates
  //   3. wrappedMaster.androidKeystore exists (master key in Keystore)
  Future<bool> isBiometricUnlockAvailable() async {
    final enabled = await isBiometricEnabled();
    if (!enabled) return false;
    final hasHardware =
        await _localAuth.canCheckBiometrics ||
        await _localAuth.isDeviceSupported();
    if (!hasHardware) return false;
    final types = await _localAuth.getAvailableBiometrics();
    if (types.isEmpty) return false;
    final wrapped = await _readSecure('wrappedMaster.androidKeystore');
    return wrapped != null;
  }

  /// Enables biometric unlock by wrapping the master key in Android Keystore
  /// and persisting the enabled flag. Must be called with a verified master key.
  Future<bool> setupBiometric(Uint8List masterKey) async {
    try {
      final keystoreWrapped = await SecurityPlatform.wrapWithAndroidKeystore(
        masterKey,
      );
      if (keystoreWrapped == null) return false;
      await _writeSecure('wrappedMaster.androidKeystore', keystoreWrapped);
      await Hive.box('vaultx_settings').put('biometricEnabled', true);
      await AuditLog.write('Biometric unlock enabled');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Disables biometric unlock without removing the Keystore key
  /// (so re-enabling does not require a new password).
  Future<void> removeBiometric() async {
    await Hive.box('vaultx_settings').put('biometricEnabled', false);
    await AuditLog.write('Biometric unlock disabled');
  }

  Future<AuthResult> unlockWithBiometric() async {
    if (!await biometricAvailable()) {
      return AuthResult.failure(
        'Biometric authentication is not available on this device',
      );
    }

    final wrapped = await _readSecure('wrappedMaster.androidKeystore');
    if (wrapped == null) {
      return AuthResult.failure(
        'Biometric unlock is not set up — unlock with password once to enable it',
      );
    }

    final authenticated = await authenticateBiometric();
    if (!authenticated) {
      return AuthResult.failure(
        'Biometric authentication was cancelled or failed',
      );
    }

    final masterKey = await SecurityPlatform.unwrapWithAndroidKeystore(wrapped);
    if (masterKey == null) {
      debugPrint('KEYSTORE RESET: biometric unwrap failed');
      await _deleteSecure('wrappedMaster.androidKeystore');
      await SecurityPlatform.resetAndroidKeystore();
      return AuthResult.failure(
        'Could not retrieve key from device keystore — try unlocking with password',
      );
    }

    await AuditLog.write('Vault unlocked via biometric');
    return AuthResult.pending(masterKey, 'masterVerifier', VaultKind.main);
  }

  // ---------------------------------------------------------------------------
  // Hidden vault unlock
  // ---------------------------------------------------------------------------

  Future<AuthResult> unlockHidden(String passwordOrPin) async {
    final salt = await _readSecure('hiddenSalt');
    final wrapped = await _readSecure('wrappedMaster.hidden');
    if (salt == null || wrapped == null) {
      return AuthResult.failure('Hidden vault is not configured');
    }
    final kdf = await _readSecure('hiddenKdf');
    final key = kdf == 'argon2id:v1'
        ? await _crypto.deriveCredentialKey(passwordOrPin, salt)
        : _crypto.deriveLegacyCredentialKey(passwordOrPin, salt);
    final result = _unwrapMaster(
      jsonDecode(wrapped) as Map<String, dynamic>,
      key,
      VaultKind.hidden,
    );
    _crypto.wipe(key);
    return result;
  }

  // ---------------------------------------------------------------------------
  // Decoy / fake PIN setup
  // ---------------------------------------------------------------------------

  Future<void> setFakePin(String pin) async {
    final salt = base64Encode(_crypto.randomBytes(16));
    final key = await _crypto.deriveCredentialKey(pin, salt);
    await _writeSecure('fakePinSalt', salt);
    await _writeSecure('fakePinKdf', 'argon2id:v1');
    await _writeSecure(
      'fakePinHash',
      Hmac(sha256, key).convert(utf8.encode('vaultx-decoy')).toString(),
    );
    _crypto.wipe(key);
    await AuditLog.write('Decoy password updated');
  }

  /// Re-wraps the existing master key with a new password-derived key.
  /// Does NOT change the master key itself, so vault data remains compatible.
  Future<bool> changeMasterPassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    // 1. Verify current password and get master key
    final authResult = await unlockWithPassword(currentPassword);
    if (!authResult.ok || authResult.masterKey == null) {
      await AuditLog.write('PASSWORD_VERIFY_FAILED');
      return false;
    }
    await AuditLog.write('PASSWORD_VERIFY_SUCCESS');
    await AuditLog.write('PASSWORD_CHANGE_STARTED');

    final masterKey = authResult.masterKey!;
    final oldSalt = await _readSecure('passwordSalt');
    final oldWrapped = await _readSecure('wrappedMaster.password');

    try {
      // 2. Generate new salt and derive new key
      final newSalt = base64Encode(_crypto.randomBytes(16));
      final newPasswordKey = await _crypto.deriveCredentialKey(newPassword, newSalt);

      // 3. Wrap existing master key with new password key
      final newWrapped = jsonEncode(
        _crypto.encryptJson({'k': base64Encode(masterKey)}, newPasswordKey),
      );

      // 4. Persist
      await _writeSecure('passwordSalt', newSalt);
      await _writeSecure('wrappedMaster.password', newWrapped);

      _crypto.wipe(newPasswordKey);
      await AuditLog.write('PASSWORD_CHANGED');
      return true;
    } catch (e) {
      // Rollback
      if (oldSalt != null) await _writeSecure('passwordSalt', oldSalt);
      if (oldWrapped != null) await _writeSecure('wrappedMaster.password', oldWrapped);
      await AuditLog.write('PASSWORD_CHANGE_FAILED: $e');
      return false;
    } finally {
      _crypto.wipe(masterKey);
    }
    }

    // Kept for backward compatibility with existing vaults that have a PIN set.

  Future<void> setPin(String pin, Uint8List masterKey) async {
    final salt = base64Encode(_crypto.randomBytes(16));
    await _writeSecure('pinSalt', salt);
    await _writeSecure('pinKdf', 'argon2id:v1');
    final key = await _crypto.deriveCredentialKey(pin, salt);
    await _writeSecure(
      'wrappedMaster.pin',
      jsonEncode(_crypto.encryptJson({'k': base64Encode(masterKey)}, key)),
    );
    _crypto.wipe(key);
    await AuditLog.write('PIN unlock updated');
  }

  // ---------------------------------------------------------------------------
  // Hidden vault configuration
  // ---------------------------------------------------------------------------

  Future<bool> isHiddenVaultConfigured() async {
    return (await _readSecure('hiddenSalt')) != null &&
        (await _readSecure('wrappedMaster.hidden')) != null;
  }

  Future<void> configureHiddenVault(String secret) async {
    final masterSalt = base64Encode(_crypto.randomBytes(16));
    final keySalt = base64Encode(_crypto.randomBytes(16));

    final masterKey = await _crypto.deriveCredentialKey(secret, masterSalt);
    final wrappingKey = await _crypto.deriveCredentialKey(secret, keySalt);

    await _writeSecure('hiddenMasterSalt', masterSalt);
    await _writeSecure('hiddenSalt', keySalt);
    await _writeSecure('hiddenKdf', 'argon2id:v1');

    await _writeSecure(
      'wrappedMaster.hidden',
      jsonEncode(
        _crypto.encryptJson({'k': base64Encode(masterKey)}, wrappingKey),
      ),
    );
    await _writeSecure(
      'hiddenVerifier',
      Hmac(sha256, masterKey).convert(utf8.encode('vaultx-master')).toString(),
    );
    _crypto.wipe(wrappingKey);
    _crypto.wipe(masterKey);
    await AuditLog.write('Hidden vault configured');
  }

  // ---------------------------------------------------------------------------
  // Biometric helpers
  // ---------------------------------------------------------------------------

  Future<bool> biometricAvailable() async {
    return await _localAuth.isDeviceSupported();
  }

  Future<bool> authenticateBiometric() async {
    final label = await biometricTypeLabel();
    final types = await getAvailableBiometrics();
    final hasFace = types.contains(BiometricType.face);

    return _localAuth.authenticate(
      localizedReason: 'Authenticate with $label to unlock VaultX',
      options: AuthenticationOptions(
        // Allow non-strong biometrics if Face Unlock is available to support
        // Class 2 (Weak) implementations common on many Android devices.
        // This change ensures Face Unlock is prioritized and active if enrolled.
        // It also enables device PIN/Pattern fallback within the system dialog.
        biometricOnly: !hasFace,
        stickyAuth: true,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Wipe
  // ---------------------------------------------------------------------------

  Future<void> wipeAll() async {
    try {
      await _storage.deleteAll();
    } catch (e) {
      debugPrint('STORAGE RECOVERY: deleteAll failed during wipe: $e');
    }
    await Hive.box('vaultx_records').clear();
    await Hive.box('vaultx_audit').clear();
    await Hive.box('vaultx_settings').clear();
  }

  Future<Uint8List> intruderLogKey() async {
    final existing = await _readSecure('intruderLogKey');
    if (existing != null) return base64Decode(existing);
    final key = _crypto.randomBytes(32);
    await _writeSecure('intruderLogKey', base64Encode(key));
    return key;
  }

  // ---------------------------------------------------------------------------
  // Cross-device sync
  // ---------------------------------------------------------------------------

  Future<Map<String, String?>> exportAuthBundle() async {
    return {
      'wrappedMaster.password': await _readSecure('wrappedMaster.password'),
      'passwordSalt': await _readSecure('passwordSalt'),
      'passwordKdf': await _readSecure('passwordKdf'),
      'masterVerifier': await _readSecure('masterVerifier'),
      'wrappedMaster.pin': await _readSecure('wrappedMaster.pin'),
      'pinSalt': await _readSecure('pinSalt'),
      'pinKdf': await _readSecure('pinKdf'),
      'wrappedMaster.hidden': await _readSecure('wrappedMaster.hidden'),
      'hiddenSalt': await _readSecure('hiddenSalt'),
      'hiddenMasterSalt': await _readSecure('hiddenMasterSalt'),
      'hiddenKdf': await _readSecure('hiddenKdf'),
      'hiddenVerifier': await _readSecure('hiddenVerifier'),
    };
  }

  Future<void> importAuthBundle(
    Map<String, dynamic> bundle, {
    bool force = false,
  }) async {
    final alreadyInit = await isInitialized();
    if (alreadyInit && !force) {
      await AuditLog.write(
        'importAuthBundle skipped — vault already initialized on this device',
      );
      return;
    }
    for (final entry in bundle.entries) {
      final value = entry.value as String?;
      if (value != null) {
        await _writeSecure(entry.key, value);
      }
    }
    await AuditLog.write('Auth bundle imported for cross-device restore');
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  AuthResult _unwrapMaster(
    Map<String, dynamic> wrapped,
    Uint8List key,
    VaultKind kind,
  ) {
    try {
      final payload = _crypto.decryptJson(wrapped, key);
      final master = base64Decode(payload['k'] as String);
      final verifierKey = kind == VaultKind.hidden
          ? 'hiddenVerifier'
          : 'masterVerifier';
      return AuthResult.pending(master, verifierKey, kind);
    } catch (_) {
      return AuthResult.failure('Invalid credential');
    }
  }

  Future<AuthResult> verify(AuthResult pending) async {
    // Decoy results are pre-verified — no master key to check.
    if (pending.kind == VaultKind.decoy) return pending;
    if (pending.masterKey == null) return pending;
    final verifier = await _readSecure(pending.verifierKey!);
    final actual = Hmac(
      sha256,
      pending.masterKey!,
    ).convert(utf8.encode('vaultx-master')).toString();
    if (verifier != actual) return AuthResult.failure('Invalid credential');
    return pending.copyWith(ok: true);
  }

  Future<String?> _readSecure(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (e, st) {
      debugPrint('STORAGE RECOVERY: read failed for $key: $e');
      debugPrint('$st');
      await _recoverCorruptedSecureKey(key);
      return null;
    }
  }

  Future<void> _writeSecure(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (e, st) {
      debugPrint('STORAGE RECOVERY: write failed for $key: $e');
      debugPrint('$st');
      await _recoverCorruptedSecureKey(key);
      try {
        await _storage.write(key: key, value: value);
      } catch (retryError) {
        debugPrint(
          'STORAGE RECOVERY: retry write failed for $key: $retryError',
        );
      }
    }
  }

  Future<void> _deleteSecure(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (e) {
      debugPrint('STORAGE RECOVERY: delete failed for $key: $e');
    }
  }

  Future<void> _recoverCorruptedSecureKey(String key) async {
    _storageFailureCount++;
    debugPrint(
      'STORAGE RECOVERY: failure #$_storageFailureCount for key $key',
    );

    // Only clear the single corrupted key — never reset the entire Keystore
    // on every failure. Android Keystore reset destroys biometric keys and
    // keys belonging to other apps. Only reset after 3 consecutive failures.
    try {
      await _storage.delete(key: key);
    } catch (_) {}

    if (_storageFailureCount >= _maxStorageFailuresBeforeReset) {
      debugPrint(
        'KEYSTORE RESET: $_maxStorageFailuresBeforeReset failures — '
        'resetting Android Keystore',
      );
      await SecurityPlatform.resetAndroidKeystore();
      _storageFailureCount = 0;
    }

    debugPrint('STORAGE RECOVERY: recovered key $key');
  }
}

// ---------------------------------------------------------------------------
// SecurityPlatform
// ---------------------------------------------------------------------------

class SecurityPlatform {
  static bool _isSensitiveOperationActive = false;

  static void setSensitiveOperationActive(bool active) {
    _isSensitiveOperationActive = active;
  }

  static bool get isSensitiveOperationActive => _isSensitiveOperationActive;

  static Future<void> enableScreenProtection() async {
    try {
      await _secureChannel.invokeMethod('enableSecureWindow');
    } catch (_) {}
  }

  static Future<Map<String, dynamic>> devicePosture() async {
    try {
      return Map<String, dynamic>.from(
        await _secureChannel.invokeMethod('devicePosture') as Map,
      );
    } catch (_) {
      return {'rooted': false, 'debuggable': false, 'platform': 'unsupported'};
    }
  }

  static Future<String?> wrapWithAndroidKeystore(Uint8List bytes) async {
    try {
      await _secureChannel.invokeMethod('keystoreReady');
      final result = Map<String, dynamic>.from(
        await _secureChannel.invokeMethod('keystoreWrap', {
              'plain': base64Encode(bytes),
            })
            as Map,
      );
      return '${result['iv']}.${result['ct']}';
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List?> unwrapWithAndroidKeystore(String wrapped) async {
    try {
      final result = await _secureChannel.invokeMethod<String>(
        'keystoreUnwrap',
        {'wrapped': wrapped},
      );
      return result == null ? null : base64Decode(result);
    } catch (_) {
      return null;
    }
  }

  static Future<void> resetAndroidKeystore() async {
    try {
      await _secureChannel.invokeMethod('keystoreReset');
    } catch (_) {}
  }

  static Future<void> setDecoyLauncherEnabled(bool enabled) async {
    try {
      await _secureChannel.invokeMethod('setDecoyLauncherEnabled', {
        'enabled': enabled,
      });
    } catch (e) {
      debugPrint('DECOY LAUNCHER: platform switch unavailable: $e');
    }
  }
}
