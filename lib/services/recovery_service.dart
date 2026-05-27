import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'auth_service.dart';
import 'crypto_service.dart';

class RecoveryResult {
  final bool success;
  final Uint8List? masterKey;
  final String? error;
  final int attemptsRemaining;

  RecoveryResult({
    required this.success,
    this.masterKey,
    this.error,
    this.attemptsRemaining = 5,
  });
}

class RecoveryService {
  RecoveryService();

  final _crypto = CryptoService();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _kCodes = 'recoveryCodes';
  static const _chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';

  static const int _maxAttempts = 5;
  static const int _windowMinutes = 15;

  Future<List<String>> generateCodes({int count = 12}) async {
    final codes = <String>[];
    final rng = Random.secure();
    for (var i = 0; i < count; i++) {
      final code = List.generate(
        8,
        (_) => _chars[rng.nextInt(_chars.length)],
      ).join();
      codes.add('${code.substring(0, 4)}-${code.substring(4)}');
    }
    return codes;
  }

  Future<void> storeCodes(List<String> codes, Uint8List masterKey) async {
    final futures = codes.map((code) async {
      final clean = code.replaceAll('-', '');
      final salt = base64Encode(_crypto.randomBytes(16));

      final lookup = sha256
          .convert([...base64Decode(salt), ...utf8.encode(clean)])
          .toString();

      final key = await _crypto.deriveCredentialKey(clean, salt);
      final encrypted = _crypto.encryptJson(
        {'k': base64Encode(masterKey)},
        key,
      );
      _crypto.wipe(key);

      return <String, dynamic>{
        'salt': salt,
        'lookup': lookup,
        'enc': encrypted,
        'used': false,
      };
    });

    final entries = await Future.wait(futures);
    await _storage.write(key: _kCodes, value: jsonEncode(entries));
  }

  Future<RecoveryResult> verifyCode(String code) async {
    final raw = await _storage.read(key: _kCodes);
    if (raw == null) {
      return RecoveryResult(
        success: false,
        error: 'No recovery codes exist for this vault.',
      );
    }

    final entries = jsonDecode(raw) as List<dynamic>;
    final clean = code.replaceAll('-', '');
    final codeBytes = utf8.encode(clean);

    final (allowed, remaining) = await _checkRateLimit();
    if (!allowed) {
      return RecoveryResult(
        success: false,
        error: remaining != null
            ? 'Too many attempts. Try again in $remaining.'
            : 'Too many failed attempts.',
        attemptsRemaining: 0,
      );
    }

    for (final entry in entries) {
      final map = entry as Map<String, dynamic>;
      if (map['used'] as bool) continue;

      final salt = map['salt'] as String;
      final storedLookup = map['lookup'] as String;

      final computed = sha256
          .convert([...base64Decode(salt), ...codeBytes])
          .toString();

      if (computed != storedLookup) continue;

      final key = await _crypto.deriveCredentialKey(clean, salt);
      try {
        final payload = _crypto.decryptJson(
          map['enc'] as Map<String, dynamic>,
          key,
        );
        _crypto.wipe(key);
        final masterKey = base64Decode(payload['k'] as String);

        await _invalidateAllCodes();
        await _resetRateLimit();

        return RecoveryResult(
          success: true,
          masterKey: Uint8List.fromList(masterKey),
        );
      } catch (_) {
        _crypto.wipe(key);
        await _recordFailedAttempt();
        return RecoveryResult(
          success: false,
          error: 'Invalid recovery code.',
        );
      }
    }

    await _recordFailedAttempt();
    return RecoveryResult(success: false, error: 'Invalid recovery code.');
  }

  Future<bool> hasCodes() async {
    final raw = await _storage.read(key: _kCodes);
    return raw != null;
  }

  Future<int> remainingCodeCount() async {
    final raw = await _storage.read(key: _kCodes);
    if (raw == null) return 0;
    final entries = jsonDecode(raw) as List<dynamic>;
    return entries.where((e) => !(e as Map)['used']).length;
  }

  Future<void> deleteAllCodes() async {
    await _storage.delete(key: _kCodes);
  }

  Future<void> _invalidateAllCodes() async {
    final raw = await _storage.read(key: _kCodes);
    if (raw == null) return;
    final entries = (jsonDecode(raw) as List<dynamic>).map((e) {
      final m = e as Map<String, dynamic>;
      m['used'] = true;
      return m;
    }).toList();
    await _storage.write(key: _kCodes, value: jsonEncode(entries));
  }

  Future<(bool, String?)> _checkRateLimit() async {
    final box = Hive.box('vaultx_settings');
    final count = box.get('recoveryFailCount', defaultValue: 0) as int;
    if (count >= _maxAttempts) {
      final windowStart = box.get('recoveryFailWindow') as int?;
      if (windowStart != null && windowStart > 0) {
        final elapsed = DateTime.now().millisecondsSinceEpoch - windowStart;
        if (elapsed < _windowMinutes * 60 * 1000) {
          final remaining =
              _windowMinutes - (elapsed / 60000).ceil();
          return (false, '$remaining min');
        }
        await _resetRateLimit();
        return (true, null);
      }
      return (false, null);
    }
    return (true, null);
  }

  Future<void> _recordFailedAttempt() async {
    final box = Hive.box('vaultx_settings');
    final count = (box.get('recoveryFailCount', defaultValue: 0) as int) + 1;
    final windowStart =
        box.get('recoveryFailWindow') as int? ??
        DateTime.now().millisecondsSinceEpoch;
    box.put('recoveryFailCount', count);
    box.put('recoveryFailWindow', windowStart);

    if (count >= _maxAttempts * 2) {
      final auth = VaultAuthService();
      await auth.wipeAll();
    }
  }

  Future<void> _resetRateLimit() async {
    final box = Hive.box('vaultx_settings');
    box.put('recoveryFailCount', 0);
    box.put('recoveryFailWindow', 0);
  }
}
